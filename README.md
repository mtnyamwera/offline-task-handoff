# Offline task handoff for AI agents

Move a running, multi-step task from one device to another over a local network, with no internet and no server, so that work is not lost when a device dies or leaves.

**Status: working proof of concept.** Not a product. Not secure. Read "What is not claimed" before you rely on any of it.

## The problem

Small AI models now run on phones and laptops. Those devices are unreliable: a battery dies, a phone is carried out of range, a laptop is closed. If a long task lives only in the memory of one device, the work is lost, and a restart can repeat a step that already happened. Cloud systems solve this with a server and an internet link. This project asks what the smallest version looks like when there is neither.

## What it does

A phone starts a seven-step task. Part-way through, it hands the task to a laptop on the same Wi-Fi. The laptop finishes it, and the result comes back to the phone, even if the phone was away in the meantime.

The rules that make that safe:

1. **Tag before you act.** Every step gets an idempotency key and is saved as "started" before it runs.
2. **Two-phase handoff.** The receiver saves the state, then sends an ACK. The sender gives up ownership only after the ACK. If the ACK never comes, the sender keeps the task.
3. **Re-run, never skip.** The new owner re-runs a step whose outcome is unknown, under the same key.
4. **Notice double execution.** If the former owner finishes the same step later, it sends the result back. The new owner compares the two, flags a difference and stores the other result in the task file for audit. Its own result stays canonical.
5. **Mailbox.** The finished result is queued and retried until the originator acknowledges it.

The guarantee is **at-least-once**, not exactly-once. A step can run twice, and two runs of a language model can differ. The protocol detects and records that. It does not prevent it.

## What has been shown

On one Honor phone (Android 15, Gemma 3 1B on-device) and one Windows laptop (Ollama, gemma3:1b), on a home Wi-Fi network:

- Discovery, handoff in the middle of a step, re-run under the same key, late-result comparison and mailbox delivery work end to end. Three runs against the Dart receiver and four against the Python receiver.
- A second implementation, in Python, written from the written protocol, interoperates with the phone.
- The step can run inside LangGraph on the Python side (`--langgraph`). The protocol state stays plain JSON, and LangGraph's own checkpoints stay on the laptop.
- 90 automated checks pass for the Python receiver. They use a fake phone written from the same document, so they show the receiver follows the text, not that it interoperates independently.
- Observed: the on-device model gave the same answer to the same input in every run, and Ollama's answers varied. So many flagged divergences come from two different runtimes, not from random variation.

## What is not claimed

- **No exactly-once.** A step can run twice. A real side effect (sending an email, writing an order) needs the tool itself to honour the idempotency key. The protocol supplies the key and nothing more.
- **No security.** Messages are unencrypted and unauthenticated. Anyone on the network can send a fake handoff.
- **Two devices, one network.** Nothing was tested with three or more devices, a lossy network, a laptop that dies after the ACK, or a lost ACK.
- **Simulated inputs.** Battery and signal are slider values, and the handoff trigger is a button.
- **The task is a toy.** The demo summarises seven short paragraphs. A 1B model drifts and sometimes states the opposite of the text. That is a model limit, not a protocol result.
- **The receiving device must know the task.** The protocol carries state, not behaviour. The new device needs the same agent code and the same tools, and it must reach the same data.
- **Known gaps** are listed in section 11 of `PROTOCOL.md`.

## Layout

```
app/lib/                    Flutter app (Dart): Source, Target, discovery, mailbox
demo/                       Demo video and captions
python_receiver/
  receiver.py               Receiver in Python (standard library only)
  langgraph_task.py         Optional: run each step through LangGraph
  test_end_to_end.py        90 automated checks
  PROTOCOL.md               The written protocol (draft 0.2)
  README.md                 Receiver usage and options
```

## Running it

**Laptop (Python receiver)**

```
ollama pull gemma3:1b
python receiver.py                      # plain
pip install langgraph langgraph-checkpoint-sqlite
python receiver.py --langgraph          # steps run through LangGraph
```

Allow TCP 5891, UDP 5892 and Ollama's 11434 through the firewall, on the network profile your Wi-Fi uses.

**Phone (Flutter app)**

Add `INTERNET` and `ACCESS_NETWORK_STATE` to the Android manifest. Run the app, pick Source, paste a Hugging Face token (the Gemma model is gated), and use "Trigger handoff" while a step is in flight. The Target mode in the same app can stand in for the Python receiver.

**Tests (no phone needed)**

```
python test_end_to_end.py
```

## Where it could apply

Edge and offline settings where devices are unreliable and data should not leave the site: a clinic with a tablet and a laptop and no dependable internet, field inspection, a workshop floor. These are plausible uses, not demonstrated ones. No real user has tried it.

## Next

- A small agent with real tools, where one tool writes something and the test counts duplicates, then crashes a device at each step. This is the most useful next experiment.
- A third device, to see what breaks when two candidates want the same task.
- Encryption and authentication.
- Fix the remaining gaps in the Dart app (resume from disk, refuse a second task).

## Licence

Not chosen yet.
