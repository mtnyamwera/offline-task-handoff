import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// UDP-based discovery. Separate from the TCP handoff channel (port 5891)
/// on purpose — broadcast/discovery is "who's out there," the TCP socket
/// is "the actual handoff," and keeping them on different ports means a
/// busy handoff transfer never gets confused with routine presence
/// announcements.
const int kDiscoveryPort = 5892;

/// One device's self-reported status, broadcast periodically.
class PeerStatus {
  final String deviceId;
  final String ip;
  final int battery; // 0-100, simulated via UI slider for this POC
  final int signal; // 0-100, simulated via UI slider for this POC
  final bool busy; // already running a handed-off task
  final String role; // "candidate" (can receive handoffs/results) or
                      // "originator" (started a task, awaiting its result)
  final int lastSeen; // local timestamp when THIS device received it

  PeerStatus({
    required this.deviceId,
    required this.ip,
    required this.battery,
    required this.signal,
    required this.busy,
    this.role = 'candidate',
    required this.lastSeen,
  });

  /// Simple weighted score — higher is a better handoff target.
  /// Busy peers are heavily penalized rather than excluded outright, so
  /// they still show up in the UI (useful for debugging) but are very
  /// unlikely to be picked while a better option exists.
  double get score {
    final base = (battery * 0.6) + (signal * 0.4);
    return busy ? base - 1000 : base;
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'ip': ip,
        'battery': battery,
        'signal': signal,
        'busy': busy,
        'role': role,
      };

  factory PeerStatus.fromJson(Map<String, dynamic> json, int lastSeen) =>
      PeerStatus(
        deviceId: json['deviceId'] as String,
        ip: json['ip'] as String,
        battery: json['battery'] as int,
        signal: json['signal'] as int,
        busy: json['busy'] as bool,
        role: json['role'] as String? ?? 'candidate',
        lastSeen: lastSeen,
      );
}

/// A device's ID must survive an app restart for the mailbox (Step 3) to
/// work at all — otherwise a phone that comes back "later" would look
/// like a brand-new, unrecognized device, and nothing could ever be
/// delivered to it. Persisted as a plain file; simple on purpose for a
/// POC, not meant to survive a full device wipe.
Future<String> getOrCreatePersistentDeviceId() async {
  final file = File('${Directory.systemTemp.path}/agent_poc_device_id.txt');
  if (await file.exists()) {
    final existing = (await file.readAsString()).trim();
    if (existing.isNotEmpty) return existing;
  }
  final fresh = DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
      (100 + DateTime.now().microsecond % 900).toString();
  await file.writeAsString(fresh, flush: true);
  return fresh;
}

/// Finds this device's own LAN IPv4 address (not loopback, not link-local
/// virtual adapters where avoidable) — this is what gets embedded in our
/// own broadcast so other devices know where to send a TCP handoff.
Future<String> getLocalIp() async {
  for (final iface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  )) {
    for (final addr in iface.addresses) {
      if (!addr.isLoopback) return addr.address;
    }
  }
  return '127.0.0.1'; // fallback; handoff will simply fail to reach anyone
}

/// Runs on a candidate device (e.g. each laptop). Periodically broadcasts
/// this device's own status so source devices can discover it.
class PeerAnnouncer {
  final String deviceId;
  int Function() getBattery;
  int Function() getSignal;
  bool Function() getBusy;
  final String role;

  Timer? _timer;
  RawDatagramSocket? _socket;

  PeerAnnouncer({
    required this.deviceId,
    required this.getBattery,
    required this.getSignal,
    required this.getBusy,
    this.role = 'candidate',
  });

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.broadcastEnabled = true;
    final ip = await getLocalIp();

    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      final status = PeerStatus(
        deviceId: deviceId,
        ip: ip,
        battery: getBattery(),
        signal: getSignal(),
        busy: getBusy(),
        role: role,
        lastSeen: 0, // irrelevant for outgoing packets
      );
      final bytes = utf8.encode(jsonEncode(status.toJson()));
      _socket!.send(
          bytes, InternetAddress('255.255.255.255'), kDiscoveryPort);
    });
  }

  void stop() {
    _timer?.cancel();
    _socket?.close();
  }
}

/// Runs on the device looking for a handoff target (e.g. the phone).
/// Listens for broadcasts, maintains a live map of recently-seen peers,
/// and prunes anyone who's gone quiet — that's how "device left the
/// mesh" is detected, without any explicit goodbye message required.
class PeerDiscovery {
  final void Function(Map<String, PeerStatus> peers) onUpdate;
  final String? selfId; // exclude our own broadcasts from candidate picks
  static const _staleAfter = Duration(seconds: 6);

  RawDatagramSocket? _socket;
  Timer? _pruneTimer;
  final Map<String, PeerStatus> _peers = {};

  PeerDiscovery({required this.onUpdate, this.selfId});

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kDiscoveryPort,
      reuseAddress: true,
    );
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket!.receive();
      if (datagram == null) return;
      try {
        final json = jsonDecode(utf8.decode(datagram.data))
            as Map<String, dynamic>;
        final status = PeerStatus.fromJson(
            json, DateTime.now().millisecondsSinceEpoch);
        _peers[status.deviceId] = status;
        onUpdate(Map.of(_peers));
      } catch (_) {
        // Ignore malformed packets — not every UDP broadcast on the LAN
        // is necessarily one of ours.
      }
    });

    _pruneTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final before = _peers.length;
      _peers.removeWhere((_, p) => now - p.lastSeen > _staleAfter.inMilliseconds);
      if (_peers.length != before) onUpdate(Map.of(_peers));
    });
  }

  /// The best current CANDIDATE (never an originator, never ourselves) —
  /// or null if nobody eligible has been heard from.
  PeerStatus? get best {
    final eligible = _peers.values
        .where((p) => p.role == 'candidate' && p.deviceId != selfId)
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return eligible.isEmpty ? null : eligible.first;
  }

  /// Look up one specific device by ID — used by the mailbox to check
  /// "has the original requester reappeared on the network yet?"
  /// regardless of how its battery/signal/role score.
  PeerStatus? byId(String deviceId) => _peers[deviceId];

  void stop() {
    _socket?.close();
    _pruneTimer?.cancel();
  }
}
