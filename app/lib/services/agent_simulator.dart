import 'dart:async';
import 'package:uuid/uuid.dart';
import '../models/task_state.dart';

const _uuid = Uuid();

/// Signature for a real tool call: given the step number and its
/// idempotency key, perform the real action and return its result text
/// (e.g. a model's real response), or throw on failure/timeout.
/// [state] is passed so the call can read what it needs from the task's
/// own data (e.g. this step's input). It must NOT mutate it — the loop below
/// records the result.
typedef ToolCall = Future<String> Function(
    int step, String idempotencyKey, TaskState state);

/// Called by the loop when a step has COMPLETED, so the task can fold the
/// result into its own [TaskState.data] (e.g. replace a running summary).
/// This is the only place task content changes, which is what makes a
/// snapshot taken mid-step safe: [data] is always "as of the last finished
/// step". The harness itself never looks inside [data].
typedef ApplyResult = void Function(int step, String result, TaskState state);

/// Runs a multi-step agent loop where each "step" dispatches a REAL,
/// external, non-idempotent action via [toolCall] — not a fake delay.
///
/// This is intentionally the hardest part of the mechanism: a handoff
/// trigger can fire while a step is mid-flight (the real HTTP request is
/// in the air, response not yet received), and the resuming device must
/// not just re-run it and hope for the best — because this time, running
/// it twice leaves real, visible evidence outside the app.
class AgentSimulator {
  final void Function(TaskState state) onTick;
  final void Function(String log) onLog;
  final ToolCall toolCall;
  final ApplyResult? applyResult;

  /// Called when a real call finishes AFTER this device has already
  /// handed off ownership — the exact "stray, late-arriving completion"
  /// case. Wiring this up is what lets the app itself notice a
  /// divergence, instead of a human having to compare two screens by
  /// eye. Only fired for calls that actually completed with a real
  /// result — a late failure has nothing to compare, so it's just logged.
  final void Function(int step, String idempotencyKey, String resultText)?
      onLateCompletion;

  Timer? _retryTimer;
  bool _running = false;
  bool _stepInProgress = false;

  AgentSimulator({
    required this.onTick,
    required this.onLog,
    required this.toolCall,
    this.applyResult,
    this.onLateCompletion,
  });

  /// Starts (or resumes) running a task from the given state.
  /// If the state was received mid-flight (pendingAction is set and not
  /// yet in this device's own log as completed), we decide here how to
  /// handle it — this is the exact "did I already send the email" moment.
  void runFrom(TaskState state) {
    _running = true;

    if (state.pendingAction != null) {
      final key = state.pendingAction!.idempotencyKey;
      final alreadyLogged = state.log.any((e) => e.idempotencyKey == key);

      if (alreadyLogged &&
          state.log.firstWhere((e) => e.idempotencyKey == key).status ==
              ActionStatus.completed) {
        // The action actually completed before the handoff — just wasn't
        // marked non-pending yet. Safe to move on, don't redo it.
        onLog('Resume: step ${state.pendingAction!.forStep} was already '
            'completed under key $key — skipping re-run, advancing.');
        state.stepIndex = state.pendingAction!.forStep;
        state.pendingAction = null;
      } else {
        // Genuinely unknown whether the real call completed on the other
        // end before the handoff happened. This is the real, unavoidable
        // ambiguity: the request may have been received by the server
        // even though this device never saw the response. We re-dispatch
        // under the SAME idempotency key — deliberately, not by
        // accident — so that afterward you can look at the webhook log
        // and see with your own eyes whether this produced one entry or
        // two for that key. A real production system would need either
        // a server that de-duplicates by key, or a way to query "did
        // this key already happen" before re-sending. This POC does
        // NOT hide that gap — it's built to make the gap visible.
        onLog('Resume: step ${state.pendingAction!.forStep} outcome unknown '
            'under key $key — re-dispatching under the SAME key so the '
            'result is checkable afterward.');
      }
    }

    _runLoop(state);
  }

  void pause() {
    _running = false;
    _retryTimer?.cancel();
  }

  void _runLoop(TaskState state) async {
    if (!_running || state.stepIndex >= state.targetStep) {
      state.status = 'completed';
      onTick(state);
      return;
    }

    final nextStep = state.stepIndex + 1;
    // Reuse the pending key if we're resuming a step that was already
    // marked in-flight (the re-dispatch case above) — otherwise mint a
    // fresh one. Either way, this key is what a real backend would use
    // to detect a duplicate.
    final key = (state.pendingAction?.forStep == nextStep)
        ? state.pendingAction!.idempotencyKey
        : _uuid.v4();
    final startedAt = DateTime.now().millisecondsSinceEpoch;

    // Mark in-flight BEFORE the real call goes out — this is what makes
    // the state migratable mid-action instead of only between actions.
    state.pendingAction = PendingAction(
      idempotencyKey: key,
      forStep: nextStep,
      startedAt: startedAt,
    );
    state.status = 'running';
    onTick(state);
    onLog('Step $nextStep: dispatching REAL call (key $key)...');

    _stepInProgress = true;
    ActionStatus resultStatus;
    String? resultText;
    try {
      resultText = await toolCall(nextStep, key, state);
      resultStatus = ActionStatus.completed;
      onLog('Step $nextStep: confirmed completed (key $key). '
          'Response: "${resultText.length > 80 ? "${resultText.substring(0, 80)}..." : resultText}"');
    } catch (e) {
      // A thrown error here does NOT mean the action didn't happen on
      // the far end — only that THIS device didn't get a clean
      // response. That ambiguity is the whole point of this version of
      // the POC. We log it as failed locally, which means a future
      // resume will treat it as "outcome unknown" and re-dispatch under
      // the same key, rather than silently pretending it's fine.
      resultStatus = ActionStatus.failed;
      resultText = 'error: $e';
      onLog('Step $nextStep: call did not confirm (key $key) — $e. '
          'Outcome is genuinely unknown, not necessarily failed.');
    }
    _stepInProgress = false;

    if (!_running) {
      // Handed off / paused while we were waiting on the call above.
      // Leave pendingAction as-is (still marked in-flight) so the
      // receiving device sees it and makes its own resume decision —
      // do NOT advance stepIndex here, even if resultStatus ended up
      // "completed," because the handoff snapshot may have already
      // been taken and sent before this line ever ran.
      //
      // But a completed result here is real, useful evidence — surface
      // it rather than silently dropping it, so whoever now owns the
      // task can compare it against their own result for this key.
      if (resultStatus == ActionStatus.completed) {
        onLog('Step $nextStep: call actually completed AFTER handoff '
            '(key $key). Forwarding as a late completion so it can be '
            'checked against whatever this step\'s outcome was on the '
            'device that took over.');
        onLateCompletion?.call(nextStep, key, resultText!);
      }
      return;
    }

    state.log.add(LogEntry(
      step: nextStep,
      idempotencyKey: key,
      status: resultStatus,
      result: resultText,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));

    if (resultStatus == ActionStatus.completed) {
      state.stepIndex = nextStep;
      state.pendingAction = null;
      // Let the task fold this step's result into its own data. This is
      // the checkpoint: it only advances here, on confirmed completion.
      applyResult?.call(nextStep, resultText!, state);
      onTick(state);
      _runLoop(state);
    } else {
      // Retry the same step under the same key after a short pause,
      // rather than looping tightly — mirrors how a real agent would
      // back off before retrying a flaky call.
      onTick(state);
      _retryTimer = Timer(const Duration(seconds: 2), () {
        if (_running) _runLoop(state);
      });
    }
  }

  void dispose() {
    _running = false;
    _retryTimer?.cancel();
  }
}
