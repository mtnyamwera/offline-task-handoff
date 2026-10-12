#!/usr/bin/env python3
"""
Offline Task Handoff Protocol: Python receiver (a "candidate" device).

This does the same job as the Dart "Target" app, written only from
PROTOCOL.md plus the prompt/cleanup rules of the summarize task. It shares
no code with the Dart app. If a phone running the Dart app can hand a task
to this program and get the result back, the specification is enough to
build a second implementation.

What it does
  1. Announces itself on the LAN (UDP broadcast, role "candidate").
  2. Accepts a handoff (STATE): saves it to disk, ACKs, then resumes the
     task (spec 6.2, 7.3).
  3. Runs the remaining steps by calling a local Ollama model (spec 7.1).
  4. Handles LATE_COMPLETION messages: holds or compares, flags divergence
     (spec 7.4).
  5. Delivers the finished result back to the originator through a
     persisted mailbox queue, retrying until ACKed (spec 7.5).

Standard library only. Python 3.8+.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from typing import Any, Callable, Dict, List, Optional

# ---------------------------------------------------------------- constants
TCP_PORT = 5891            # spec section 3
UDP_PORT = 5892
ANNOUNCE_INTERVAL = 2.0    # spec section 8
PEER_STALE_AFTER = 6.0
PRUNE_EVERY = 2.0
CONNECT_TIMEOUT = 5.0
ACK_WAIT = 5.0             # seconds of silence
STEP_RETRY_DELAY = 2.0
MAILBOX_RETRY = 5.0
MODEL_TIMEOUT = 60.0       # application level, not protocol
READ_TIMEOUT = 10.0        # how long we wait for a sender to finish a line
MAX_MESSAGE_BYTES = 16 * 1024 * 1024


# ------------------------------------------------------------------ helpers
def now_ms() -> int:
    return int(time.time() * 1000)


def to_base36(n: int) -> str:
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if n == 0:
        return "0"
    out = []
    while n:
        n, r = divmod(n, 36)
        out.append(digits[r])
    return "".join(reversed(out))


def encode_message(obj: Dict[str, Any]) -> bytes:
    """One JSON object on one line, ended by LF (spec section 3).
    json.dumps escapes newlines inside strings, so no raw LF appears."""
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


def read_line(sock: socket.socket, timeout: float, max_bytes: int = MAX_MESSAGE_BYTES) -> Optional[bytes]:
    """Read RAW BYTES up to the first LF and return them (without the LF).
    We frame on the byte BEFORE decoding, so a multi-byte UTF-8 character
    split across two TCP segments cannot break parsing (spec section 3).
    `timeout` is an inactivity timeout, as in the spec's "5 s of silence"."""
    sock.settimeout(timeout)
    buf = bytearray()
    while True:
        try:
            chunk = sock.recv(65536)
        except (socket.timeout, OSError):
            return None
        if not chunk:
            return None          # closed before a full line arrived
        buf.extend(chunk)
        i = buf.find(b"\n")
        if i >= 0:
            return bytes(buf[:i])
        if len(buf) > max_bytes:
            return None


def send_message(ip: str, message: Dict[str, Any], port: int = TCP_PORT) -> Optional[Dict[str, Any]]:
    """The exchange pattern of spec 6.1: connect (5 s), send one line, wait
    for one reply line (5 s of silence), close. Returns the parsed reply, or
    None on any failure (the caller treats None as "not confirmed")."""
    try:
        with socket.create_connection((ip, port), timeout=CONNECT_TIMEOUT) as s:
            s.sendall(encode_message(message))
            line = read_line(s, ACK_WAIT)
        if line is None:
            return None
        reply = json.loads(line.decode("utf-8"))
        return reply if isinstance(reply, dict) else None
    except (OSError, ValueError):
        return None


def detect_local_ip() -> str:
    """Best guess at this machine's LAN address (no packet is sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def load_or_create_device_id(data_dir: str) -> str:
    """The device ID must survive restarts (spec section 3)."""
    path = os.path.join(data_dir, "device_id.txt")
    try:
        with open(path, "r", encoding="utf-8") as f:
            existing = f.read().strip()
        if existing:
            return existing
    except OSError:
        pass
    fresh = to_base36(now_ms()) + str(100 + int(time.time() * 1_000_000) % 900)
    with open(path, "w", encoding="utf-8") as f:
        f.write(fresh)
    return fresh


def write_json_atomic(path: str, obj: Any) -> None:
    """Write, flush to disk, then rename. A crash never leaves half a file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _is_int(x: Any) -> bool:
    return isinstance(x, int) and not isinstance(x, bool)


# ---------------------------------------------------------------- discovery
def parse_announcement(raw: bytes) -> Optional[Dict[str, Any]]:
    """Spec 4.1. Returns a normalised dict, or None for anything malformed."""
    try:
        d = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(d, dict):
        return None
    if not isinstance(d.get("deviceId"), str) or not isinstance(d.get("ip"), str):
        return None
    if not _is_int(d.get("battery")) or not _is_int(d.get("signal")):
        return None
    if not isinstance(d.get("busy"), bool):
        return None
    role = d.get("role", "candidate")
    if not isinstance(role, str):
        return None
    return {"deviceId": d["deviceId"], "ip": d["ip"], "battery": d["battery"],
            "signal": d["signal"], "busy": d["busy"], "role": role}


class PeerTable:
    """Who has been heard recently. Entries expire after `stale_after`
    seconds without an announcement; that is the only way a departure is
    noticed (spec 4.2). `static` maps deviceId to ip for manual/test use."""

    def __init__(self, stale_after: float = PEER_STALE_AFTER,
                 clock: Callable[[], float] = time.monotonic):
        self._stale_after = stale_after
        self._clock = clock
        self._peers: Dict[str, Dict[str, Any]] = {}
        self._seen: Dict[str, float] = {}
        self.static: Dict[str, str] = {}
        self._lock = threading.Lock()

    def update(self, ann: Dict[str, Any]) -> None:
        with self._lock:
            self._peers[ann["deviceId"]] = ann
            self._seen[ann["deviceId"]] = self._clock()

    def prune(self) -> None:
        with self._lock:
            now = self._clock()
            for did in [d for d, t in self._seen.items() if now - t > self._stale_after]:
                self._peers.pop(did, None)
                self._seen.pop(did, None)

    def ip_of(self, device_id: str) -> Optional[str]:
        with self._lock:
            if device_id in self.static:
                return self.static[device_id]
            p = self._peers.get(device_id)
            return p["ip"] if p else None

    def ids(self) -> List[str]:
        with self._lock:
            return list(self._peers)


# ----------------------------------------------------------- summarize task
SUMMARY_MAX_CHARS = 1500
# These three patterns are mirrored character for character in the Dart app
# (kPreamblePattern, kLabelLinePattern, kLabelInlinePattern in summary_task.dart).
# Change them together; the test suite compares the pattern text.
_PREAMBLE_SRC = r"^(?:here(?:['’]s| is| are)|sure|okay|certainly)\b[^\n:]{0,100}:\s*"
_LABEL_LINE_SRC = r"^(?:#{1,6}[ \t]*)?(?:\*\*|__)?(?:(?:updated|final|new|revised|running|consolidated)[ \t]+)?summary(?:[ \t]+so[ \t]+far)?[ \t]*(?:\*\*|__)?[ \t]*:?[ \t]*(?:\*\*|__)?[ \t]*(?:\r?\n[ \t\r\n]*|$)"
_LABEL_INLINE_SRC = r"^(?:#{1,6}[ \t]*)?(?:\*\*|__)?(?:(?:updated|final|new|revised|running|consolidated)[ \t]+)?summary(?:[ \t]+so[ \t]+far)?[ \t]*(?:\*\*|__)?[ \t]*:[ \t]*(?:\*\*|__)?[ \t]+(?=[^ \t\r\n])"
_PREAMBLE = re.compile(_PREAMBLE_SRC, re.IGNORECASE)
_LABEL_LINE = re.compile(_LABEL_LINE_SRC, re.IGNORECASE)
_LABEL_INLINE = re.compile(_LABEL_INLINE_SRC, re.IGNORECASE)


def build_summary_prompt(step: int, total_steps: int, chunk: str, running_summary: str) -> str:
    """Identical wording to the Dart buildSummaryPrompt, so a step re-run on
    this device sees the same instructions the phone used."""
    trimmed = running_summary.strip()
    if not trimmed:
        summary = "(none yet - this is the first section)"
    else:
        summary = trimmed[:SUMMARY_MAX_CHARS]
    return ("You are summarizing a document one section at a time.\n\n"
            f"Summary so far:\n{summary}\n\n"
            f"New section ({step} of {total_steps}):\n{chunk}\n\n"
            "Write an updated summary that covers everything so far, including "
            "this new section. Keep the important points from the earlier "
            "sections; do not drop them to make room. Use only information from "
            "the text above. Use at most 150 words. Start directly with the "
            "summary, with no introduction.")


def clean_summary(raw: str) -> str:
    """Strip a leading "Here's an updated summary:" line, then a leading label
    such as "**Summary:**" (same as Dart cleanSummary)."""
    t = raw.strip()
    out = _PREAMBLE.sub("", t, count=1).strip()
    out = _LABEL_LINE.sub("", out, count=1).strip()
    out = _LABEL_INLINE.sub("", out, count=1).strip()
    return out or t


def normalize_endpoint(endpoint: str) -> str:
    e = endpoint.strip()
    e = re.sub(r"/+$", "", e)
    e = re.sub(r"/api(/generate)?$", "", e)
    e = re.sub(r"/+$", "", e)
    if not e.startswith(("http://", "https://")):
        e = "http://" + e
    return e


# No proxy: Ollama is local, and an HTTP_PROXY variable must not intercept it.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def ollama_generate(endpoint: str, model: str, prompt: str, timeout: float = MODEL_TIMEOUT) -> str:
    """One real model call. Raises on any failure; the caller records it as
    a failed attempt and retries under the SAME key (invariants I3, I4)."""
    url = normalize_endpoint(endpoint) + "/api/generate"
    body = json.dumps({"model": model, "prompt": prompt, "stream": False,
                       "options": {"num_predict": 260}}).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")[:200]
        raise RuntimeError(f"Ollama returned {e.code} for POST {url}: {detail}")
    text = payload.get("response") if isinstance(payload, dict) else None
    if not isinstance(text, str) or not text.strip():
        raise RuntimeError("Ollama returned an empty response")
    return text.strip()


class SummarizeTask:
    """Everything this receiver knows about the "summarize" task type. The
    protocol carries only TaskState.data; the knowledge of how to work on it
    lives here, on the device (spec: "the protocol carries state, not
    behaviour"). A different task type is a different class like this one."""

    task_type = "summarize"

    def __init__(self, endpoint: str, model: str):
        self.endpoint = endpoint
        self.model = model

    def run_step(self, step: int, state: Dict[str, Any]) -> str:
        """Do step N. MUST NOT change `state` (the loop records the result)."""
        data = state.get("data") or {}
        chunks = data.get("chunks") or []
        chunk = chunks[step - 1] if len(chunks) >= step else ""
        prompt = build_summary_prompt(step, state["targetStep"], chunk,
                                      data.get("runningSummary", "") or "")
        return clean_summary(ollama_generate(self.endpoint, self.model, prompt))

    def apply_result(self, step: int, result: str, state: Dict[str, Any]) -> None:
        state["data"]["runningSummary"] = result          # replaces, not appends

    def final_result(self, state: Dict[str, Any], device_id: str) -> Dict[str, Any]:
        data = state.get("data") or {}
        summary = data.get("runningSummary", "") or ""
        return {"taskId": state["taskId"], "completedSteps": state["stepIndex"],
                "finishedBy": device_id, "taskType": self.task_type,
                "chunks": len(data.get("chunks") or []),
                "summary": summary if summary.strip()
                else f"Task completed after {len(state['log'])} logged steps."}


def validate_state(p: Any) -> Optional[str]:
    """Minimal structural check of a TaskState (spec 5.1). Returns an error
    string, or None if the state is acceptable."""
    if not isinstance(p, dict):
        return "payload is not an object"
    for k in ("taskId", "originatorId", "status"):
        if not isinstance(p.get(k), str):
            return f"missing or invalid '{k}'"
    for k in ("stepIndex", "targetStep"):
        if not _is_int(p.get(k)):
            return f"missing or invalid '{k}'"
    if not isinstance(p.get("log"), list):
        return "missing or invalid 'log'"
    pa = p.get("pendingAction")
    if pa is not None and not (isinstance(pa, dict) and isinstance(pa.get("idempotencyKey"), str)
                               and _is_int(pa.get("forStep"))):
        return "invalid 'pendingAction'"
    if not isinstance(p.get("data", {}), dict):
        return "invalid 'data'"
    return None


# --------------------------------------------------------------- task runner
class TaskRunner(threading.Thread):
    """Runs one task: resume rule (7.3), step loop (7.1), late-completion
    handling (7.4). Holds the invariants I1 to I4 of spec 5.2."""

    def __init__(self, node: "Receiver", state: Dict[str, Any], handler: Any):
        super().__init__(daemon=True, name=f"task-{state['taskId'][:8]}")
        state.setdefault("data", {})
        state.setdefault("taskType", "generic")
        self.node = node
        self.state = state
        self.handler = handler
        self.lock = threading.RLock()
        self.divergences = 0
        self.finished = False
        self._stop_evt = threading.Event()

    @property
    def task_id(self) -> str:
        return self.state["taskId"]

    def is_active(self) -> bool:
        return not self.finished

    def stop(self) -> None:
        self._stop_evt.set()

    def save_state(self) -> None:
        with self.lock:
            write_json_atomic(self.node.task_path(self.task_id), self.state)

    # ---- 7.3 resume rule, then 7.1 loop
    def run(self) -> None:
        try:
            self._resume_rule()
            self._loop()
        except Exception as e:                                  # noqa: BLE001
            self.node.log(f"Task {self.task_id[:8]} stopped by an error: {e!r}")
        finally:
            self.finished = True

    def _resume_rule(self) -> None:
        with self.lock:
            pa = self.state.get("pendingAction")
            if not pa:
                return
            key, step = pa["idempotencyKey"], pa["forStep"]
            done = any(e.get("idempotencyKey") == key and e.get("status") == "completed"
                       for e in self.state["log"])
            if done:
                self.node.log(f"Resume: step {step} was already completed under key {key}"
                              " - skipping re-run, advancing.")
                self.state["stepIndex"] = step
                self.state["pendingAction"] = None
                self.save_state()
            else:
                self.node.log(f"Resume: step {step} outcome unknown under key {key}"
                              " - re-running under the SAME key.")

    def _loop(self) -> None:
        while not self._stop_evt.is_set():
            with self.lock:
                if self.state["stepIndex"] >= self.state["targetStep"]:
                    self.state["status"] = "completed"
                    result = self.handler.final_result(self.state, self.node.device_id)
                    # Queue the result BEFORE marking the task completed on
                    # disk: a crash in between duplicates a delivery (which
                    # is allowed) instead of losing it.
                    self.node.mailbox.enqueue(self.task_id, self.state["originatorId"], result)
                    self.save_state()
                    break
                n = self.state["stepIndex"] + 1
                pa = self.state.get("pendingAction")
                key = pa["idempotencyKey"] if pa and pa.get("forStep") == n else str(uuid.uuid4())
                # I1: tag the step BEFORE acting on it.
                self.state["pendingAction"] = {"idempotencyKey": key, "forStep": n,
                                               "startedAt": now_ms()}
                self.state["status"] = "running"
                self.save_state()
            self.node.log(f"Step {n}: dispatching REAL call (key {key})...")

            ok, result = True, ""
            try:
                result = self.handler.run_step(n, self.state)
            except Exception as e:                              # noqa: BLE001
                ok, result = False, f"error: {e}"

            with self.lock:
                self.state["log"].append({"step": n, "idempotencyKey": key,
                                          "status": "completed" if ok else "failed",
                                          "result": result, "timestamp": now_ms()})   # I4
                if ok:
                    self.state["stepIndex"] = n
                    self.state["pendingAction"] = None
                    self.handler.apply_result(n, result, self.state)                    # I2
                    self.save_state()
                    short = result if len(result) <= 80 else result[:80] + "..."
                    self.node.log(f'Step {n}: confirmed completed (key {key}). Response: "{short}"')
                    self.node.event("step_completed", task_id=self.task_id, step=n, key=key, result=result)
                    for e in self._late_entries(key, "held"):        # arrived while we were running
                        self._compare(n, key, result, e["result"])
                else:
                    self.save_state()
                    self.node.log(f"Step {n}: call did not confirm (key {key}) - {result}. "
                                  "Outcome unknown; retrying under the same key.")
                    self.node.event("step_failed", task_id=self.task_id, step=n, key=key, error=result)
            if not ok and self._stop_evt.wait(self.node.step_retry_delay):                  # I3
                break

        if self.state["status"] == "completed":
            summary = (self.state.get("data") or {}).get("runningSummary", "")
            self.node.log(f"Task {self.task_id[:8]} completed. Final result queued for "
                          f"originator {self.state['originatorId']}.")
            if summary:
                self.node.log("Final summary:\n" + summary)
            self.node.event("task_completed", task_id=self.task_id)

    # ---- 7.4 late completions
    def on_late_completion(self, step: int, key: str, text: str) -> None:
        with self.lock:
            own = [e for e in self.state["log"]
                   if e.get("idempotencyKey") == key and e.get("status") == "completed"]
            pa = self.state.get("pendingAction")
            if own:
                self._compare(step, key, own[0].get("result") or "", text)
            elif pa and pa.get("idempotencyKey") == key:
                self._record_late(step, key, text, "held")
                self.node.log(f"Late completion for step {step} (key {key}) arrived while our own "
                              "attempt is still in flight - holding it, will compare when ours finishes.")
                self.node.event("late_held", task_id=self.task_id, step=step, key=key)
            else:
                self.node.log(f"Late completion for step {step} (key {key}): we have no completed "
                              "result and none in flight for this key. Not a divergence; the late "
                              "result is the only successful one (policy open: adopt or ignore).")
                self._record_late(step, key, text, "orphan")
                self.node.event("late_orphan", task_id=self.task_id, step=step, key=key, text=text)

    # The other device's result is stored IN the task state ("lateResults"), not
    # only printed, so the audit trail survives a closed terminal or a restart.
    # One entry per (key, text); a repeated LATE_COMPLETION does not add another.
    def _late_entries(self, key: str, outcome: Optional[str] = None) -> List[Dict[str, Any]]:
        return [e for e in self.state.get("lateResults", [])
                if e.get("idempotencyKey") == key and (outcome is None or e.get("outcome") == outcome)]

    def _record_late(self, step: int, key: str, text: str, outcome: str) -> None:
        lst = self.state.setdefault("lateResults", [])
        for e in lst:
            if e.get("idempotencyKey") == key and e.get("result") == text:
                e["outcome"] = outcome
                break
        else:
            lst.append({"step": step, "idempotencyKey": key, "result": text,
                        "receivedAt": now_ms(), "outcome": outcome})
        self.save_state()

    def _compare(self, step: int, key: str, own: str, late: str) -> None:
        """Reference policy: COMPARE AND FLAG. Trimmed exact equality; on a
        difference keep our own result as canonical, log the other."""
        outcome = "match" if own.strip() == late.strip() else "divergence"
        self._record_late(step, key, late, outcome)
        if outcome == "match":
            self.node.log(f"Step {step} (key {key}): late result matches our own exactly - no divergence.")
            self.node.event("late_match", task_id=self.task_id, step=step, key=key)
            return
        self.divergences += 1
        self.node.log(f"WARNING: DIVERGENCE DETECTED - step {step}, key {key}.\n"
                      f'  Our result:  "{own}"\n  Late result: "{late}"\n'
                      "  Policy applied: COMPARE AND FLAG - keeping our own result as canonical, "
                      "late result stored in the task file (lateResults) for audit.")
        self.node.event("divergence", task_id=self.task_id, step=step, key=key, own=own, late=late)


# ------------------------------------------------------------------ mailbox
class Mailbox:
    """Spec 7.5: a persisted queue of finished results, retried until the
    originator is heard and ACKs."""

    def __init__(self, node: "Receiver"):
        self.node = node
        self.path = os.path.join(node.data_dir, "mailbox_queue.json")
        self.queue: List[Dict[str, Any]] = []
        self._lock = threading.Lock()
        self._retry_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = json.load(f)
            if isinstance(raw, list):
                self.queue = [x for x in raw if isinstance(x, dict) and "taskId" in x]
        except (OSError, ValueError):
            pass
        if self.queue:
            self.node.log(f"Mailbox: loaded {len(self.queue)} undelivered result(s) from a previous run.")
        self._thread = threading.Thread(target=self._loop, daemon=True, name="mailbox")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def pending(self) -> int:
        with self._lock:
            return len(self.queue)

    def _save(self) -> None:
        write_json_atomic(self.path, self.queue)

    def enqueue(self, task_id: str, originator_id: str, result: Dict[str, Any]) -> None:
        with self._lock:
            if any(q["taskId"] == task_id for q in self.queue):
                return                                           # dedupe by taskId
            self.queue.append({"taskId": task_id, "originatorId": originator_id, "result": result})
            self._save()
        self.node.log(f"Mailbox: queued result for task {task_id[:8]}, waiting for originator "
                      f"{originator_id} to be seen on the network.")
        threading.Thread(target=self.retry_all, daemon=True).start()   # try at once

    def _loop(self) -> None:
        while not self._stop.wait(self.node.mailbox_retry):
            self.retry_all()

    def retry_all(self) -> None:
        if not self._retry_lock.acquire(blocking=False):
            return
        try:
            with self._lock:
                items = list(self.queue)
            for item in items:
                ip = self.node.peers.ip_of(item["originatorId"])
                if ip is None:
                    continue            # originator not heard recently: expected while it is away
                tid = item["taskId"]
                self.node.log(f"Mailbox: originator {item['originatorId']} is on the network at {ip}"
                              f" - attempting delivery for task {tid[:8]}.")
                reply = send_message(ip, {"type": "RESULT", "taskId": tid, "result": item["result"]},
                                     port=self.node.tcp_port)
                if reply and reply.get("type") == "ACK" and reply.get("taskId") == tid:
                    with self._lock:
                        self.queue = [q for q in self.queue if q["taskId"] != tid]
                        self._save()
                    self.node.log(f"Result delivery confirmed for task {tid[:8]}.")
                    self.node.event("result_delivered", task_id=tid, ip=ip)
                else:
                    self.node.log(f"Result delivery for task {tid[:8]}: no ACK - will retry.")
        finally:
            self._retry_lock.release()


# ----------------------------------------------------------------- receiver
class Receiver:
    def __init__(self, *, data_dir: str, ollama_endpoint: str = "http://127.0.0.1:11434",
                 model: str = "gemma3:1b", device_id: Optional[str] = None,
                 announce_ip: Optional[str] = None, bind_addr: str = "0.0.0.0",
                 battery: int = 80, signal: int = 70,
                 broadcast_addr: str = "255.255.255.255", discovery: bool = True,
                 static_peers: Optional[Dict[str, str]] = None,
                 resume_unfinished: bool = False,
                 tcp_port: int = TCP_PORT, udp_port: int = UDP_PORT, udp_bind: str = "0.0.0.0",
                 announce_interval: float = ANNOUNCE_INTERVAL,
                 step_retry_delay: float = STEP_RETRY_DELAY, mailbox_retry: float = MAILBOX_RETRY,
                 handlers: Optional[Dict[str, Any]] = None, use_langgraph: bool = False,
                 on_event: Optional[Callable[..., None]] = None,
                 log: Optional[Callable[[str], None]] = None):
        os.makedirs(data_dir, exist_ok=True)
        self.data_dir = data_dir
        self.device_id = device_id or load_or_create_device_id(data_dir)
        self.announce_ip = announce_ip or detect_local_ip()
        self.bind_addr, self.battery, self.signal = bind_addr, battery, signal
        self.broadcast_addr, self.discovery = broadcast_addr, discovery
        self.resume_unfinished = resume_unfinished
        self.tcp_port, self.udp_port, self.udp_bind = tcp_port, udp_port, udp_bind
        self.announce_interval = announce_interval
        self.step_retry_delay, self.mailbox_retry = step_retry_delay, mailbox_retry
        if handlers is None:
            if use_langgraph:
                # Optional dependency, imported only when asked for, so the
                # default receiver stays standard-library only.
                import langgraph_task
                handlers = {"summarize": langgraph_task.LangGraphSummarizeTask(
                    sys.modules[__name__], ollama_endpoint, model,
                    os.path.join(data_dir, "langgraph_checkpoints.sqlite"))}
            else:
                handlers = {"summarize": SummarizeTask(ollama_endpoint, model)}
        self.handlers = handlers
        self._on_event, self._log = on_event, log
        self._print_lock = threading.Lock()
        self.peers = PeerTable()
        self.peers.static.update(static_peers or {})
        self.tasks: Dict[str, TaskRunner] = {}
        self._lock = threading.Lock()
        self.mailbox = Mailbox(self)
        self._stop = threading.Event()
        self._server: Optional[socket.socket] = None
        self._threads: List[threading.Thread] = []

    # ---- logging / events
    def log(self, msg: str) -> None:
        if self._log:
            self._log(msg)
            return
        with self._print_lock:
            print(f"[{time.strftime('%H:%M:%S')}] [PY] {msg}", flush=True)

    def event(self, name: str, **kw: Any) -> None:
        if self._on_event:
            self._on_event(name, **kw)

    def task_path(self, task_id: str) -> str:
        return os.path.join(self.data_dir, f"task_{task_id}.json")

    @property
    def busy(self) -> bool:
        with self._lock:
            return any(r.is_active() for r in self.tasks.values())

    # ---- lifecycle
    def start(self) -> None:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if os.name != "nt":      # on Windows, leave exclusive so a clash is reported
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            srv.bind((self.bind_addr, self.tcp_port))
        except OSError as e:
            srv.close()
            raise SystemExit(f"Cannot listen on TCP port {self.tcp_port}: {e}\n"
                             "Is the Dart Target app (or another receiver) already running?")
        srv.listen(16)
        srv.settimeout(0.5)
        self._server = srv
        self._accept_thread = self._spawn(self._accept_loop, "accept")
        self.mailbox.start()
        if self.discovery:
            self._spawn(self._listen_loop, "udp-listen")
            self._spawn(self._announce_loop, "udp-announce")
        if self.resume_unfinished:
            self._recover()
        self.log(f"Listening on TCP {self.bind_addr}:{self.tcp_port} as {self.device_id} "
                 f"(announcing {self.announce_ip}).")

    def stop(self) -> None:
        self._stop.set()
        self.mailbox.stop()
        with self._lock:
            runners = list(self.tasks.values())
        for r in runners:
            r.stop()
        # Wait for the accept loop to exit and close the listening socket,
        # so the port is genuinely free when stop() returns.
        t = getattr(self, "_accept_thread", None)
        if t is not None:
            t.join(timeout=3)

    def _spawn(self, fn: Callable[[], None], name: str) -> threading.Thread:
        t = threading.Thread(target=fn, daemon=True, name=name)
        t.start()
        self._threads.append(t)
        return t

    # ---- TCP server
    def _accept_loop(self) -> None:
        try:
            while not self._stop.is_set():
                try:
                    conn, addr = self._server.accept()          # type: ignore[union-attr]
                except socket.timeout:
                    continue
                except OSError:
                    return
                threading.Thread(target=self._handle, args=(conn, addr), daemon=True).start()
        finally:
            try:
                self._server.close()                            # type: ignore[union-attr]
            except OSError:
                pass

    def _ack(self, conn: socket.socket, task_id: str) -> None:
        try:
            conn.sendall(encode_message({"type": "ACK", "taskId": task_id}))
        except OSError:
            pass

    def _handle(self, conn: socket.socket, addr: Any) -> None:
        try:
            line = read_line(conn, READ_TIMEOUT)
            if line is None:
                return                                   # no complete message: close silently
            try:
                msg = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                self.log(f"Ignoring unparseable message from {addr[0]} (closing, no reply).")
                return
            if not isinstance(msg, dict):
                return
            mtype = msg.get("type")
            if mtype == "STATE":
                self._on_state(conn, msg, addr)
            elif mtype == "RESULT":
                self._on_result(conn, msg)
            elif mtype == "LATE_COMPLETION":
                self._on_late(conn, msg)
            else:
                self.log(f"Unknown message type {mtype!r} from {addr[0]} (closing, no reply).")
        except Exception as e:                                  # noqa: BLE001
            self.log(f"Error while handling a message: {e!r}")
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _refuse(self, reason: str, task_id: str = "?") -> None:
        self.log(f"Refusing STATE for task {task_id[:8]}: {reason} (no ACK, so the sender keeps the task).")
        self.event("state_refused", task_id=task_id, reason=reason)

    def _on_state(self, conn: socket.socket, msg: Dict[str, Any], addr: Any) -> None:
        payload = msg.get("payload")
        err = validate_state(payload)
        if err:
            self._refuse(err)
            return
        task_id = payload["taskId"]
        handler = self.handlers.get(payload.get("taskType", "generic"))
        if handler is None:
            self._refuse(f"unsupported taskType {payload.get('taskType')!r}", task_id)
            return
        with self._lock:
            if task_id in self.tasks:
                duplicate, runner = True, None
            elif any(r.is_active() for r in self.tasks.values()):
                self._refuse("busy with another task", task_id)  # admission control (spec gap 4)
                return
            else:
                duplicate = False
                runner = TaskRunner(self, payload, handler)
                self.tasks[task_id] = runner
        if duplicate:
            self.log(f"Duplicate STATE for task {task_id[:8]}: already have it; ACKing again.")
            self._ack(conn, task_id)
            return
        # Spec 6.2: (2) write to storage, (3) only then ACK, (4) then run.
        try:
            runner.save_state()
        except OSError as e:
            with self._lock:
                self.tasks.pop(task_id, None)
            self._refuse(f"could not save state ({e})", task_id)
            return
        self._ack(conn, task_id)
        self.log(f"State received + persisted locally: task {task_id[:8]}, step "
                 f"{payload['stepIndex']} of {payload['targetStep']}.")
        self.event("state_received", task_id=task_id, step_index=payload["stepIndex"])
        runner.start()

    def _on_result(self, conn: socket.socket, msg: Dict[str, Any]) -> None:
        task_id, result = msg.get("taskId"), msg.get("result")
        if not isinstance(task_id, str) or not isinstance(result, dict):
            return
        try:
            write_json_atomic(os.path.join(self.data_dir, f"result_{task_id}.json"), result)
        except OSError:
            return
        self._ack(conn, task_id)
        self.log(f"Result received + persisted locally for task {task_id[:8]}.")
        self.event("result_received", task_id=task_id, result=result)

    def _on_late(self, conn: socket.socket, msg: Dict[str, Any]) -> None:
        tid, step, key, text = (msg.get("taskId"), msg.get("step"),
                                msg.get("idempotencyKey"), msg.get("resultText"))
        if not (isinstance(tid, str) and _is_int(step) and isinstance(key, str) and isinstance(text, str)):
            return
        self._ack(conn, tid)                  # spec 6.5: ACK first, save nothing
        with self._lock:
            runner = self.tasks.get(tid)
        if runner is None:
            self.log(f"Late completion for unknown task {tid[:8]} (ignored).")
            self.event("late_unknown_task", task_id=tid)
            return
        runner.on_late_completion(step, key, text)

    # ---- recovery (an extension: the Dart reference never reloads saved state)
    def _recover(self) -> None:
        for name in sorted(os.listdir(self.data_dir)):
            if not (name.startswith("task_") and name.endswith(".json")):
                continue
            try:
                with open(os.path.join(self.data_dir, name), "r", encoding="utf-8") as f:
                    state = json.load(f)
            except (OSError, ValueError):
                continue
            if validate_state(state) or state.get("status") == "completed":
                continue
            handler = self.handlers.get(state.get("taskType", "generic"))
            if handler is None or state["taskId"] in self.tasks:
                continue
            self.log(f"Recovering unfinished task {state['taskId'][:8]} from disk "
                     f"(step {state['stepIndex']} of {state['targetStep']}).")
            runner = TaskRunner(self, state, handler)
            with self._lock:
                self.tasks[state["taskId"]] = runner
            runner.start()

    # ---- discovery (UDP)
    def make_announcement(self) -> Dict[str, Any]:
        return {"deviceId": self.device_id, "ip": self.announce_ip, "battery": self.battery,
                "signal": self.signal, "busy": self.busy, "role": "candidate"}

    def _announce_loop(self) -> None:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        warned = False
        try:
            while not self._stop.is_set():
                pkt = json.dumps(self.make_announcement(), ensure_ascii=False,
                                 separators=(",", ":")).encode("utf-8")      # no trailing LF
                try:
                    s.sendto(pkt, (self.broadcast_addr, self.udp_port))
                except OSError as e:
                    if not warned:
                        self.log(f"Could not send announcements to {self.broadcast_addr}: {e}")
                        warned = True
                self._stop.wait(self.announce_interval)
        finally:
            s.close()

    def _listen_loop(self) -> None:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except OSError:
                pass
        try:
            s.bind((self.udp_bind, self.udp_port))
        except OSError as e:
            self.log(f"Cannot listen for announcements on UDP {self.udp_port}: {e}")
            s.close()
            return
        s.settimeout(0.5)
        last_prune = time.monotonic()
        try:
            while not self._stop.is_set():
                try:
                    data, _ = s.recvfrom(65535)
                    ann = parse_announcement(data)
                    if ann:                      # malformed packets are ignored
                        self.peers.update(ann)
                except socket.timeout:
                    pass
                except OSError:
                    break
                if time.monotonic() - last_prune >= PRUNE_EVERY:
                    self.peers.prune()
                    last_prune = time.monotonic()
        finally:
            s.close()


# --------------------------------------------------------------------- main
def main(argv: Optional[List[str]] = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description="Offline Task Handoff Protocol: Python receiver")
    ap.add_argument("--ollama", default="http://127.0.0.1:11434", help="Ollama endpoint (default %(default)s)")
    ap.add_argument("--model", default="gemma3:1b", help="Ollama model (default %(default)s)")
    ap.add_argument("--data-dir", default="receiver_data", help="where state, queue and device id are stored")
    ap.add_argument("--device-id", help="override the saved device id")
    ap.add_argument("--ip", help="IPv4 address to announce (default: auto-detect)")
    ap.add_argument("--bind", default="0.0.0.0", help="address to listen on (default %(default)s)")
    ap.add_argument("--battery", type=int, default=80, help="announced battery 0-100 (simulated)")
    ap.add_argument("--signal", type=int, default=70, help="announced signal 0-100 (simulated)")
    ap.add_argument("--broadcast-addr", default="255.255.255.255",
                    help="UDP broadcast address; try your subnet's (e.g. 192.168.1.255) if 255.255.255.255 is dropped")
    ap.add_argument("--langgraph", action="store_true",
                    help="run each step through a LangGraph graph (needs: pip install langgraph "
                         "langgraph-checkpoint-sqlite)")
    ap.add_argument("--no-discovery", action="store_true", help="do not announce or listen on UDP")
    ap.add_argument("--peer", action="append", default=[], metavar="ID=IP",
                    help="static originator address, e.g. phone1=192.168.1.50 (repeatable)")
    ap.add_argument("--resume-unfinished", action="store_true",
                    help="at startup, resume tasks left unfinished on disk")
    a = ap.parse_args(argv)

    peers: Dict[str, str] = {}
    for p in a.peer:
        if "=" not in p:
            ap.error("--peer needs ID=IP")
        k, v = p.split("=", 1)
        peers[k.strip()] = v.strip()

    r = Receiver(data_dir=a.data_dir, ollama_endpoint=a.ollama, model=a.model, device_id=a.device_id,
                 announce_ip=a.ip, bind_addr=a.bind, battery=a.battery, signal=a.signal,
                 broadcast_addr=a.broadcast_addr, discovery=not a.no_discovery,
                 static_peers=peers, resume_unfinished=a.resume_unfinished,
                 use_langgraph=a.langgraph)
    r.start()
    r.log(f"Model {a.model} via {normalize_endpoint(a.ollama)}. Waiting for a handoff. Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        r.log("Stopping.")
        r.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
