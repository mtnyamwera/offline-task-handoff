import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'models/task_state.dart';
import 'services/agent_simulator.dart';
import 'services/transport_service.dart';
import 'services/slm_tool_call_service.dart';
import 'services/phone_slm_service.dart';
import 'services/discovery_service.dart';
import 'services/mailbox_service.dart';
import 'services/summary_task.dart';

void main() => runApp(const PocApp());

class PocApp extends StatelessWidget {
  const PocApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent State Migration POC',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const RoleSelectScreen(),
    );
  }
}

class RoleSelectScreen extends StatefulWidget {
  const RoleSelectScreen({super.key});
  @override
  State<RoleSelectScreen> createState() => _RoleSelectScreenState();
}

class _RoleSelectScreenState extends State<RoleSelectScreen> {
  // Point this at Ollama's REST API on the laptop, e.g.
  // http://192.168.1.227:11434 — each "step" sends a real prompt here.
  final _endpointController = TextEditingController();
  final _hfTokenController = TextEditingController();
  // The document the SOURCE will summarize. Pre-filled so the demo works
  // immediately; paste your own text to replace it.
  final _docController = TextEditingController(text: kSampleDocument.trim());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agent Migration POC — Step 5: Document Summarization')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'A real task: the SOURCE splits the document below into '
                'chunks and folds one chunk per step into a running '
                'summary. If it hands off mid-way, the running summary '
                'travels with the task and the other device continues '
                'from the same point. The finished summary is delivered '
                'back to the originating device.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _endpointController,
                decoration: const InputDecoration(
                  labelText: 'Ollama endpoint (for the LAPTOP\'s own inference)',
                  hintText: 'http://192.168.1.227:11434',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _hfTokenController,
                decoration: const InputDecoration(
                  labelText: 'Hugging Face token (for the PHONE\'s on-device model)',
                  hintText: 'hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _docController,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Document to summarize (used by the SOURCE only)',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SourceScreen(
                      ollamaEndpoint: _endpointController.text.trim(),
                      hfToken: _hfTokenController.text.trim(),
                      documentText: _docController.text,
                    ),
                  ),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Run as SOURCE (e.g. phone — on-device model)'),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        TargetScreen(ollamaEndpoint: _endpointController.text.trim()),
                  ),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Run as TARGET (e.g. laptop — Ollama)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ---------------- SOURCE (originates the task, later receives the result) ----------------
class SourceScreen extends StatefulWidget {
  final String ollamaEndpoint; // kept only for reference/logging; no longer used for inference
  final String hfToken;
  final String documentText;
  const SourceScreen({
    super.key,
    required this.ollamaEndpoint,
    required this.hfToken,
    required this.documentText,
  });
  @override
  State<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends State<SourceScreen> {
  late TaskState _state;
  late AgentSimulator _agent;
  late PeerDiscovery _discovery;
  late ReceiverService _receiver; // now used to receive RESULT messages too
  String? _deviceId; // persistent — must survive a restart for Step 3
  bool _modelReady = false;
  double _modelDownloadProgress = 0;
  String? _modelLoadError;
  Map<String, PeerStatus> _peers = {};
  final List<String> _logs = [];
  bool _relinquished = false;
  String? _handoffTargetIp; // where to forward a stray late completion
  Map<String, dynamic>? _deliveredResult;
  // What this device handed away, kept for the screen. After a handoff the
  // local _state is frozen at the moment of the snapshot, so showing it as
  // "Step N / in flight" would be misleading.
  String? _handedOffTo;
  int _handedOffAfterStep = 0;
  bool _handedOffMidStep = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final id = await getOrCreatePersistentDeviceId();
    setState(() => _deviceId = id);

    // Load the on-device model BEFORE starting the agent loop — this can
    // take a while on first run (downloading a real model file over
    // WiFi), which is exactly why it happens once here, not per step.
    try {
      await PhoneSlmService.ensureModelLoaded(
        onLog: _log,
        huggingFaceToken: widget.hfToken,
        onProgress: (p) => setState(() => _modelDownloadProgress = p),
      );
      setState(() => _modelReady = true);
    } catch (e) {
      setState(() => _modelLoadError = e.toString());
      _log('Failed to load on-device model: $e');
      return; // don't start the agent loop with no working model
    }

    var chunks = chunkText(widget.documentText);
    if (chunks.isEmpty) chunks = chunkText(kSampleDocument);
    _log('Document split into ${chunks.length} chunk(s) — one per step.');
    _state = newSummaryTask(
      taskId: const Uuid().v4(),
      originatorId: id,
      chunks: chunks,
    );
    _agent = AgentSimulator(
      onTick: (s) => setState(() => _state = s),
      onLog: _log,
      // The phone now thinks entirely on its own — no network call to
      // Ollama, no dependency on any laptop being present at all for
      // this step to succeed.
      applyResult: applySummaryResult,
      toolCall: (step, key, st) async => cleanSummary(
        await PhoneSlmService.dispatch(
          prompt: summaryPromptForStep(step, st),
        ),
      ),
      onLateCompletion: (step, key, resultText) async {
        if (_handoffTargetIp == null) return; // never handed off — nowhere to send this
        final sender = SenderService(onLog: _log);
        await sender.sendLateCompletion(
          targetIp: _handoffTargetIp!,
          taskId: _state.taskId,
          step: step,
          idempotencyKey: key,
          resultText: resultText,
        );
      },
    );
    _agent.runFrom(_state);

    // Discover candidates to hand off to (excludes our own broadcast).
    _discovery = PeerDiscovery(
      onUpdate: (peers) => setState(() => _peers = peers),
      selfId: id,
    );
    _discovery.start();

    // Broadcast OUR OWN presence too, with role "originator" — this is
    // what lets a Target find us again later to deliver a result, even
    // if we restarted since handing off.
    PeerAnnouncer(
      deviceId: id,
      getBattery: () => 100,
      getSignal: () => 100,
      getBusy: () => false,
      role: 'originator',
    ).start();

    // Listen for a RESULT message arriving back — this is the actual
    // "mailbox delivery" landing on the originator's side.
    _receiver = ReceiverService(
      onStateReceived: (_) {}, // Source doesn't accept new task handoffs
      onResultReceived: (taskId, result) {
        setState(() => _deliveredResult = result);
        _log('RESULT DELIVERED for task ${taskId.substring(0, 8)}: $result');
      },
      onLog: _log,
    );
    _receiver.start();
  }

  void _log(String msg) {
    setState(() => _logs.insert(0, msg));
    // ignore: avoid_print
    print('[SOURCE] $msg');
  }

  Future<void> _handOff() async {
    final best = _discovery.best;
    if (best == null) {
      _log('No candidate devices in range — nothing to hand off to. '
          'Staying in control.');
      return;
    }

    final snapshot = _state.copy();
    _log('Trigger fired (simulated 5% battery). Best candidate: '
        '${best.deviceId} (battery ${best.battery}%, signal ${best.signal}%, '
        'score ${best.score.toStringAsFixed(1)}). Sending snapshot at '
        'step ${snapshot.stepIndex}${snapshot.pendingAction != null ? " (mid-action!)" : ""}...');

    final sender = SenderService(onLog: _log);
    final confirmed = await sender.sendState(
      targetIp: best.ip,
      state: snapshot,
    );

    if (confirmed) {
      _agent.pause();
      _handoffTargetIp = best.ip;
      setState(() {
        _relinquished = true;
        _handedOffTo = best.deviceId;
        _handedOffAfterStep = snapshot.stepIndex;
        _handedOffMidStep = snapshot.pendingAction != null;
      });
      _log('Ownership relinquished to ${best.deviceId}. Source is now idle, '
          'waiting for the result to be delivered back — even if this app '
          'is closed and reopened later.');
    } else {
      _log('Handoff not confirmed — continuing to run locally.');
    }
  }

  void _killNow() {
    _agent.dispose();
    _log('SIMULATED CRASH: source stopped with no handoff.');
  }

  @override
  Widget build(BuildContext context) {
    if (_modelLoadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Source (Phone)')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'On-device model failed to load:\n\n$_modelLoadError\n\n'
            'Common causes: missing/invalid Hugging Face token, no '
            'internet for the first-time model download, or not enough '
            'free storage on the phone.',
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }
    if (_deviceId == null || !_modelReady) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_deviceId == null
                  ? 'Starting...'
                  : 'Loading on-device model... '
                      '${(_modelDownloadProgress).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      );
    }

    final sortedPeers = _peers.values
        .where((p) => p.role == 'candidate')
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return Scaffold(
      appBar: AppBar(title: Text('Source (Phone) — $_deviceId')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_deliveredResult != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.12),
                  border: Border.all(color: Colors.blue),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '📬 Result delivered (finished by '
                  '${_deliveredResult!['finishedBy']}):\n\n'
                  '${_deliveredResult!['summary']}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            Text('Discovered candidates (${sortedPeers.length}):',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            if (sortedPeers.isEmpty)
              const Text('None yet — start a Target device on the same WiFi.',
                  style: TextStyle(color: Colors.grey))
            else
              ...sortedPeers.asMap().entries.map((entry) {
                final isBest = entry.key == 0;
                final p = entry.value;
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isBest
                        ? Colors.green.withOpacity(0.12)
                        : Colors.grey.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: isBest
                        ? Border.all(color: Colors.green, width: 1.2)
                        : null,
                  ),
                  child: Text(
                    '${isBest ? "★ " : ""}${p.deviceId} (${p.ip}) — '
                    'battery ${p.battery}%, signal ${p.signal}%'
                    '${p.busy ? ", BUSY" : ""} — score ${p.score.toStringAsFixed(1)}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                );
              }),
            const SizedBox(height: 12),
            Text('Task: ${_state.taskId.substring(0, 8)}',
                style: Theme.of(context).textTheme.bodySmall),
            if (_relinquished) ...[
              Text(
                  _deliveredResult != null
                      ? 'Handed off - result received'
                      : 'Handed off to $_handedOffTo',
                  style: Theme.of(context).textTheme.headlineSmall),
              Text('Snapshot sent after step $_handedOffAfterStep of '
                  '${_state.targetStep}'
                  '${_handedOffMidStep ? ", with step ${_handedOffAfterStep + 1} in flight" : ""}. '
                  '${_deliveredResult != null ? "The finished result is shown above." : "Waiting for the result to come back."}'),
            ] else ...[
              Text('Step: ${_state.stepIndex} / ${_state.targetStep}',
                  style: Theme.of(context).textTheme.headlineSmall),
              Text(_state.pendingAction != null
                  ? 'IN FLIGHT: step ${_state.pendingAction!.forStep} '
                      '(key ${_state.pendingAction!.idempotencyKey.substring(0, 8)})'
                  : 'No action in flight'),
              const SizedBox(height: 8),
              summaryCard(summaryText(_state)),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _relinquished ? null : _handOff,
                    child: const Text('Trigger handoff\n(auto-pick best candidate)',
                        textAlign: TextAlign.center),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _relinquished ? null : _killNow,
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                    child: const Text('Kill now\n(no handoff)',
                        textAlign: TextAlign.center),
                  ),
                ),
              ],
            ),
            const Divider(height: 32),
            Expanded(
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (_, i) => Text(_logs[i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Guarded because a failed on-device model load returns early in
    // _init(), before _agent/_discovery/_receiver are ever assigned.
    if (_modelReady) {
      _agent.dispose();
      _discovery.stop();
      _receiver.stop();
    }
    PhoneSlmService.dispose();
    super.dispose();
  }
}

/// ---------------- TARGET (receives the handoff, later delivers the result) ----------------
class TargetScreen extends StatefulWidget {
  final String ollamaEndpoint;
  const TargetScreen({super.key, required this.ollamaEndpoint});
  @override
  State<TargetScreen> createState() => _TargetScreenState();
}

class _TargetScreenState extends State<TargetScreen> {
  late ReceiverService _receiver;
  late PeerAnnouncer _announcer;
  late PeerDiscovery _discovery; // Target now ALSO discovers, to find the
                                  // originator again later for delivery
  late MailboxService _mailbox;
  final String _deviceId = const Uuid().v4().substring(0, 6);
  AgentSimulator? _agent;
  TaskState? _state;
  final List<String> _logs = [];

  int _battery = 80;
  int _signal = 70;
  int _divergencesDetected = 0;
  bool get _busy => _agent != null && _state?.status == 'running';

  @override
  void initState() {
    super.initState();

    _discovery = PeerDiscovery(
      onUpdate: (_) {}, // Target doesn't need to render this list itself;
                         // the mailbox just queries it by ID when retrying
      selfId: _deviceId,
    );
    _discovery.start();

    _mailbox = MailboxService(discovery: _discovery, onLog: _log);
    _mailbox.start();

    _receiver = ReceiverService(
      onStateReceived: _onStateReceived,
      onLateCompletion: _onLateCompletion,
      onLog: _log,
    );
    _receiver.start();

    _announcer = PeerAnnouncer(
      deviceId: _deviceId,
      getBattery: () => _battery,
      getSignal: () => _signal,
      getBusy: () => _busy,
      role: 'candidate',
    );
    _announcer.start();
  }

  void _log(String msg) {
    setState(() => _logs.insert(0, msg));
    // ignore: avoid_print
    print('[TARGET] $msg');
  }

  void _onStateReceived(TaskState state) {
    setState(() => _state = state);
    _agent?.dispose();
    _agent = AgentSimulator(
      onTick: (s) {
        setState(() => _state = s);
        _checkPendingLate(s);
        if (s.status == 'completed') _deliverResult(s);
      },
      onLog: _log,
      applyResult: applySummaryResult,
      toolCall: (step, key, st) async => cleanSummary(
        await SlmToolCallService.dispatch(
          endpoint: widget.ollamaEndpoint,
          prompt: summaryPromptForStep(step, st),
        ),
      ),
    );
    _agent!.runFrom(state);
  }

  /// This is where the table of policies from the design discussion
  /// actually gets applied, not just talked about. Policy chosen here:
  /// COMPARE AND FLAG. We don't silently pick a winner — we keep
  /// whatever this device already used to make forward progress (since
  /// steps 5, 6, 7... may already depend on it), but we explicitly log
  /// that a second, different result existed for the same key, so the
  /// divergence is visible and auditable rather than hidden.
  // Late results that arrived while OUR OWN attempt at the same step was
  // still in flight. We can't judge them yet, so hold them and compare the
  // moment our own result lands (see _checkPendingLate).
  final Map<String, String> _pendingLate = {};

  void _onLateCompletion(
      String taskId, int step, String idempotencyKey, String resultText) {
    final sameKey =
        _state?.log.where((e) => e.idempotencyKey == idempotencyKey).toList() ??
            [];
    // Only a COMPLETED result of our own is something a late result can
    // "diverge" from. A failed attempt stores an error string as its
    // result; comparing that to a real answer would flag a fake divergence.
    final completed =
        sameKey.where((e) => e.status == ActionStatus.completed).toList();

    if (completed.isNotEmpty) {
      _compareLate(step, idempotencyKey, completed.first.result ?? '', resultText);
      return;
    }

    if (_state?.pendingAction?.idempotencyKey == idempotencyKey) {
      // Our own attempt at this exact step is still running. "No result
      // yet" does NOT mean "no divergence" — hold the late result and
      // compare as soon as ours finishes.
      _pendingLate[idempotencyKey] = resultText;
      _recordLate(step, idempotencyKey, resultText, 'held');
      _log('Late completion for step $step (key $idempotencyKey) arrived '
          'while our own attempt is still in flight — holding it and '
          'comparing when ours finishes.');
      return;
    }

    _log('Late completion for step $step (key $idempotencyKey): we have '
        'NO completed result of our own for this key and none in flight '
        '(${sameKey.length} failed attempt(s)). Not a divergence — the late '
        'result is the only successful one. Policy decision pending: '
        'whether to adopt it (currently it is only logged).');
    _log('  Late result: "$resultText"');
    _recordLate(step, idempotencyKey, resultText, 'orphan');
  }

  /// Keep the other device's result in the saved task file, not only in the
  /// on-screen log, so the audit trail survives closing the app.
  void _recordLate(int step, String key, String text, String outcome) {
    final s = _state;
    if (s == null) return;
    s.recordLate(step: step, key: key, text: text, outcome: outcome);
    persistTaskState(s);
  }

  /// Called on every tick: if one of our own attempts has now completed
  /// for a key we were holding a late result for, compare them.
  void _checkPendingLate(TaskState s) {
    if (_pendingLate.isEmpty) return;
    for (final key in List<String>.from(_pendingLate.keys)) {
      final own = s.log
          .where((e) =>
              e.idempotencyKey == key && e.status == ActionStatus.completed)
          .toList();
      if (own.isEmpty) continue;
      final late = _pendingLate.remove(key)!;
      _compareLate(own.first.step, key, own.first.result ?? '', late);
    }
  }

  /// The "compare and flag" policy. We keep our own result as canonical
  /// (later steps already build on it) but make any difference visible.
  void _compareLate(int step, String key, String ownResult, String lateResult) {
    final same = ownResult.trim() == lateResult.trim();
    _recordLate(step, key, lateResult, same ? 'match' : 'divergence');
    if (same) {
      _log('Step $step (key $key): late result matches our own exactly — '
          'no divergence.');
      return;
    }
    setState(() => _divergencesDetected++);
    _log('⚠ DIVERGENCE DETECTED — step $step, key $key.\n'
        '  Our result:  "$ownResult"\n'
        '  Late result: "$lateResult"\n'
        '  Policy applied: COMPARE AND FLAG — keeping our own result as '
        'canonical (later steps already built on it), late result kept '
        'in the task file (lateResults) for audit.');
  }

  void _deliverResult(TaskState finished) {
    // This is Step 3's actual payoff: instead of assuming the originator
    // is listening right now, the result is handed to the mailbox, which
    // takes responsibility for eventual delivery — including retrying
    // across this device's own restarts.
    _mailbox.enqueue(
      taskId: finished.taskId,
      originatorId: finished.originatorId,
      result: {
        'taskId': finished.taskId,
        'completedSteps': finished.stepIndex,
        'finishedBy': _deviceId,
        'taskType': finished.taskType,
        'chunks': summaryChunks(finished).length,
        // The actual finished summary — not just a step count.
        'summary': summaryText(finished).isNotEmpty
            ? summaryText(finished)
            : 'Task completed after ${finished.log.length} logged steps.',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Target (Laptop) — $_deviceId')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Broadcasting status on LAN. Waiting for handoff on '
                'port 5891...',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            Text('Battery: $_battery%'),
            Slider(
              value: _battery.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              label: '$_battery%',
              onChanged: (v) => setState(() => _battery = v.round()),
            ),
            Text('Signal: $_signal%'),
            Slider(
              value: _signal.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              label: '$_signal%',
              onChanged: (v) => setState(() => _signal = v.round()),
            ),
            Text(_busy ? 'Status: BUSY (running a task)' : 'Status: idle',
                style: TextStyle(
                    color: _busy ? Colors.orange : Colors.green,
                    fontWeight: FontWeight.bold)),
            if (_mailbox.pendingCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '📮 ${_mailbox.pendingCount} result(s) waiting for their '
                  'originator to reappear...',
                  style: const TextStyle(color: Colors.deepOrange, fontSize: 12),
                ),
              ),
            if (_divergencesDetected > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '⚠ $_divergencesDetected divergence(s) detected — same key, '
                  'different result. See log below.',
                  style: const TextStyle(color: Colors.red, fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ),
            const SizedBox(height: 8),
            if (_state != null) ...[
              Text('Task: ${_state!.taskId.substring(0, 8)} '
                  '(from ${_state!.originatorId})',
                  style: Theme.of(context).textTheme.bodySmall),
              Text('Step: ${_state!.stepIndex} / ${_state!.targetStep}',
                  style: Theme.of(context).textTheme.headlineSmall),
              Text(_state!.status),
              summaryCard(summaryText(_state!)),
            ],
            const Divider(height: 24),
            Expanded(
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (_, i) => Text(_logs[i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _receiver.stop();
    _announcer.stop();
    _discovery.stop();
    _mailbox.stop();
    _agent?.dispose();
    super.dispose();
  }
}


/// Shows the running summary on either screen, so you can watch it grow
/// step by step — and see it carry over intact after a handoff.
Widget summaryCard(String text) {
  if (text.trim().isEmpty) return const SizedBox.shrink();
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.amber.withOpacity(0.12),
      border: Border.all(color: Colors.amber),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      'Summary so far:\n$text',
      maxLines: 6,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12),
    ),
  );
}
