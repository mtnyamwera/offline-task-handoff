# Agent State Migration POC — Real Tool Call Version

A minimal, honest proof of the mechanism behind mid-task AI agent state
migration across devices — over a local network only, no internet, no
cloud, no account system for the HANDOFF itself.

This version replaces the earlier fake `Future.delayed` step with a REAL,
external, non-idempotent action: an HTTP POST to a
[webhook.site](https://webhook.site) URL you control. Unlike the fake
delay, running this step twice leaves real, visible, timestamped evidence
outside the app — which is the entire point. This is the test that
actually exercises the idempotency-key logic, rather than assuming it
works.

## Setup

1. Go to https://webhook.site — it gives you a unique URL immediately,
   no signup required. Keep that browser tab open; every request sent to
   your URL appears there live.
2. Paste that URL into the app's home screen, on **both** devices (phone
   and laptop) — they must use the identical URL, since either one might
   end up running a given step.
3. Run one as Target, one as Source, same as before.

## What this proves that the counter-only version could not

1. **State (including mid-action state) can be captured and transferred**
   — same as before.
2. **The receiving device never acts on unconfirmed guesses** — it checks
   the log for the idempotency key of any in-flight action before
   deciding whether to redo it.
3. **The sending device never gives up ownership early** — only stops
   after an explicit ACK.
4. **A crash with no handoff loses only what the crashed device had.**
5. **NEW: a step that gets interrupted mid-call is re-dispatched under
   the SAME idempotency key** — and you can literally check the
   webhook.site log afterward to see whether that key appears once or
   twice. If it appears twice, that's not a bug in this POC — it's the
   real, honest limitation the design docs called out: without a
   server that de-duplicates by key, at-least-once delivery is the best
   a purely local, no-cloud protocol can guarantee on its own. Seeing
   this with your own eyes is more valuable than a POC that hides it.

## Running it

You need two devices (or two emulators/simulators) on the **same LAN**,
e.g. the same office WiFi network with no internet required.

```bash
flutter pub get
flutter run -d <device-id>
```

On the **target** device (the "laptop"): choose **Run as TARGET**. It will
start listening on port `5891`.

On the **source** device (the "phone"): choose **Run as SOURCE**, enter the
target's LAN IP address in the text field (find it with `ipconfig` /
`ifconfig` / your OS's WiFi settings on the target device), and let the
counter start running.

## Test scenarios to actually run, not just read about

- **Clean handoff mid-count.** Let the source complete a step or two,
  then tap *Trigger handoff*. Watch the target resume from the correct
  step.
- **Handoff fired mid-action — the real test.** Trigger the handoff
  *while a real HTTP call is in flight* (right after a "dispatching REAL
  call" log line, before "confirmed completed" appears — real network
  latency makes the window less predictable than the old fixed delay,
  so you may need a couple of tries). Then:
  1. Check the webhook.site tab. Note the idempotency key of the step
     that was in flight.
  2. Watch the target's log for its "Resume: ... re-dispatching under
     the SAME key" line.
  3. Check webhook.site again — does that exact key appear once or
     twice? Either outcome is informative: once means the original
     call happened to fail cleanly before the handoff; twice means the
     original call actually succeeded on the server, and this local-only
     protocol had no way to know that in advance. Recording which one
     you actually observed is the real output of this test.
- **Kill with no handoff.** Tap *Kill now*. Confirm the target shows no
  reaction and webhook.site shows no new entry.
- **Kill the source right after sending, before ACK arrives.** Same as
  before — toggle WiFi off immediately after tapping *Trigger handoff*.
  Confirm the source's log is honest about the outcome either way.

## What's deliberately faked, and why

- **The tool call is a `Future.delayed`, not a real network request.**
  This isolates the migration mechanism from real-world API flakiness
  while you're proving the protocol. Swap it for a real HTTP call (e.g. a
  weather API or web search) once the above scenarios all pass reliably.
- **The battery-5% trigger is a button, not `battery_plus`.** Wiring in
  the real battery listener is a five-minute change once the mechanism
  itself is trusted — it shouldn't be the thing you're debugging first.
- **Transport is a raw TCP socket on the LAN**, not BLE or WiFi Direct.
  The protocol above the transport layer (state shape, idempotency check,
  two-phase ACK) doesn't change when you swap the radio — only
  `transport_service.dart` would need to change.

## Step 2 — Multiple Candidates, Auto-Selected

The Source screen no longer takes a typed IP address. Instead:

- Every Target device broadcasts its own status (device ID, IP, a
  simulated battery %, a simulated signal %, busy/idle) once every 2
  seconds over UDP, port 5892.
- The Source device listens continuously and keeps a live list, dropping
  any device it hasn't heard from in 6 seconds — that's how "left the
  mesh" is detected without needing an explicit goodbye message.
- When you tap "Trigger handoff," the Source automatically picks the
  highest-scoring candidate (weighted: 60% battery, 40% signal; busy
  devices are heavily penalized) and sends to it — no manual IP entry.

### Try this with 3 devices

Run Target on two laptops (or a laptop + a second phone) and Source on
the phone. On each Target, drag the battery/signal sliders to different
values. Watch the Source screen's candidate list re-rank in real time as
you move the sliders — the device marked ★ is who Trigger handoff will
actually use. Then physically close one Target app (or turn off its
WiFi) and confirm it drops out of the Source's list within about 6
seconds.

### One Windows note

If broadcasts aren't being received, add a firewall rule for the new UDP
port (the existing TCP rule from Step 1 does not cover this):

```powershell
New-NetFirewallRule -DisplayName "Agent Migration POC UDP" -Direction Inbound -Protocol UDP -LocalPort 5892 -Action Allow -Profile Any
```

## Step 3 — The Mailbox (Return Path)

Until now, once a Target finished a task, there was no way to get the
result back if the original Source device was gone. This step fixes
that.

### What changed

- Every device now has a **persistent ID** that survives an app restart
  (stored in a small local file) — without this, a phone that comes back
  "later" would look like a brand-new, unrecognized device, and nothing
  could ever be routed to it.
- The **Source now also broadcasts itself** on the discovery channel,
  with role `originator` (as opposed to a Target's role `candidate`).
  This is what lets a Target find the phone again later.
- The **Source now also listens** on the TCP port — not just to send
  handoffs, but to receive a `RESULT` message when one finally arrives.
- When a Target finishes a task, it doesn't assume the originator is
  reachable. It hands the result to a **MailboxService**, which:
  - Persists the pending result to local disk immediately (survives the
    Target's own restart too).
  - Checks the live discovery list every 5 seconds for the originator's
    current IP.
  - Once found, attempts delivery using the same two-phase ACK discipline
    as the original handoff — only removing the item from the queue on a
    confirmed ACK.

### The test that actually proves this step

1. Start Source (phone) and Target (laptop). Trigger a handoff as usual.
2. **Immediately force-close the Source app entirely** — not just
   "kill now," actually swipe it away / close the process. Simulates the
   phone being gone, possibly for hours.
3. Let the Target finish all 10 steps. Watch its log: it will say
   "queued result... waiting for originator to be seen on the network"
   and its screen will show a pending-delivery count. It keeps retrying
   every 5 seconds and finding nobody — this is the correct, expected
   state while the phone is genuinely gone.
4. **Reopen the Source app.** Because its device ID is persistent, it
   broadcasts under the same identity as before.
5. Within a few seconds, the Target's mailbox should find it, deliver the
   result, and its pending count should drop to zero. The Source screen
   should show a blue "📬 Result delivered" box with the task's outcome.

This is deliberately the hardest test in the project so far: it spans an
app restart, a genuinely unknown amount of "gone" time, and a device
identity that has to survive all of it.

## Step 4a — Real Local Model Inference (Ollama)

Every step now sends a real prompt to a real small language model,
running locally via [Ollama](https://ollama.com) on the laptop — still
no internet, no cloud API, nothing external. This replaces the
webhook.site version entirely.

### Setup — read this carefully, especially the LAN-binding step

1. Install Ollama on the laptop: https://ollama.com/download
2. Pull a small model that runs comfortably on CPU:
   ```
   ollama pull llama3.2:1b
   ```
3. **Critical step, easy to miss:** by default, Ollama only listens on
   `localhost` — it will NOT accept connections from your phone over the
   LAN until you explicitly tell it to bind to all interfaces. On
   Windows:
   ```powershell
   setx OLLAMA_HOST "0.0.0.0"
   ```
   Then fully quit Ollama (check the system tray) and restart it so the
   new environment variable takes effect. Confirm it worked by visiting
   `http://<laptop-LAN-IP>:11434` from your phone's browser — you should
   see a plain "Ollama is running" response, not a connection error.
4. If needed, add a firewall rule for the Ollama port, same pattern as
   before:
   ```powershell
   New-NetFirewallRule -DisplayName "Ollama LAN" -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Allow -Profile Any
   ```
5. On the app's home screen, enter the laptop's LAN IP with the Ollama
   port, e.g. `http://192.168.1.227:11434` — on BOTH devices, same as the
   webhook URL before it. This is required even for the Target (laptop)
   itself, since the app always dials this address explicitly rather than
   special-casing "am I the same machine as Ollama."

### What's different about this test compared to Step 1

A model call has no external side effect — running the same prompt
twice doesn't duplicate a real-world action, it just costs extra compute
time and may produce a slightly different response (LLM output isn't
perfectly deterministic). So this step isn't really re-testing
duplication risk — Step 1 already proved that. What it tests instead is
whether the handoff mechanism holds up against a **slower, more
variable** action: real inference can take anywhere from under a second
to tens of seconds, so the "mid-action interruption" window becomes
realistic rather than something you have to time carefully by hand.

### What to look for

- The app's log now shows the model's actual response text after each
  step, not just a status code — a real, readable sentence about offline
  AI agents.
- Try triggering a handoff while a step is genuinely mid-inference (this
  is now much easier to catch than with the old fast webhook calls,
  precisely because inference is slower).
- Confirm the resumed device's re-dispatch under the same key produces a
  new, real model response — check that the log shows two different
  (or occasionally identical) pieces of generated text under one shared
  idempotency key, which is the direct, visible evidence of the same
  ambiguity discovered in Step 1, now happening with a real model instead
  of a test webhook.

## Where this goes next

1. Add real on-device inference to the PHONE too (e.g. via MediaPipe's
   LLM Inference API for Flutter), so either device can genuinely think,
   not just relay to whichever laptop happens to be running Ollama.
2. Replace the trigger button with a real battery-level listener
   (`battery_plus`) and a real RSSI-based proximity check.
3. Replace the single-prompt step with a real multi-step agent plan
   (read → extract → search → reason → summarize → email), where each
   step's prompt depends on the previous step's real output.

## Step 4b — Real Inference on the Phone Too (On-Device)

The phone now runs a real small model ENTIRELY on-device via
[flutter_gemma](https://pub.dev/packages/flutter_gemma) — no network call,
no dependency on Ollama or any laptop being present for its own
reasoning. The laptop (Target) is unchanged — it still uses Ollama. This
is what makes the phone a genuine peer, not just a relay.

**Default model: Gemma 3 1B**, sized for a phone with roughly 8GB of
PHYSICAL RAM. Ignore "Turbo" / virtual RAM figures when sizing a model:
that is storage borrowed to act like memory, and it is slow for model
weights. **Fallback: Gemma 3 270M** (~290MB) if the phone runs hot, is
very slow, or the app gets killed mid-inference. Switching is a
one-line change in `phone_slm_service.dart` (both URLs are in the file).
Note that on a mid-range phone CPU, speed rather than memory is the
likely bottleneck.

### A note on package version churn

`flutter_gemma` moves fast — this project has already been updated once
from v0.16.x to v1.x mid-build, and the API surface changed with it
(explicit `ModelFileType`, built-in OS-model support). If you hit a
compile error in `phone_slm_service.dart` that looks like a renamed or
missing method, check the **example app bundled inside your actually
installed version** (`flutter pub deps` shows the resolved version
number) — that's a more reliable source of truth than this README or any
tutorial, given how quickly this specific package changes.

### This step has real setup overhead — more than any step before it

- Create a free Hugging Face account and access token at
  https://huggingface.co/settings/tokens
- Visit https://huggingface.co/litert-community/Gemma3-1B-IT (and the
  270M page, if you may use the fallback) and accept the license terms
  once, using the SAME Hugging Face account whose token you'll paste
  into the app — gated models refuse to download without this, even with
  a valid token.
- In `android/app/build.gradle`, raise `minSdkVersion` to at least 26 if
  it's currently lower.
- Expect the FIRST run to be slow: the app downloads a real model file
  (roughly 0.5-1GB for the 1B model, ~290MB for 270M) over WiFi, then loads it into memory — this
  can take a few minutes, not seconds, and needs a real internet
  connection for this one-time download (the model itself then runs
  fully offline afterward).
- Inference on a phone's CPU is noticeably slower than Ollama on a
  laptop — expect each step to take longer than the Step 4a laptop-only
  version.

### Setup

1. Get a Hugging Face token (see above) and accept the model's license.
2. Rebuild the app: `flutter pub get`, then `flutter build apk --release`.
3. On the phone's home screen, paste the Hugging Face token into the new
   field, and still fill in the Ollama endpoint (used only by the
   Target/laptop now).
4. Tap "Run as SOURCE" — you'll see a loading screen with download
   progress before the task starts. This only happens once; the model
   stays cached on the phone after that.

### What to check

- The phone's log should show real generated text, same as before — but
  now produced without any network request leaving the phone at all.
- Try turning off the phone's WiFi entirely (once the model is loaded)
  and confirm a step still completes — this is the direct proof that the
  phone's reasoning no longer depends on the laptop, Ollama, or any
  network at all. (Discovery/handoff still need WiFi, obviously — only
  the "thinking" part is now fully independent.)
- Run the same mid-action handoff and divergence tests as before —
  they should behave identically, since none of the transport/discovery/
  mailbox/idempotency logic changed; only what a step *does* changed
  again, same pattern as every step in this project so far.

## Divergence Detection — Making the Ambiguity Visible, Not Just Possible

Live testing surfaced something worth naming precisely: when the SAME
idempotency key gets dispatched twice — once by the original device
before it handed off, once by the device that took over — the two real
model calls can return genuinely DIFFERENT text. This is expected LLM
behavior (output isn't perfectly deterministic), but it's a sharper
version of the duplicate-dispatch ambiguity from Step 1: with a webhook,
a duplicate is identical to itself. With an LLM, two "duplicates" can
disagree.

Until this addition, the only way to notice this was for a human to read
two separate device screens side by side. That's now built into the app:

- When a device's in-flight call finishes AFTER it has already handed
  off ownership, it forwards that stray result (a new `LATE_COMPLETION`
  message, same two-phase ACK discipline as everything else) to whoever
  it handed off to.
- The receiving device compares the late-arriving result against its own
  result for the same key.
- If they differ, it's flagged explicitly in the log and in a visible
  on-screen counter — not silently resolved one way or the other.

**Policy chosen for this stage: COMPARE AND FLAG.** The device that
already made forward progress keeps its own result as canonical (later
steps may already depend on it), but the divergence is recorded for
audit rather than hidden. Other policies are real, valid alternatives —
first-write-wins, last-write-wins, cache-and-pin — each with different
trade-offs; this project deliberately picks the option that makes the
problem visible rather than the option that makes it disappear, because
at this stage understanding how often and how badly this occurs matters
more than optimizing it away.

### How to trigger it

Same as the mid-action handoff test, but now watch specifically for the
laptop's log to show `⚠ DIVERGENCE DETECTED` — this requires the
original device's stray call to actually reach Ollama and get a response
before the app is closed, so it may take a couple of attempts to catch
in the exact right window.
