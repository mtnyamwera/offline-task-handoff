# Python receiver

A second implementation of the **candidate** side of the Offline Task Handoff
Protocol (see `PROTOCOL.md`). It plays the same role as the Dart "Target" app on
the laptop, but it was written from the specification alone and shares no code
with the Dart app.

If your phone can hand a task to this program and get the finished summary back,
the specification is enough to build a second implementation.

## What it does

1. Announces itself on the LAN (UDP broadcast) as a **candidate**, so the phone lists it.
2. Accepts a handoff (`STATE`): saves it to disk, ACKs, then resumes the task.
3. Runs the remaining steps with a local Ollama model, using the same prompt and cleanup as the Dart app.
4. Handles `LATE_COMPLETION` messages: holds or compares, flags a divergence.
5. Delivers the finished result to the originator through a saved queue, retrying until it is ACKed.

Standard library only. No `pip install` needed. Written for Python 3.8+ (tested on 3.12).

## Run it with your phone

1. **Close the Dart Target app on the laptop.** Both programs listen on TCP port 5891, and only one can.
2. Make sure Ollama is running and the model is pulled (`ollama pull gemma3:1b`).
3. In a terminal, from this folder:

   ```
   python receiver.py
   ```

   The defaults are Ollama at `http://127.0.0.1:11434` and the model `gemma3:1b`.
4. On the phone, open the app as **Source**. The laptop should appear under *Discovered candidates*,
   shown with the device id the program printed at startup.
5. Trigger the handoff. The terminal shows the same kind of log lines as the Dart Target app.

The phone's Ollama endpoint field is only used by the Dart Target mode, so it does not matter here.

## Options

| Option | Meaning |
|---|---|
| `--ollama URL` | Ollama endpoint (default `http://127.0.0.1:11434`) |
| `--model NAME` | Model (default `gemma3:1b`) |
| `--data-dir DIR` | Where saved tasks, the mailbox queue and the device id live (default `receiver_data`) |
| `--ip ADDR` | Address to announce. Use this if auto-detection picks the wrong network adapter. |
| `--broadcast-addr ADDR` | Broadcast address. If `255.255.255.255` is dropped on your network, try your subnet's, such as `192.168.1.255`. |
| `--peer ID=IP` | Fix an originator's address by hand (skips discovery for that device) |
| `--no-discovery` | Do not announce or listen on UDP |
| `--battery N`, `--signal N` | Announced values 0 to 100. They are simulated, as in the Dart app. |
| `--resume-unfinished` | At startup, resume tasks left unfinished on disk |
| `--langgraph` | Run each summarize step through a LangGraph graph (see below). Needs `pip install langgraph langgraph-checkpoint-sqlite`. |

## Running the task inside LangGraph

`python receiver.py --langgraph` swaps only *how one step is done*. The protocol code (idempotency key, step tagging, log, ACK, handoff, mailbox) is the same. One protocol step is one run of a three-node graph (`prepare` -> `generate` -> `clean`), checkpointed to `receiver_data/langgraph_checkpoints.sqlite` with the step's idempotency key as the thread id.

What you get on this machine: if the receiver crashes or the model call fails, re-running the step under the same key resumes at the unfinished node, and a step that already finished returns its stored result without calling the model again.

What you do not get: exactly-once across devices. A step the phone started has no checkpoint here, so it runs fresh, and the divergence check still applies. The checkpoint file is local; the phone never sees it, and the state that travels between devices is still the plain JSON TaskState.

## Test it without a phone

```
python test_end_to_end.py          # add -v to see the receiver's log
```

This starts a fake Ollama and a fake phone on loopback addresses and uses its own ports, so it
never touches your real Ollama, your network, or ports 5891 and 5892. It takes about 12 seconds
and checks 69 things, including:

- a handoff whose bytes arrive split in the middle of a multi-byte character,
- the snapshot being on disk before the ACK is sent,
- the pending step being re-run under the same key, and a failed step being retried under that key,
- a late result being held, compared, and flagged as a divergence,
- refusal of a second task while busy, duplicates, unsupported task types and invalid messages,
- the mailbox queue surviving a restart and delivering when the originator returns.

**What this proves and does not prove.** The fake phone was written by the same person who read the
specification to write the receiver, so a pass shows the receiver is consistent with that reading.
It does not prove it interoperates with the real Dart phone. The real test is the steps above, with
your phone.

## How it differs from the Dart Target app

| | Dart Target | Python receiver |
|---|---|---|
| A second task while busy | Accepts it and abandons the first (spec gap 4) | **Refuses** it (no ACK), so the sender keeps it |
| Same task sent twice | Restarts it | ACKs again, does not restart |
| Saved snapshot | Written once, never read back (gap 1) | Rewritten after every step. `--resume-unfinished` resumes from it. |
| Task types | `summarize` only | `summarize` only, but each type is a small class (`SummarizeTask`) |
| Broadcast address | Fixed `255.255.255.255` | Configurable |
| Screen | Yes | Terminal only |

Because it refuses a task while busy, a sender that is refused sees no reply and times out after 5 s,
then keeps the task. That is the only refusal signal the current specification has.

## Adding another task type

The protocol carries state, not behaviour. A device that takes over a task must already know how to
do that kind of task. In this program that knowledge is one class. `SummarizeTask` has three methods:

- `run_step(step, state)`: do one step and return its result text. It must not change `state`.
- `apply_result(step, result, state)`: fold a completed result into `state["data"]`.
- `final_result(state, device_id)`: build the `result` object sent back in `RESULT`.

Register a new class in `Receiver(handlers={...})` under its `taskType` name. This is also where a
LangGraph agent would plug in later.

## Files

- `receiver.py`: the receiver and its command-line entry point
- `langgraph_task.py`: the optional LangGraph version of the summarize step
- `test_end_to_end.py`: the automated tests
- `README.md`: this file
