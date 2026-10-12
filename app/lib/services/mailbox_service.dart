import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'discovery_service.dart';
import 'transport_service.dart';

/// One result waiting to be delivered back to whoever started the task.
class PendingDelivery {
  final String taskId;
  final String originatorId;
  final Map<String, dynamic> result;

  PendingDelivery({
    required this.taskId,
    required this.originatorId,
    required this.result,
  });

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'originatorId': originatorId,
        'result': result,
      };

  factory PendingDelivery.fromJson(Map<String, dynamic> json) =>
      PendingDelivery(
        taskId: json['taskId'] as String,
        originatorId: json['originatorId'] as String,
        result: json['result'] as Map<String, dynamic>,
      );
}

/// Runs on a device that has just finished a task and needs to get the
/// result back to whoever originally asked for it — who may not be on
/// the network right now, and may not come back for a while.
///
/// Nothing here assumes the originator is reachable immediately. A
/// result is queued, persisted to local disk (so even a restart of THIS
/// device doesn't lose it), and retried periodically by checking the
/// live peer-discovery list for the originator's current IP. Only a
/// confirmed ACK (same two-phase discipline as the original handoff)
/// removes an entry from the queue.
class MailboxService {
  final PeerDiscovery discovery; // used to find the originator's live IP
  final void Function(String log) onLog;
  static const _queueFile = 'agent_poc_mailbox_queue.json';

  final List<PendingDelivery> _queue = [];
  Timer? _retryTimer;

  MailboxService({required this.discovery, required this.onLog});

  Future<void> start() async {
    await _loadQueue();
    if (_queue.isNotEmpty) {
      onLog('Mailbox: loaded ${_queue.length} undelivered result(s) from '
          'a previous run.');
    }
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (_) => _retryAll());
  }

  Future<void> enqueue({
    required String taskId,
    required String originatorId,
    required Map<String, dynamic> result,
  }) async {
    // Avoid double-queueing the same task if this somehow gets called
    // twice (e.g. a duplicate completion event).
    if (_queue.any((d) => d.taskId == taskId)) return;

    _queue.add(PendingDelivery(
      taskId: taskId,
      originatorId: originatorId,
      result: result,
    ));
    await _saveQueue();
    onLog('Mailbox: queued result for task ${taskId.substring(0, 8)}, '
        'waiting for originator $originatorId to be seen on the network.');
    _retryAll(); // try immediately, don't wait for the next timer tick
  }

  Future<void> _retryAll() async {
    if (_queue.isEmpty) return;
    final delivered = <PendingDelivery>[];

    for (final pending in List<PendingDelivery>.from(_queue)) {
      final originator = discovery.byId(pending.originatorId);
      if (originator == null) {
        // Originator hasn't been seen recently — this is the normal,
        // expected state while "the phone is gone for hours." Nothing
        // to do but wait for the next retry tick.
        continue;
      }

      onLog('Mailbox: originator ${pending.originatorId} is back on the '
          'network at ${originator.ip} — attempting delivery for task '
          '${pending.taskId.substring(0, 8)}.');

      final sender = SenderService(onLog: onLog);
      final confirmed = await sender.sendResult(
        targetIp: originator.ip,
        taskId: pending.taskId,
        result: pending.result,
      );

      if (confirmed) {
        delivered.add(pending);
      }
      // If not confirmed, it stays in the queue — same "don't assume
      // success" rule as everywhere else in this project.
    }

    if (delivered.isNotEmpty) {
      _queue.removeWhere((d) => delivered.any((x) => x.taskId == d.taskId));
      await _saveQueue();
    }
  }

  Future<void> _saveQueue() async {
    final file = File('${Directory.systemTemp.path}/$_queueFile');
    await file.writeAsString(
      jsonEncode(_queue.map((d) => d.toJson()).toList()),
      flush: true,
    );
  }

  Future<void> _loadQueue() async {
    final file = File('${Directory.systemTemp.path}/$_queueFile');
    if (!await file.exists()) return;
    try {
      final raw = jsonDecode(await file.readAsString()) as List;
      _queue.addAll(raw.map(
          (e) => PendingDelivery.fromJson(e as Map<String, dynamic>)));
    } catch (_) {
      // Corrupt or empty queue file — start clean rather than crash.
    }
  }

  int get pendingCount => _queue.length;

  void stop() {
    _retryTimer?.cancel();
  }
}
