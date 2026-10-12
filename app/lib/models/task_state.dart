/// The state object that gets migrated between devices.
///
/// Shaped deliberately like a real agent's state, not just an int, so the
/// mechanism proven here (idempotency checks, in-flight detection, two-phase
/// handoff) carries over unchanged when `stepIndex` becomes a real reasoning
/// step and `pendingAction` becomes a real tool call (web search, email send,
/// etc).

enum ActionStatus { inFlight, completed, failed }

class LogEntry {
  final int step;
  final String idempotencyKey;
  ActionStatus status;
  final String? result;
  final int timestamp;

  LogEntry({
    required this.step,
    required this.idempotencyKey,
    required this.status,
    this.result,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'step': step,
        'idempotencyKey': idempotencyKey,
        'status': status.name,
        'result': result,
        'timestamp': timestamp,
      };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        step: json['step'] as int,
        idempotencyKey: json['idempotencyKey'] as String,
        status: ActionStatus.values.byName(json['status'] as String),
        result: json['result'] as String?,
        timestamp: json['timestamp'] as int,
      );
}

class PendingAction {
  final String idempotencyKey;
  final int forStep;
  final int startedAt;

  PendingAction({
    required this.idempotencyKey,
    required this.forStep,
    required this.startedAt,
  });

  Map<String, dynamic> toJson() => {
        'idempotencyKey': idempotencyKey,
        'forStep': forStep,
        'startedAt': startedAt,
      };

  factory PendingAction.fromJson(Map<String, dynamic> json) => PendingAction(
        idempotencyKey: json['idempotencyKey'] as String,
        forStep: json['forStep'] as int,
        startedAt: json['startedAt'] as int,
      );
}

class TaskState {
  final String taskId;
  final String originatorId; // device that started this task — where the
                              // final result must eventually be delivered
  int stepIndex; // number of COMPLETED steps (0..targetStep)
  final int targetStep; // total number of steps
  // --- Generic task format. The harness (handoff, tagging, mailbox,
  // divergence checks) only understands the fields in this class.
  // Everything specific to WHAT the task is — a document and its running
  // summary, a form being filled in, anything else — lives in [data],
  // labelled by [taskType]. The harness copies [data] across devices
  // untouched, so a new kind of agent needs no harness changes.
  // Rules for [data]: keep it JSON-encodable (maps, lists, strings,
  // numbers), and change it only when a step COMPLETES, so a snapshot
  // taken mid-step carries "the state as of the last finished step".
  final String taskType;
  final Map<String, dynamic> data;
  String status; // "running" | "paused" | "completed"
  PendingAction? pendingAction; // null when no tool call is in flight
  final List<LogEntry> log;
  // Results the PREVIOUS owner of a step reported after handing over (the
  // late completions). Kept beside the log, never inside it, so the step
  // history (the log) is unchanged. One entry per (key, text); the outcome is
  // "held" (our own attempt was still running), "match", "divergence" or
  // "orphan". It is an audit trail: it never changes the task's own result.
  final List<Map<String, dynamic>> lateResults;

  TaskState({
    required this.taskId,
    required this.originatorId,
    required this.stepIndex,
    required this.targetStep,
    required this.status,
    this.pendingAction,
    required this.log,
    this.taskType = 'generic',
    Map<String, dynamic>? data,
    List<Map<String, dynamic>>? lateResults,
  })  : data = data ?? <String, dynamic>{},
        lateResults = lateResults ?? <Map<String, dynamic>>[];

  /// Record the other device's result for audit (see [lateResults]).
  void recordLate({
    required int step,
    required String key,
    required String text,
    required String outcome,
  }) {
    for (final e in lateResults) {
      if (e['idempotencyKey'] == key && e['result'] == text) {
        e['outcome'] = outcome;
        return;
      }
    }
    lateResults.add({
      'step': step,
      'idempotencyKey': key,
      'result': text,
      'receivedAt': DateTime.now().millisecondsSinceEpoch,
      'outcome': outcome,
    });
  }

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'originatorId': originatorId,
        'stepIndex': stepIndex,
        'targetStep': targetStep,
        'status': status,
        'pendingAction': pendingAction?.toJson(),
        'log': log.map((e) => e.toJson()).toList(),
        'taskType': taskType,
        'data': data,
        'lateResults': lateResults,
      };

  factory TaskState.fromJson(Map<String, dynamic> json) {
    final data = Map<String, dynamic>.from((json['data'] as Map?) ?? const {});
    // Backward compatibility: state saved by the earlier summarization-only
    // format kept these two fields at the top level.
    if (json['chunks'] != null) data.putIfAbsent('chunks', () => json['chunks']);
    if (json['runningSummary'] != null) {
      data.putIfAbsent('runningSummary', () => json['runningSummary']);
    }
    return TaskState(
      taskId: json['taskId'] as String,
      originatorId: json['originatorId'] as String,
      stepIndex: json['stepIndex'] as int,
      targetStep: json['targetStep'] as int,
      status: json['status'] as String,
      pendingAction: json['pendingAction'] == null
          ? null
          : PendingAction.fromJson(
              json['pendingAction'] as Map<String, dynamic>),
      log: (json['log'] as List)
          .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      taskType: json['taskType'] as String? ?? 'generic',
      data: data,
      lateResults: ((json['lateResults'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }

  TaskState copy() => TaskState.fromJson(toJson());
}
