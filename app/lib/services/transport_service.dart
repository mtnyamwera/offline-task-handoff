import 'dart:convert';
import 'dart:io';
import '../models/task_state.dart';

/// Local-network-only transport. Plain TCP socket over WiFi LAN — no
/// internet, no cloud, no account system. This stands in for WiFi
/// Direct / Bluetooth in the eventual version; the protocol above this
/// layer (two-phase ACK, idempotency checks) doesn't care which radio
/// carries the bytes.

const int kPort = 5891;
const String kMsgState = 'STATE';
const String kMsgResult = 'RESULT';
const String kMsgLateCompletion = 'LATE_COMPLETION';
const String kMsgAck = 'ACK';

/// Runs on the device that will RECEIVE a handoff (e.g. the laptop).
/// Listens for an incoming state push, applies it, and sends an ACK only
/// after the state has been durably written to local disk — never before.
class ReceiverService {
  ServerSocket? _server;
  final void Function(TaskState state) onStateReceived;
  final void Function(String taskId, Map<String, dynamic> result)?
      onResultReceived;
  final void Function(String taskId, int step, String idempotencyKey,
      String resultText)? onLateCompletion;
  final void Function(String log) onLog;

  ReceiverService({
    required this.onStateReceived,
    this.onResultReceived,
    this.onLateCompletion,
    required this.onLog,
  });

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, kPort);
    onLog('Listening on port $kPort (LAN only, no internet).');
    _server!.listen((Socket client) {
      // Collect RAW BYTES and find the end of the message (a newline byte,
      // 0x0A) BEFORE decoding. Decoding each network chunk on its own can
      // split a multi-byte UTF-8 character (’ — – …) across two chunks and
      // throw, which would leave the sender waiting for an ACK that never
      // comes. One message per connection: anything after the first
      // newline is ignored.
      final bytes = <int>[];
      var handled = false;
      client.listen(
        (data) async {
          if (handled) return;
          bytes.addAll(data);

          // Messages are newline-delimited (see SenderService). We parse as
          // soon as a full line has arrived — we do NOT wait for the
          // connection to close, because we need the connection to stay
          // open afterward to send the ACK back on it. Waiting for
          // onDone here would deadlock against a sender that's waiting on
          // this same connection for that ACK.
          final newlineAt = bytes.indexOf(10);
          if (newlineAt < 0) return;
          handled = true;

          try {
            final line = utf8.decode(bytes.sublist(0, newlineAt));
            final envelope = jsonDecode(line) as Map<String, dynamic>;

            if (envelope['type'] == kMsgState) {
              final state = TaskState.fromJson(
                  envelope['payload'] as Map<String, dynamic>);

              // --- Critical ordering ---
              // 1. Persist to local disk BEFORE acknowledging.
              // 2. Only after persistence succeeds, send ACK.
              // If we crash between receiving and persisting, the sender
              // never got an ACK and correctly assumes the handoff failed.
              await _persistState(state);
              onLog('State received + persisted locally: step ${state.stepIndex}.');

              client.add(utf8.encode(
                  '${jsonEncode({'type': kMsgAck, 'taskId': state.taskId})}\n'));
              await client.flush();

              onStateReceived(state);
            } else if (envelope['type'] == kMsgResult) {
              final taskId = envelope['taskId'] as String;
              final result = envelope['result'] as Map<String, dynamic>;

              // Same discipline as state: persist before acknowledging.
              await _persistResult(taskId, result);
              onLog('Result received + persisted locally for task '
                  '${taskId.substring(0, 8)}.');

              client.add(utf8.encode(
                  '${jsonEncode({'type': kMsgAck, 'taskId': taskId})}\n'));
              await client.flush();

              onResultReceived?.call(taskId, result);
            } else if (envelope['type'] == kMsgLateCompletion) {
              final taskId = envelope['taskId'] as String;
              final step = envelope['step'] as int;
              final key = envelope['idempotencyKey'] as String;
              final resultText = envelope['resultText'] as String;

              onLog('Late completion received for task ${taskId.substring(0, 8)}, '
                  'step $step, key $key — checking for divergence against our '
                  'own result for this key.');

              client.add(utf8.encode(
                  '${jsonEncode({'type': kMsgAck, 'taskId': taskId})}\n'));
              await client.flush();

              onLateCompletion?.call(taskId, step, key, resultText);
            }
          } catch (e) {
            onLog('Failed to process incoming message: $e');
          } finally {
            await client.close();
          }
        },
      );
    });
  }

  Future<void> _persistState(TaskState state) => persistTaskState(state);

  Future<void> _persistResult(String taskId, Map<String, dynamic> result) async {
    final file =
        File('${Directory.systemTemp.path}/result_$taskId.json');
    await file.writeAsString(jsonEncode(result), flush: true);
  }

  Future<void> stop() async {
    await _server?.close();
  }
}

/// Runs on the device that is HANDING OFF (e.g. the phone at 5% battery).
/// Sends state, waits for ACK, and only reports success once the ACK is
/// actually received. If the ACK never arrives (timeout, or this device
/// dies mid-send), the caller must assume the handoff did NOT happen and
/// keep running — never silently stop owning the task on a guess.
class SenderService {
  final void Function(String log) onLog;

  SenderService({required this.onLog});

  /// Returns true only if the target confirmed receipt with an ACK.
  /// Throws / returns false on any failure — caller must treat that as
  /// "handoff did not occur," not as an ambiguous case.
  Future<bool> sendState({
    required String targetIp,
    required TaskState state,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(targetIp, kPort, timeout: timeout);
      final envelope =
          '${jsonEncode({'type': kMsgState, 'payload': state.toJson()})}\n';
      socket.add(utf8.encode(envelope));
      await socket.flush();

      // Read data events directly — do NOT wait for the connection to
      // close. The receiver keeps this same connection open specifically
      // to write the ACK back on it, so waiting for onDone here would
      // deadlock against that. A timeout on the stream still protects us
      // if the receiver never responds at all.
      final ackBytes = <int>[];
      bool timedOut = false;
      await for (final chunk in socket.timeout(timeout, onTimeout: (sink) {
        timedOut = true;
        sink.close();
      })) {
        ackBytes.addAll(chunk);
        if (utf8.decode(ackBytes, allowMalformed: true).contains('\n')) break;
      }

      if (timedOut || ackBytes.isEmpty) {
        onLog('No ACK received before timeout — handoff NOT confirmed. '
            'This device must keep running the task.');
        return false;
      }

      final line = utf8.decode(ackBytes).split('\n').first;
      final response = jsonDecode(line) as Map<String, dynamic>;
      final confirmed = response['type'] == kMsgAck &&
          response['taskId'] == state.taskId;

      if (confirmed) {
        onLog('ACK confirmed for task ${state.taskId}. Safe to relinquish ownership.');
      } else {
        onLog('Unexpected response — treating as unconfirmed handoff.');
      }
      return confirmed;
    } catch (e) {
      onLog('Send failed ($e) — handoff NOT confirmed. This device must keep running.');
      return false;
    } finally {
      await socket?.close();
    }
  }

  /// Same discipline as sendState, for delivering a finished result back
  /// to the task's originator. Returns true only on a confirmed ACK — the
  /// mailbox relies on this to decide whether to stop retrying.
  Future<bool> sendResult({
    required String targetIp,
    required String taskId,
    required Map<String, dynamic> result,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(targetIp, kPort, timeout: timeout);
      final envelope =
          '${jsonEncode({'type': kMsgResult, 'taskId': taskId, 'result': result})}\n';
      socket.add(utf8.encode(envelope));
      await socket.flush();

      final ackBytes = <int>[];
      bool timedOut = false;
      await for (final chunk in socket.timeout(timeout, onTimeout: (sink) {
        timedOut = true;
        sink.close();
      })) {
        ackBytes.addAll(chunk);
        if (utf8.decode(ackBytes, allowMalformed: true).contains('\n')) break;
      }

      if (timedOut || ackBytes.isEmpty) {
        onLog('Result delivery: no ACK — will retry later.');
        return false;
      }

      final line = utf8.decode(ackBytes).split('\n').first;
      final response = jsonDecode(line) as Map<String, dynamic>;
      final confirmed =
          response['type'] == kMsgAck && response['taskId'] == taskId;
      onLog(confirmed
          ? 'Result delivery confirmed for task ${taskId.substring(0, 8)}.'
          : 'Result delivery: unexpected response — will retry later.');
      return confirmed;
    } catch (e) {
      onLog('Result delivery attempt failed ($e) — will retry later.');
      return false;
    } finally {
      await socket?.close();
    }
  }

  /// Forwards a stray, late-arriving result to whoever the task was
  /// handed off to — so it can be compared against their own result for
  /// the same idempotency key. This is what makes divergence DETECTABLE
  /// inside the app, rather than only visible by a human reading two
  /// separate device screens. If this fails (the target is no longer
  /// reachable, e.g. it has since handed off again itself), the
  /// divergence simply goes undetected this time — an honest, named
  /// limitation rather than something silently papered over.
  Future<bool> sendLateCompletion({
    required String targetIp,
    required String taskId,
    required int step,
    required String idempotencyKey,
    required String resultText,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(targetIp, kPort, timeout: timeout);
      final envelope = '${jsonEncode({
            'type': kMsgLateCompletion,
            'taskId': taskId,
            'step': step,
            'idempotencyKey': idempotencyKey,
            'resultText': resultText,
          })}\n';
      socket.add(utf8.encode(envelope));
      await socket.flush();

      final ackBytes = <int>[];
      bool timedOut = false;
      await for (final chunk in socket.timeout(timeout, onTimeout: (sink) {
        timedOut = true;
        sink.close();
      })) {
        ackBytes.addAll(chunk);
        if (utf8.decode(ackBytes, allowMalformed: true).contains('\n')) break;
      }

      if (timedOut || ackBytes.isEmpty) {
        onLog('Late completion for step $step: no ACK — target may no '
            'longer be reachable. Divergence check skipped this time.');
        return false;
      }

      final line = utf8.decode(ackBytes).split('\n').first;
      final response = jsonDecode(line) as Map<String, dynamic>;
      return response['type'] == kMsgAck && response['taskId'] == taskId;
    } catch (e) {
      onLog('Late completion for step $step: delivery failed ($e). '
          'Divergence check skipped this time.');
      return false;
    } finally {
      await socket?.close();
    }
  }
}

/// Write a task's saved state to disk. Used when a state is received and
/// again when a late result is recorded, so the audit trail survives a
/// restart.
Future<void> persistTaskState(TaskState state) async {
  final file = File('${Directory.systemTemp.path}/task_${state.taskId}.json');
  await file.writeAsString(jsonEncode(state.toJson()), flush: true);
}
