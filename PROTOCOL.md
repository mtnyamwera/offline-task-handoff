# Offline Task Handoff Protocol — Draft 0.2

**Status:** draft. Written from the Dart reference implementation and checked against a second implementation in Python. If this document and the code disagree, the code is what actually runs. Items marked **[gap]** are known weaknesses of the reference implementations, not features.

**What 0.2 changes from 0.1**

- Late results are stored in the task state (`lateResults`, sections 5.1, 6.5, 7.4), including a result that is being held, so the audit trail survives a restart. 0.1 only logged them.
- Guarantee G5 added (section 10).
- Section 11 now says which known gaps each implementation has closed. Gaps 1 and 4 are closed in the Python receiver and still open in the Dart app. Gap 9 is closed in both.
- Section 12 lists the interoperability tests that have actually been run, and by whom.

**Evidence level.** A phone running the Dart app handed tasks to the Python receiver on a real network several times, and the task finished and the result returned. The Python receiver is also covered by an automated suite of 90 checks, using a fake phone that the author wrote from this same document, so that suite shows consistency with this text and not independent interoperability. The protocol has not been tested with more than two devices, over a lossy network, or with any security layer.

## 1. Purpose and scope

The protocol moves a running, multi-step task from one device to another on the same local network, with **no server and no internet**, so that:

1. work is not lost when a device leaves or dies,
2. an unfinished step is never silently skipped,
3. the finished result gets back to the device that started the task.

**Out of scope:** what a step actually does (it is opaque to the protocol), security, wide-area networks, and the radio itself. The reference implementation uses WiFi/LAN; Bluetooth or WiFi Direct could replace it without changing the rules in sections 5 to 7.

## 2. Roles

| Role | Meaning | Announced as |
|---|---|---|
| **originator** | Created the task and wants its result. | `"role":"originator"` |
| **candidate** | Willing to take over a task. | `"role":"candidate"` |
| **owner** | The device currently running the task. Changes at each handoff. | n/a |

One device can hold several roles over time. In the reference app the phone is the originator and first owner, and the laptop is a candidate that becomes the owner.

## 3. Conventions

| Item | Rule |
|---|---|
| Ports | UDP **5892** for discovery, TCP **5891** for messages |
| Encoding | UTF-8 JSON |
| TCP framing | One message is one JSON object on a single line, ended by one LF byte (`0x0A`). A raw LF never appears inside the JSON, because newlines inside strings are escaped as `\n`. |
| Connections | One message per TCP connection. The receiver replies on the same connection, then closes it. |
| Decoding order | Receivers MUST find the LF in the **raw bytes first**, then decode UTF-8. Decoding each network chunk separately can split a multi-byte character and fail. |
| IDs | Opaque strings. `taskId` and `idempotencyKey` are UUID v4 in the reference app. `deviceId` must stay the same across restarts (reference: base-36 millisecond timestamp plus 3 digits, saved to a file). |
| Timestamps | Integer milliseconds since the Unix epoch. Informational only. Device clocks are not synchronised, so never compare timestamps across devices. |

## 4. Discovery (UDP)

Every device that wants to be found sends an announcement, and every device that wants to find others listens.

### 4.1 Announcement

```json
{"deviceId":"muwpml5k643","ip":"192.168.1.182","battery":80,"signal":70,"busy":false,"role":"originator"}
```

| Field | Type | Meaning |
|---|---|---|
| `deviceId` | string | Stable device identity |
| `ip` | string | Sender's own IPv4 address (first non-loopback address found). Peers use **this**, not the datagram's source address. |
| `battery` | int 0 to 100 | Remaining battery. **Simulated by a slider in the reference app.** |
| `signal` | int 0 to 100 | Link quality. **Simulated by a slider in the reference app.** |
| `busy` | bool | `true` if this device is currently running a task |
| `role` | string | `"candidate"` or `"originator"`. Treated as `"candidate"` if missing. |

The payload has no trailing LF.

### 4.2 Rules

- **Send:** every **2 s**, as a UDP broadcast to `255.255.255.255:5892`.
- **Listen:** bind UDP 5892 with address reuse. Parse each datagram as JSON and **ignore anything malformed**. Keep a table keyed by `deviceId` with the local time each entry was last heard.
- **Expire:** remove an entry not refreshed for more than **6 s** (checked every 2 s). This is the only way a device is known to have left. There is no goodbye message.
- A device hears its own announcements. Ignore them when picking a candidate.

### 4.3 Choosing a candidate

Among entries with `role == "candidate"` and `deviceId` different from your own:

```
score = 0.6 * battery + 0.4 * signal      (minus 1000 if busy)
```

The highest score wins. A busy candidate is not excluded. It only scores very low, so it is still chosen if it is the only one **[gap 4]**.

## 5. Task state

The task state is the thing that moves between devices. The protocol understands only the generic fields. Everything specific to the task lives in `data`.

### 5.1 TaskState

| Field | Type | Meaning |
|---|---|---|
| `taskId` | string | Identity of the task |
| `originatorId` | string | `deviceId` of the originator (where the result must go) |
| `stepIndex` | int | Number of **completed** steps, from 0 to `targetStep` |
| `targetStep` | int | Total number of steps |
| `status` | string | `"running"`, `"completed"`, or `"paused"`. The reference only uses the first two. |
| `pendingAction` | object or null | The step that has been started but not confirmed |
| `log` | array | History of attempts (LogEntry) |
| `taskType` | string | Label for the kind of task, default `"generic"` |
| `data` | object | Task-specific content, copied across devices untouched |
| `lateResults` | array, optional | Audit trail of late completions received from a previous owner (LateResult). Absent means none. A receiver that does not know the field SHOULD preserve it when forwarding the state. |

**PendingAction:** `{ "idempotencyKey": string, "forStep": int, "startedAt": int }`. `forStep` is always `stepIndex + 1`.

**LogEntry:** `{ "step": int, "idempotencyKey": string, "status": "completed" | "failed" | "inFlight", "result": string or null, "timestamp": int }`. A failed attempt has a `result` that begins with `error:`. The reference only writes `completed` and `failed`.

**LateResult:** `{ "step": int, "idempotencyKey": string, "result": string, "receivedAt": int, "outcome": "held" | "match" | "divergence" | "orphan" }`. One entry per (key, result text). It is kept beside the log, never inside it, and never changes `data` (invariant I2).

Steps are numbered from 1. `stepIndex = 3` means steps 1 to 3 are done.

### 5.2 Invariants

Any implementation must keep these four rules. They are what make a handoff safe.

- **I1. Tag before acting.** Before a step's action is dispatched, set `pendingAction` with a key for that step. A snapshot taken at any later moment then shows the unfinished step.
- **I2. Content changes only on completion.** `stepIndex`, `data` and the completed log entry change only when a step completes. A snapshot never contains a half-applied result.
- **I3. Same step, same key.** Any retry or re-run of step N, on any device, reuses the key already in `pendingAction` for step N.
- **I4. Append-only log.** Failed attempts are appended with status `failed` and retried under the same key. A success is appended as `completed`.

### 5.3 Example (summarisation task, shortened)

```json
{
  "taskId": "77199706-41dd-4637-a568-77878d7f675b",
  "originatorId": "muwpml5k643",
  "stepIndex": 3,
  "targetStep": 7,
  "status": "running",
  "pendingAction": { "idempotencyKey": "873db1fb-cffe-40bd-8680-79fd403625ca", "forStep": 4, "startedAt": 1700000000000 },
  "log": [
    { "step": 3, "idempotencyKey": "7892bfb4-761e-418f-91f6-560156bdba56", "status": "completed", "result": "Software designed for offline operation…", "timestamp": 1700000000000 }
  ],
  "taskType": "summarize",
  "data": {
    "chunks": ["Software that works without a network connection…", "Artificial intelligence has mostly gone the other way…"],
    "runningSummary": "Software designed for offline operation…"
  }
}
```

## 6. Messages (TCP)

### 6.1 Exchange pattern

1. The sender connects to the receiver's `ip:5891` (timeout **5 s**).
2. It writes the message followed by LF.
3. It waits for **one reply line** (it gives up after **5 s of silence**).
4. It closes the connection.

The sender counts anything other than a matching `ACK` as a failure.

### 6.2 STATE: hand a task over

```json
{"type":"STATE","payload":{ …TaskState… }}
```

**Receiver MUST, in this order:**

1. parse the message,
2. **write the TaskState to storage**,
3. **only then send the ACK**,
4. then load the state and start running it (section 7.3).

**Sender MUST:**

- keep owning the task until it receives an `ACK` whose `taskId` matches,
- on timeout, error or mismatch, **continue as owner**, because the handoff did not happen,
- after the `ACK`, stop starting new steps and remember the receiver's address (used for `LATE_COMPLETION`).

### 6.3 ACK

```json
{"type":"ACK","taskId":"77199706-41dd-4637-a568-77878d7f675b"}
```

`taskId` equals the `taskId` of the message being acknowledged. For `STATE` and `RESULT`, an ACK means **"I have saved it"**. It does not mean "I accepted it" or "I will run it" **[gap 7]**.

### 6.4 RESULT: deliver a finished task

Sent by the device that finished the task to the originator.

```json
{"type":"RESULT","taskId":"77199706-41dd-4637-a568-77878d7f675b","result":{"taskType":"summarize","completedSteps":7,"finishedBy":"a06c99","summary":"This document explores…"}}
```

The `result` object is opaque to the protocol. The reference app puts the final summary in it. The receiver saves it, replies `ACK`, then shows it to the user.

### 6.5 LATE_COMPLETION: a call that finished after handoff

Sent by the **former owner** when an action it started before the handoff finishes **after** the handoff, to the device it handed off to.

```json
{"type":"LATE_COMPLETION","taskId":"77199706-41dd-4637-a568-77878d7f675b","step":4,"idempotencyKey":"873db1fb-cffe-40bd-8680-79fd403625ca","resultText":"Software designed for offline operation…"}
```

- Only sent for calls that **completed**. A failed late call has nothing to compare.
- The receiver replies `ACK` **immediately**, before processing.
- The receiver SHOULD then store the text in `lateResults` (section 5.1) and compare it as described in section 7.4. The Python receiver does; the Dart app does too, but its task file is written only when the late result is recorded.
- If delivery fails, it is dropped. There is no retry **[gap 3]**.

### 6.6 Invalid messages

Invalid JSON, an unknown `type`, or missing fields get **no reply**. The receiver closes the connection, and the sender sees an empty reply and treats it as a failure.

## 7. Behaviour rules

### 7.1 Owner runs the steps

```
loop:
  if stepIndex >= targetStep:  status = "completed"; stop
  N = stepIndex + 1
  key = pendingAction.idempotencyKey if pendingAction.forStep == N else new UUID
  pendingAction = { key, forStep: N }               # I1
  run the step
  on success: append LogEntry(completed)
              stepIndex = N; pendingAction = null
              apply the result to data              # I2
              continue
  on failure: append LogEntry(failed, "error: …")
              wait 2 s, retry step N under the same key   # I3, unbounded [gap 5]
```

### 7.2 Handing off (sender side)

1. A trigger fires (reference: a button that simulates 5% battery).
2. Pick the best candidate (section 4.3). If none, stay as owner.
3. Take a **deep copy** of the current state. It may contain a `pendingAction`.
4. Send `STATE` (section 6.2). On a matching `ACK`, stop starting steps and remember the receiver. Otherwise carry on.

### 7.3 Receiving a handoff (resume rule)

After sending the `ACK`, the receiver loads the state. If `pendingAction` is present:

- If the log contains an entry with that key whose status is `completed`, **skip it**: set `stepIndex = forStep` and clear `pendingAction`.
- Otherwise the outcome is **unknown**. **Re-run step `forStep` under the same key.**

Then continue with section 7.1.

### 7.4 Late completions and divergence

When `LATE_COMPLETION(step, key, text)` arrives:

| Situation | Action |
|---|---|
| Own log has a `completed` entry for `key` | Compare |
| Own `pendingAction.key == key` (own attempt still running) | **Hold** the text (stored with outcome `held`, so a restart does not lose it), and compare as soon as the own attempt completes |
| Neither | Record it in `lateResults` with outcome `orphan`. Not a divergence. Whether to adopt it is an open policy choice (the reference only records it). |

**Comparison:** the two texts, trimmed, are equal. If they are not equal, that is a **divergence**. Because model output rarely matches word for word, a divergence means the wording differs, not that either answer is wrong.

**Reference policy, "compare and flag":** keep the device's own result as canonical, store the other in `lateResults` (so the audit trail survives a restart), and raise a visible flag. Other policies (first-write-wins, last-write-wins, adopt-the-better) are valid. The protocol does not mandate one.

### 7.5 Result delivery (mailbox)

When the owner's task reaches `completed`:

1. Add the result to a **persisted queue** (deduplicated by `taskId`).
2. Try immediately, then every **5 s**.
3. For each queued item, look up the originator in the discovery table. An entry exists only if it was heard recently (entries expire after 6 s without an announcement, and expiry is checked every 2 s, so an entry can be up to about 8 s old). If present, send `RESULT` to its announced `ip`.
4. On a matching `ACK`, remove the item and save the queue. Otherwise keep it.
5. At startup, reload the queue from storage.

The originator saves the result, replies `ACK`, and shows it. If an ACK is lost, the same `RESULT` can arrive twice, so receivers SHOULD treat `RESULT` as idempotent by `taskId` **[gap 6]**.

## 8. Timing constants

| Constant | Value |
|---|---|
| Announcement interval | 2 s |
| Peer expires after | 6 s without an announcement (checked every 2 s) |
| TCP connect timeout | 5 s |
| ACK wait | 5 s of silence |
| Failed-step retry delay | 2 s |
| Mailbox retry | every 5 s, plus one immediate attempt |
| Model call timeout (app level, not protocol) | 60 s |

## 9. Full sequence

```
 originator/owner (phone)                 candidate (laptop)
        |                                        |
        |<------ UDP announcement (every 2 s) ---|
        |------- UDP announcement (every 2 s) -->|
        | runs steps 1..3 (I1, I2, I3)           |
        | step 4 started, pendingAction set      |
        | [trigger]                              |
        |-- STATE (snapshot, step 4 pending) --->|
        |                                        | write snapshot to storage
        |<----------------------- ACK -----------|
        | stop starting steps                    | resume: step 4 unknown, re-run
        | (its own step 4 call still running)    | steps 4, 5, 6, 7 ...
        |-- LATE_COMPLETION (step 4, text) ----->|
        |<----------------------- ACK -----------| compare, flag if different
        |                                        | task completed -> mailbox
        |                                        | (retries every 5 s until the
        |                                        |  originator is heard)
        |<------- RESULT (final) ----------------|
        |-- ACK ---------------------------------->| remove from queue
```

## 10. What the protocol does and does not give you

**Guarantees (while the stated device is working):**

- **G1.** A handed-off task is never silently dropped. The sender keeps ownership until it sees an ACK.
- **G2.** An unfinished step is never silently skipped. It is re-run unless the log shows it completed.
- **G3.** Every step carries a tag that survives the handoff, so a repeated step can be recognised.
- **G4.** A finished result is retried until the originator acknowledges it, as long as the owner's queue file survives.
- **G5.** A late result from a previous owner is kept in the saved task state, with the outcome of its comparison, so a double execution can be audited after the fact. It never changes the task's own result.

**Not guaranteed:**

- **Exactly-once execution.** A step can run twice, possibly with different results. The protocol can detect this when a late completion arrives. It does not prevent it.
- **Authentication or encryption.** Any device on the LAN can send `STATE` or `RESULT`, or announce as anyone.
- **Clock agreement** between devices.
- **Discovery across networks.** UDP broadcast works only within one broadcast domain, and it is blocked by AP isolation and some firewalls.

## 11. Known gaps in the reference implementation

1. **Saved snapshots are never read back.** *(Python receiver: closed when started with `--resume-unfinished`, which resumes unfinished tasks from disk. Dart app: still open.)* The receiver writes `task_<id>.json` (and `result_<id>.json`) before it ACKs, but nothing reloads them. Only the mailbox queue and the device ID are reloaded at startup. So "saved before ACK" has no recovery path today. If the receiver crashes after the ACK, the task is not resumed.
2. **The snapshot-to-ACK window.** The sender keeps running its loop while the `STATE` is in flight (up to about 5 s). A step it completes in that window is in its own log but not in the snapshot. The receiver re-runs it, and no `LATE_COMPLETION` is sent, because that only happens for calls that finish after the loop has stopped.
3. **Late completion goes to one place.** It is sent to the first receiver. If that device has since handed off again, the message goes to a device that no longer owns the task, and a failed delivery is not retried.
4. **No admission control.** *(Python receiver: closed, since it refuses a second task while busy and does not ACK. Dart app: still open.)* A candidate that is busy still accepts a `STATE`, abandons its current task, and starts the new one. A busy candidate can also be chosen if it is the only one.
5. **Unbounded retries.** A step that keeps failing is retried every 2 s forever.
6. **`RESULT` is not idempotent at the receiver.** A duplicate would be shown or processed twice.
7. **ACK is early.** For `STATE` it is sent before the receiver's application code starts the task. For `LATE_COMPLETION` it is sent before anything is saved or processed.
8. **Simulated inputs.** Battery and signal are slider values, and the handoff trigger is a button.
9. **Fixed in both implementations.** Earlier receivers decoded each network chunk separately, which can fail when a chunk boundary falls inside a multi-byte character. Receivers now frame on the raw LF byte first (section 3).
10. **Broadcast address.** Discovery uses `255.255.255.255`. Some networks drop it.

## 12. Notes for implementing it in another language

An implementation in, for example, Python needs the following to interoperate with the reference app:

1. Listen on TCP 5891. On `STATE`: save the snapshot, reply `ACK` within 5 s, then run the task.
2. Handle a message arriving in **several TCP segments**, including a split inside a multi-byte character. Find the LF in the bytes first.
3. Send every message as one line plus LF, and read the reply from the first line.
4. Announce on UDP 5892 every 2 s. Listen, and expire peers after 6 s.
5. Keep invariants I1 to I4 and apply the resume rule in section 7.3.
6. For unknown or invalid messages, close the connection without replying.
7. Send `RESULT` to the originator's announced `ip` once it is heard, retrying until ACKed.

**Interoperability tests that have been run**

- Phone (Dart) hands a task mid-step to the Python receiver, which re-runs the pending step under the same key, finishes the task and delivers `RESULT` back to the phone. Run on real hardware, four times, including a held late completion and a divergence.
- Python receiver against a fake phone (automated, 90 checks): split UTF-8, ACK before running, resume rule, retry under the same key, late completion in all three situations, mailbox, recovery, discovery packets.

**Not yet tested:** three or more devices, a receiver that dies after the ACK, an ACK lost on the way back, a sender that vanishes between snapshot and ACK, and any hostile or malformed traffic beyond the cases above.

**Suggested interoperability tests**

- Phone (Dart) hands a task to a Python receiver, which finishes it and delivers `RESULT` back to the phone.
- A `STATE` containing characters such as `’`, `—`, `–` and `⚠`, large enough to arrive in several chunks.
- A `STATE` whose `pendingAction` already has a completed log entry (it must be skipped).
- A `STATE` with an unfinished step (it must be re-run under the same key).
- An unknown message type (no reply, connection closed).
- A `LATE_COMPLETION` arriving while the own attempt is still running (held, then compared), after it finished (compared at once), and for a key never run (recorded as `orphan`). In each case the entry appears in the saved task file.
