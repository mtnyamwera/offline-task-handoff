#!/usr/bin/env python3
"""
End-to-end tests for receiver.py, run entirely on this machine.

  * FakeOllama  : a tiny HTTP server that answers /api/generate
  * FakePhone   : plays the originator (receives RESULT, sends STATE etc.)
  * Receiver    : the real receiver.py, on its own loopback address and ports

Nothing here touches your network, your real Ollama, or the default ports
5891/5892, so it is safe to run while the real receiver or the Dart app is
running.   Usage:   python test_end_to_end.py        (add -v for the receiver's log)
"""
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import receiver as R

PHONE_ID = "phone-test-1"
RECV_IP, PHONE_IP = "127.0.0.2", "127.0.0.3"
VERBOSE = "-v" in sys.argv
CHUNKS5 = ["Alpha \u2019quoted\u2019 \u2014 dash", "Beta \u2013 en dash", "Gamma \u26a0 warning",
           "Delta \u2019x\u2019 text", "Epsilon \u2014 the end"]

results = []
_port = [21000]


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"   [{detail}]" if (detail and not cond) else ""))


def next_port():
    _port[0] += 10
    return _port[0]


def wait_for(pred, timeout=20.0, step=0.05):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(step)
    return False


# ---------------------------------------------------------------- test doubles
class FakeOllama:
    """behaviour(n, prompt) -> (http_status, response_text_or_None, delay_seconds)"""

    def __init__(self, behaviour=None):
        self.prompts = []
        self.behaviour = behaviour or (lambda n, p: (200, None, 0.0))
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8"))
                outer.prompts.append(body["prompt"])
                n = len(outer.prompts)
                status, text, delay = outer.behaviour(n, body["prompt"])
                if delay:
                    time.sleep(delay)
                if status != 200:
                    data = b'{"error":"simulated failure"}'
                    self.send_response(status)
                else:
                    k = re.search(r"New section \((\d+) of", body["prompt"]).group(1)
                    resp = text if text is not None else f"Here\u2019s an updated summary:\nS{k} \u2014 done"
                    data = json.dumps({"response": resp}).encode("utf-8")
                    self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class FakePhone:
    """The originator: listens for RESULT and ACKs it."""

    def __init__(self, port, ip=PHONE_IP):
        self.port, self.ip, self.results = port, ip, []
        self._stop = threading.Event()
        self.srv = None

    def start(self):
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.ip, self.port))
        s.listen(8)
        s.settimeout(0.3)
        self.srv = s
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while not self._stop.is_set():
            try:
                c, _ = self.srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._one, args=(c,), daemon=True).start()

    def _one(self, c):
        try:
            line = R.read_line(c, 5)
            if line is None:
                return
            msg = json.loads(line.decode("utf-8"))
            if msg.get("type") == "RESULT":
                self.results.append(msg)
                c.sendall(R.encode_message({"type": "ACK", "taskId": msg["taskId"]}))
        finally:
            c.close()

    def stop(self):
        self._stop.set()
        if self.srv:
            self.srv.close()


def exchange(port, pieces, pause=0.0, wait=5.0, half_close=False, ip=RECV_IP):
    """Send `pieces` (bytes) in separate TCP writes; return the parsed reply
    line, or None if the receiver closed/stayed silent (a refusal)."""
    s = socket.create_connection((ip, port), timeout=5)
    try:
        for i, p in enumerate(pieces):
            s.sendall(p)
            if pause and i < len(pieces) - 1:
                time.sleep(pause)
        if half_close:
            s.shutdown(socket.SHUT_WR)
        s.settimeout(wait)
        buf = b""
        while b"\n" not in buf:
            try:
                c = s.recv(65536)
            except socket.timeout:
                return None
            if not c:
                return None
            buf += c
        return json.loads(buf.split(b"\n")[0].decode("utf-8"))
    finally:
        s.close()


def state_line(state):
    return R.encode_message({"type": "STATE", "payload": state})


def make_state(task_id, chunks, step_index, pending_key=None, running_summary="",
               task_type="summarize", status="running", extra_log=None):
    log = [{"step": i, "idempotencyKey": f"k{i}-{task_id}", "status": "completed",
            "result": f"S{i}", "timestamp": 1} for i in range(1, step_index + 1)]
    log += extra_log or []
    return {"taskId": task_id, "originatorId": PHONE_ID, "stepIndex": step_index,
            "targetStep": len(chunks), "status": status,
            "pendingAction": ({"idempotencyKey": pending_key, "forStep": step_index + 1, "startedAt": 1}
                              if pending_key else None),
            "log": log, "taskType": task_type,
            "data": {"chunks": chunks, "runningSummary": running_summary}}


class Rig:
    """One receiver + its fakes, with an event recorder."""

    def __init__(self, ollama, port, data_dir=None, with_phone=True, **kw):
        self.tmp = data_dir or tempfile.mkdtemp(prefix="rcv_")
        self.port, self.ollama = port, ollama
        self.events, self._ev_lock, self.logs = [], threading.Lock(), []
        self.phone = FakePhone(port)
        if with_phone:
            self.phone.start()
        self.r = self.make(**kw)
        self.r.start()

    def make(self, **kw):
        def on_event(name, **k):
            with self._ev_lock:
                self.events.append((name, k))
        opts = dict(data_dir=self.tmp, ollama_endpoint=self.ollama.url, model="test-model",
                    device_id="py-test", announce_ip=RECV_IP, bind_addr=RECV_IP, discovery=False,
                    static_peers={PHONE_ID: PHONE_IP}, tcp_port=self.port, step_retry_delay=0.2,
                    mailbox_retry=0.4, on_event=on_event,
                    log=self._record_log)
        opts.update(kw)
        return R.Receiver(**opts)

    def _record_log(self, m):
        self.logs.append(m)
        if VERBOSE:
            print("        | " + m.replace("\n", "\n        | "))

    def names(self, n=None):
        with self._ev_lock:
            return [e for e in self.events if n is None or e[0] == n]

    def saved(self, task_id):
        with open(os.path.join(self.tmp, f"task_{task_id}.json"), encoding="utf-8") as f:
            return json.load(f)

    def close(self):
        self.r.stop()
        self.phone.stop()
        self.ollama.stop()
        time.sleep(0.1)
        shutil.rmtree(self.tmp, ignore_errors=True)


# ------------------------------------------------------------------ scenarios
def scenario_core():
    print("\nA. Handoff mid-step: framing, ACK-after-save, resume, late completion, delivery")
    port = next_port()
    k3 = str(uuid.uuid4())
    rig = Rig(FakeOllama(lambda n, p: (200, None, 1.0 if n == 1 else 0.0)), port)
    try:
        state = make_state("task-A", CHUNKS5, 2, pending_key=k3, running_summary="BASE-SUMMARY-2")
        line = state_line(state)
        i = next(j for j, b in enumerate(line) if b >= 0x80) + 1          # inside the first multi-byte char
        pieces = [line[:i], line[i:]]
        try:
            pieces[0].decode("utf-8")
            split_ok = False
        except UnicodeDecodeError:
            split_ok = True
        check("setup: first TCP write ends in the middle of a UTF-8 character", split_ok)

        t0 = time.time()
        reply = exchange(port, pieces, pause=0.3)
        ack_after = time.time() - t0 - 0.3
        check("STATE split inside a UTF-8 character is parsed and ACKed",
              reply == {"type": "ACK", "taskId": "task-A"}, reply)
        check("ACK is sent before the task runs (model call takes 1 s, ACK took %.2f s)" % ack_after,
              ack_after < 0.8, ack_after)
        saved = rig.saved("task-A")
        check("snapshot was already on disk when the ACK arrived",
              saved["stepIndex"] == 2 and saved["pendingAction"]["idempotencyKey"] == k3, saved)

        t1 = time.time()
        late = exchange(port, [R.encode_message({"type": "LATE_COMPLETION", "taskId": "task-A", "step": 3,
                                                 "idempotencyKey": k3, "resultText": "PHONE VERSION \u2019 of step 3"})])
        check("LATE_COMPLETION is ACKed immediately", late == {"type": "ACK", "taskId": "task-A"}
              and time.time() - t1 < 0.5, late)
        check("late result arriving while our own attempt is in flight is HELD",
              wait_for(lambda: rig.names("late_held"), 2))

        check("task runs to completion", wait_for(lambda: rig.names("task_completed"), 20))
        check("held result is compared when ours finishes: divergence flagged (once)",
              len(rig.names("divergence")) == 1 and rig.names("divergence")[0][1]["key"] == k3,
              rig.names("divergence"))

        p = rig.ollama.prompts
        check("exactly 3 model calls: steps 3, 4, 5 (step 3 re-run, steps 1-2 not repeated)", len(p) == 3, len(p))
        check("step 3 prompt = the phone's summary + chunk 3 + 'New section (3 of 5)'",
              "Summary so far:\nBASE-SUMMARY-2" in p[0] and "New section (3 of 5):\n" + CHUNKS5[2] in p[0])
        check("step 4 prompt carries step 3's output with the preamble stripped",
              "Summary so far:\nS3 \u2014 done\n" in p[1] and "Here" not in p[1].split("New section")[0].split("Summary so far:")[1])
        check("prompt wording is byte-identical to the Dart prompt",
              R.build_summary_prompt(2, 7, "CHUNK", "SUM") ==
              "You are summarizing a document one section at a time.\n\nSummary so far:\nSUM\n\n"
              "New section (2 of 7):\nCHUNK\n\nWrite an updated summary that covers everything so far, "
              "including this new section. Keep the important points from the earlier sections; do not "
              "drop them to make room. Use only information from the text above. Use at most 150 words. "
              "Start directly with the summary, with no introduction.")

        check("RESULT delivered to the originator", wait_for(lambda: rig.phone.results, 10))
        res = rig.phone.results[0]["result"] if rig.phone.results else {}
        check("RESULT content: taskId, 5 steps, finishedBy, taskType, 5 chunks, cleaned summary",
              rig.phone.results and rig.phone.results[0]["taskId"] == "task-A" and res.get("completedSteps") == 5
              and res.get("finishedBy") == "py-test" and res.get("taskType") == "summarize"
              and res.get("chunks") == 5 and res.get("summary") == "S5 \u2014 done", res)
        check("mailbox queue is empty after the ACK", wait_for(lambda: rig.r.mailbox.pending() == 0, 3))

        final = rig.saved("task-A")
        step3 = [e for e in final["log"] if e["step"] == 3 and e["idempotencyKey"] == k3]
        check("final saved state: completed, stepIndex 5, step 3 logged under the SAME key",
              final["status"] == "completed" and final["stepIndex"] == 5 and len(step3) == 1
              and step3[0]["status"] == "completed", final)

        # late completions that arrive AFTER we finished
        exchange(port, [R.encode_message({"type": "LATE_COMPLETION", "taskId": "task-A", "step": 3,
                                          "idempotencyKey": k3, "resultText": "S3 \u2014 done"})])
        check("late result identical to ours: 'match', no divergence", wait_for(lambda: rig.names("late_match"), 2))
        exchange(port, [R.encode_message({"type": "LATE_COMPLETION", "taskId": "task-A", "step": 3,
                                          "idempotencyKey": k3, "resultText": "something different"})])
        check("late result different from ours (after we finished): divergence flagged",
              wait_for(lambda: len(rig.names("divergence")) == 2, 2))
        exchange(port, [R.encode_message({"type": "LATE_COMPLETION", "taskId": "task-A", "step": 9,
                                          "idempotencyKey": "no-such-key", "resultText": "x"})])
        check("late result for a key we never ran: recorded as orphan, not a divergence",
              wait_for(lambda: rig.names("late_orphan"), 2) and len(rig.names("divergence")) == 2)
        # the audit trail is in the saved task file, not only in the terminal
        lr = rig.saved("task-A").get("lateResults", [])
        by = {e["result"]: e for e in lr}
        check("saved task file keeps every late result (4 entries) with step, key and receive time",
              len(lr) == 4 and all(e["idempotencyKey"] and e["receivedAt"] and "step" in e for e in lr), lr)
        check("outcomes recorded: held->divergence, match, divergence, orphan",
              by["PHONE VERSION \u2019 of step 3"]["outcome"] == "divergence"
              and by["S3 \u2014 done"]["outcome"] == "match"
              and by["something different"]["outcome"] == "divergence"
              and by["x"]["outcome"] == "orphan", lr)
        exchange(port, [R.encode_message({"type": "LATE_COMPLETION", "taskId": "task-A", "step": 3,
                                          "idempotencyKey": k3, "resultText": "something different"})])
        time.sleep(0.4)
        check("a repeated identical LATE_COMPLETION does not add a duplicate entry",
              len(rig.saved("task-A").get("lateResults", [])) == 4)
        check("late results do not change the task's own content (I2): summary and log untouched",
              rig.saved("task-A")["data"]["runningSummary"] == "S5 \u2014 done"
              and len([e for e in rig.saved("task-A")["log"] if e["step"] == 3]) == 1)
        unk = exchange(port, [R.encode_message({"type": "LATE_COMPLETION", "taskId": "ghost", "step": 1,
                                                "idempotencyKey": "k", "resultText": "x"})])
        check("late completion for an unknown task is still ACKed", unk == {"type": "ACK", "taskId": "ghost"}, unk)
    finally:
        rig.close()


def scenario_retry_same_key():
    print("\nB. A failed step is retried under the SAME key (invariants I3 and I4)")
    port = next_port()
    k3 = str(uuid.uuid4())
    rig = Rig(FakeOllama(lambda n, p: (500, None, 0.0) if n == 1 else (200, None, 0.0)), port)
    try:
        reply = exchange(port, [state_line(make_state("task-B", CHUNKS5, 2, pending_key=k3, running_summary="B2"))])
        check("STATE ACKed", reply == {"type": "ACK", "taskId": "task-B"}, reply)
        check("task completes despite the first model call failing", wait_for(lambda: rig.names("task_completed"), 20))
        fails, oks = rig.names("step_failed"), [e for e in rig.names("step_completed") if e[1]["step"] == 3]
        check("one failure then one success for step 3, both under key K3",
              len(fails) == 1 and len(oks) == 1 and fails[0][1]["key"] == k3 and oks[0][1]["key"] == k3)
        entries = [e for e in rig.saved("task-B")["log"] if e["step"] == 3]
        check("log is append-only: step 3 has [failed, completed], same key, failure text starts 'error:'",
              [e["status"] for e in entries] == ["failed", "completed"]
              and {e["idempotencyKey"] for e in entries} == {k3} and entries[0]["result"].startswith("error:"), entries)
        check("model was called twice for step 3 (retry), then steps 4 and 5", len(rig.ollama.prompts) == 4,
              len(rig.ollama.prompts))
        check("a failed attempt did not change the running summary (I2)",
              "Summary so far:\nB2" in rig.ollama.prompts[1])
    finally:
        rig.close()


def scenario_skip_rule():
    print("\nC. Resume rule: a pending step already completed in the log is skipped")
    port = next_port()
    k3 = str(uuid.uuid4())
    rig = Rig(FakeOllama(), port)
    try:
        done = [{"step": 3, "idempotencyKey": k3, "status": "completed", "result": "S3 pre-done", "timestamp": 1}]
        st = make_state("task-C", CHUNKS5, 2, pending_key=k3, running_summary="S3 pre-done", extra_log=done)
        reply = exchange(port, [state_line(st)])
        check("STATE ACKed", reply == {"type": "ACK", "taskId": "task-C"}, reply)
        check("task completes", wait_for(lambda: rig.names("task_completed"), 20))
        p = rig.ollama.prompts
        check("step 3 was NOT re-run: only steps 4 and 5 hit the model", len(p) == 2 and "(4 of 5)" in p[0], len(p))
        check("final stepIndex is 5", rig.saved("task-C")["stepIndex"] == 5)
    finally:
        rig.close()


def scenario_admission_and_invalid():
    print("\nD. Admission control, duplicate STATE, unsupported type, invalid messages")
    port = next_port()
    rig = Rig(FakeOllama(lambda n, p: (200, None, 0.5)), port)
    try:
        c3 = CHUNKS5[:3]
        check("task D1 accepted", exchange(port, [state_line(make_state("task-D1", c3, 0))]) ==
              {"type": "ACK", "taskId": "task-D1"})
        check("announcement says busy while running", rig.r.make_announcement()["busy"] is True)
        check("a DIFFERENT task while busy is refused (no ACK, connection closed)",
              exchange(port, [state_line(make_state("task-D2", c3, 0))]) is None)
        check("refusal is recorded with reason 'busy'",
              any("busy" in e[1].get("reason", "") for e in rig.names("state_refused")))
        check("the SAME task sent again is ACKed without restarting it",
              exchange(port, [state_line(make_state("task-D1", c3, 0))]) == {"type": "ACK", "taskId": "task-D1"})
        check("unsupported taskType is refused",
              exchange(port, [state_line(make_state("task-X", c3, 0, task_type="other"))]) is None)
        check("unknown message type: no reply, connection closed",
              exchange(port, [R.encode_message({"type": "HELLO"})]) is None)
        check("garbage that is not JSON: no reply",
              exchange(port, [b"this is not json\n"]) is None)
        check("invalid UTF-8 bytes: no reply", exchange(port, [b"\xff\xfe\xfd\n"]) is None)
        check("message with no LF before the sender closes: no reply",
              exchange(port, [b'{"type":"STATE"'], half_close=True) is None)
        check("STATE with a missing field is refused",
              exchange(port, [R.encode_message({"type": "STATE", "payload": {"taskId": "t"}})]) is None)

        check("D1 finishes and its RESULT is delivered exactly once",
              wait_for(lambda: len(rig.phone.results) == 1, 20))
        time.sleep(0.6)
        check("no model call was ever made for the refused task D2",
              all("task-D2" not in p for p in rig.ollama.prompts) and len(rig.ollama.prompts) == 3, len(rig.ollama.prompts))
        check("once idle, announcement says busy=false", wait_for(lambda: rig.r.make_announcement()["busy"] is False, 3))
        check("after finishing, a new task is accepted again",
              exchange(port, [state_line(make_state("task-D3", c3, 0))]) == {"type": "ACK", "taskId": "task-D3"})
        check("D3 completes too", wait_for(lambda: len(rig.phone.results) == 2, 20))
    finally:
        rig.close()


def scenario_mailbox():
    print("\nE. Mailbox: originator away, queue persisted, survives a receiver restart, delivered on return")
    port = next_port()
    rig = Rig(FakeOllama(), port, with_phone=False)
    try:
        exchange(port, [state_line(make_state("task-E", CHUNKS5, 3, pending_key=str(uuid.uuid4())))])
        check("task completes while the phone is away", wait_for(lambda: rig.names("task_completed"), 20))
        qpath = os.path.join(rig.tmp, "mailbox_queue.json")
        check("result is in the persisted queue file",
              wait_for(lambda: os.path.exists(qpath) and len(json.load(open(qpath))) == 1, 3))
        time.sleep(1.0)
        check("still queued after several retries with nobody there", rig.r.mailbox.pending() == 1)

        rig.r.stop()
        rig.r = rig.make()                    # a NEW receiver process, same data dir
        rig.r.start()
        check("restarted receiver reloads the undelivered result",
              rig.r.mailbox.pending() == 1 and any("loaded 1 undelivered" in m for m in rig.logs))
        rig.phone.start()                     # the originator comes back
        check("RESULT delivered after the phone returns", wait_for(lambda: rig.phone.results, 10))
        check("queue file is empty after the ACK", wait_for(lambda: json.load(open(qpath)) == [], 3))
        check("delivered exactly once", len(rig.phone.results) == 1, len(rig.phone.results))
    finally:
        rig.close()


def scenario_recovery():
    print("\nF. Recovery (extension): unfinished task on disk is resumed; completed/corrupt files are ignored")
    port = next_port()
    tmp = tempfile.mkdtemp(prefix="rcv_rec_")
    k4 = str(uuid.uuid4())
    for name, obj in [("task_task-F.json", make_state("task-F", CHUNKS5, 3, pending_key=k4, running_summary="F3")),
                      ("task_task-done.json", make_state("task-done", CHUNKS5, 5, status="completed"))]:
        with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
            json.dump(obj, f)
    with open(os.path.join(tmp, "task_bad.json"), "w") as f:
        f.write("{not json")
    rig = Rig(FakeOllama(), port, data_dir=tmp, resume_unfinished=True)
    try:
        check("unfinished task resumed and finished", wait_for(lambda: rig.names("task_completed"), 20))
        p = rig.ollama.prompts
        check("resumed at step 4 under the pending key (steps 4,5 only)", len(p) == 2 and "(4 of 5)" in p[0], len(p))
        check("its RESULT is delivered", wait_for(lambda: rig.phone.results and
                                                  rig.phone.results[0]["taskId"] == "task-F", 10))
        check("completed and corrupt files did not start anything",
              set(rig.r.tasks) == {"task-F"}, list(rig.r.tasks))
    finally:
        rig.close()


def scenario_discovery_and_units():
    print("\nG. Discovery packets, expiry, and small units")
    ok = R.parse_announcement
    base = {"deviceId": "d1", "ip": "10.0.0.5", "battery": 80, "signal": 70, "busy": False, "role": "originator"}
    enc = lambda d: json.dumps(d).encode("utf-8")
    check("valid announcement parses", ok(enc(base)) == base)
    nr = dict(base); del nr["role"]
    check("missing role defaults to 'candidate'", ok(enc(nr))["role"] == "candidate")
    check("unknown extra fields are ignored", ok(enc(dict(base, extra=1))) is not None)
    check("malformed packets are ignored (bad JSON, bad UTF-8, wrong types, missing fields)",
          ok(b"nope") is None and ok(b"\xff\xfe") is None and ok(enc(dict(base, battery="80"))) is None
          and ok(enc(dict(base, busy=1))) is None and ok(enc({"deviceId": "x"})) is None and ok(b"[1,2]") is None)

    now = [0.0]
    pt = R.PeerTable(clock=lambda: now[0])
    pt.update(base)
    now[0] = 5.9
    pt.prune()
    check("peer still known after 5.9 s of silence", pt.ip_of("d1") == "10.0.0.5")
    now[0] = 6.1
    pt.prune()
    check("peer expires after more than 6 s of silence", pt.ip_of("d1") is None)
    pt.static["d1"] = "1.2.3.4"
    check("a static peer address overrides discovery", pt.ip_of("d1") == "1.2.3.4")

    check("clean_summary strips the preambles seen in the real logs",
          R.clean_summary("Here\u2019s an updated summary: \nOffline-first software") == "Offline-first software"
          and R.clean_summary("Here\u2019s a consolidated summary of the document: \nX y") == "X y"
          and R.clean_summary("Offline-first is key: it works") == "Offline-first is key: it works"
          and R.clean_summary("Here is a summary:") == "Here is a summary:")
    cs = R.clean_summary
    real = "**Summary:**\n\nSoftware aimed at sustained functionality without a stable internet."
    check("clean_summary strips **Summary:** + blank line (real log string)",
          cs(real) == "Software aimed at sustained functionality without a stable internet.")
    cases = [
        ("Summary:\nText here", "Text here"),
        ("**Updated Summary:**\n\nText here", "Text here"),
        ("**Summary**\nText here", "Text here"),
        ("## Summary\n\nText here", "Text here"),
        ("__Final Summary so far:__\r\n\r\nText here", "Text here"),
        ("**Summary:** Text here", "Text here"),
        ("Summary: Text here", "Text here"),
        ("Here's an updated summary:\n\n**Summary:**\n\nText here", "Text here"),
        # must NOT be damaged
        ("Summary statistics are useful", "Summary statistics are useful"),
        ("Summary of the report is short", "Summary of the report is short"),
        ("Offline-first is key: it works", "Offline-first is key: it works"),
        ("The summary: it works", "The summary: it works"),
        ("**Summary:**", "**Summary:**"),            # nothing left -> keep original
        ("Summary:", "Summary:"),
    ]
    bad = [(i, cs(i), o) for i, o in cases if cs(i) != o]
    check("clean_summary label cases (strip labels, leave real content alone)", not bad, str(bad))
    check("clean_summary is idempotent on cleaned text",
          all(cs(cs(i)) == cs(i) for i, _ in cases))
    dart = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "user_lib", "lib",
                             "services", "summary_task.dart"), encoding="utf-8").read() \
        if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "user_lib")) else None
    if dart is None:
        print("  SKIP  Dart/Python pattern parity (Dart source not next to receiver)")
    else:
        def dart_pat(name):
            m = re.search(r"const String " + name + r"\s*=\s*\n?\s*r\"(.*)\";", dart)
            return m.group(1) if m else None
        check("Dart and Python cleanup patterns are textually identical",
              dart_pat("kPreamblePattern") == R._PREAMBLE_SRC
              and dart_pat("kLabelLinePattern") == R._LABEL_LINE_SRC
              and dart_pat("kLabelInlinePattern") == R._LABEL_INLINE_SRC)
    check("endpoint cleanup (trailing slash, pasted /api/generate, missing http://)",
          R.normalize_endpoint("http://192.168.1.227:11434/") == "http://192.168.1.227:11434"
          and R.normalize_endpoint("192.168.1.227:11434/api/generate") == "http://192.168.1.227:11434")
    line = R.encode_message({"a": "x\ny \u2019"})
    check("encoded message is one line ended by exactly one LF, non-ASCII kept raw",
          line.count(b"\n") == 1 and line.endswith(b"\n") and "\u2019".encode("utf-8") in line)

    # live UDP loopback: the receiver announces and hears itself
    port, uport = next_port(), next_port() + 1
    rig = Rig(FakeOllama(), port, discovery=True, broadcast_addr="127.0.0.1", udp_bind="127.0.0.1",
              udp_port=uport, announce_interval=0.2)
    try:
        check("announcement is heard over UDP and recorded in the peer table",
              wait_for(lambda: "py-test" in rig.r.peers.ids(), 4))
        ann = rig.r.make_announcement()
        pkt = json.dumps(ann, separators=(",", ":")).encode()
        check("announcement has every field of spec 4.1 and no trailing LF",
              set(ann) == {"deviceId", "ip", "battery", "signal", "busy", "role"} and b"\n" not in pkt
              and ann["role"] == "candidate" and ann["ip"] == RECV_IP)
    finally:
        rig.close()


def scenario_langgraph():
    print("\nH. The summarize step run by LangGraph (--langgraph)")
    try:
        import langgraph_task as L
    except ImportError as e:
        print("  SKIP  langgraph not installed:", e)
        return
    # H1: end to end, failing first call, same key, label cleaning
    port = next_port()
    k3 = str(uuid.uuid4())
    labelled = lambda n, p: (200, "**Summary:**\n\nText " + re.search(r"New section \((\d+) of", p).group(1), 0.0) \
        if n != 1 else (500, None, 0.0)
    rig = Rig(FakeOllama(labelled), port, use_langgraph=True)
    try:
        reply = exchange(port, [state_line(make_state("task-H", CHUNKS5, 2, pending_key=k3, running_summary="H2"))])
        check("STATE ACKed (LangGraph handler)", reply == {"type": "ACK", "taskId": "task-H"}, reply)
        check("task completes despite the first model call failing", wait_for(lambda: rig.names("task_completed"), 20))
        entries = [e for e in rig.saved("task-H")["log"] if e["step"] == 3]
        check("step 3 log is [failed, completed] under the SAME key K3 (protocol bookkeeping unchanged)",
              [e["status"] for e in entries] == ["failed", "completed"]
              and {e["idempotencyKey"] for e in entries} == {k3}, entries)
        check("model called 4 times (step 3 twice, then 4 and 5): graph retry did not add calls",
              len(rig.ollama.prompts) == 4, len(rig.ollama.prompts))
        saved = rig.saved("task-H")
        check("stored summary is clean: no '**Summary:**' label reached TaskState",
              saved["data"]["runningSummary"] == "Text 5" and all("**" not in e["result"] for e in saved["log"] if e["step"] > 2),
              saved["data"]["runningSummary"])
        check("the next prompt carries the cleaned summary, not the label",
              "Summary so far:\nText 3" in rig.ollama.prompts[2])
        check("a checkpoint database exists on this machine only",
              os.path.exists(os.path.join(rig.tmp, "langgraph_checkpoints.sqlite")))
    finally:
        rig.close()

    # H2: identical prompts and identical stored state to the plain handler
    outs = []
    for use_lg in (False, True):
        port = next_port()
        rig = Rig(FakeOllama(), port, use_langgraph=use_lg)
        try:
            exchange(port, [state_line(make_state("task-P", CHUNKS5, 2, pending_key="kP", running_summary="P2"))])
            wait_for(lambda: rig.names("task_completed"), 20)
            sv = rig.saved("task-P")
            outs.append((list(rig.ollama.prompts), sv["data"], [(e["step"], e["status"], e["result"]) for e in sv["log"]]))
        finally:
            rig.close()
    check("plain and LangGraph handlers send identical prompts and store identical task data/log",
          outs[0] == outs[1])

    # H3: unit-level: same key -> stored result, no second model call; crash mid-graph resumes
    fo = FakeOllama()
    d = tempfile.mkdtemp()
    try:
        h = L.LangGraphSummarizeTask(R, fo.url, "m", os.path.join(d, "cp.sqlite"))
        st = make_state("task-U", CHUNKS5, 0)
        st["pendingAction"] = {"idempotencyKey": "KU1", "forStep": 1, "startedAt": 1}
        a = h.run_step(1, st)
        b = h.run_step(1, st)
        check("re-running a finished step under the same key returns the stored result, no new model call",
              a == b and len(fo.prompts) == 1, (a, b, len(fo.prompts)))
        st["pendingAction"] = {"idempotencyKey": "KU2", "forStep": 2, "startedAt": 1}
        orig, boom = R.clean_summary, [True]

        def flaky(x):
            if boom[0]:
                boom[0] = False
                raise RuntimeError("simulated crash after the model call")
            return orig(x)
        R.clean_summary = flaky
        try:
            try:
                h.run_step(2, st)
                raised = False
            except RuntimeError:
                raised = True
            calls_before = len(fo.prompts)
            c = h.run_step(2, st)
        finally:
            R.clean_summary = orig
        check("a crash after the model call: the retry resumes at the next node, model NOT called again",
              raised and len(fo.prompts) == calls_before and c, (raised, calls_before, len(fo.prompts)))
        h.close()
        h2 = L.LangGraphSummarizeTask(R, fo.url, "m", os.path.join(d, "cp.sqlite"))     # 'restart'
        e2 = h2.run_step(2, st)
        check("after reopening the database (process restart) the finished step is still remembered",
              e2 == c and len(fo.prompts) == calls_before)
        h2.close()
        st["pendingAction"] = {"idempotencyKey": "KOTHER", "forStep": 2, "startedAt": 1}
        h3 = L.LangGraphSummarizeTask(R, fo.url, "m", os.path.join(d, "cp.sqlite"))
        h3.run_step(2, st)
        check("a different key (e.g. a step the other device started) is NOT served from the cache",
              len(fo.prompts) == calls_before + 1)
        st["pendingAction"] = None
        try:
            h3.run_step(2, st)
            untagged = False
        except RuntimeError:
            untagged = True
        check("an untagged step is refused (invariant I1 is enforced, not assumed)", untagged)
        h3.close()
    finally:
        fo.stop()
        shutil.rmtree(d, ignore_errors=True)


def main():
    scenario_core()
    scenario_retry_same_key()
    scenario_skip_rule()
    scenario_admission_and_invalid()
    scenario_mailbox()
    scenario_recovery()
    scenario_discovery_and_units()
    scenario_langgraph()
    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    for name, ok in results:
        if not ok:
            print("  FAILED:", name)
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
