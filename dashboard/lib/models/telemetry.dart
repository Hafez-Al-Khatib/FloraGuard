class TelemetrySnapshot {
  final String nodeId;
  final double? moisture;
  final double? temperature;
  final double? ec;
  final double? batteryPct;
  final DateTime? timestamp;
  // Firmware diagnostics, populated by the MQTT subscriber from ESP32 reports.
  // A `resetReason` other than "deepsleep" or "poweron" indicates a crash worth
  // surfacing (panic, watchdog, brownout). `freeHeap` is a live health signal.
  final String? resetReason;
  final int? freeHeap;
  // Pairing metadata. `lastSeen` is the unix timestamp of the last device
  // contact (telemetry, MQTT, or hello); the card dims to "STALE" past 5 min.
  final int? lastSeen;
  final Map<String, String>? profile;
  // Latest camera disease detection (camera nodes). `detectionIssue` is the
  // raw PlantVillage label, e.g. "Tomato_Late_blight" or "Tomato_healthy".
  final String? detectionIssue;
  final double? detectionConfidence;
  final DateTime? detectionAt;
  // Irrigation actuator state (soil/zone nodes). `actuatorBound` is "virtual"
  // (no controller flashed) or "hardware" (a controller node is connected).
  final bool? actuatorOn;
  final String? actuatorReason;
  final String? actuatorBound;
  final String? actuatorMode;
  // Monotonic-ish counter incremented each time a fresh delta merges in.
  // Used by the card's AnimatedSwitcher to retrigger entrance animations on
  // every update so the operator gets visual confirmation a value is live.
  final int updateTick;

  TelemetrySnapshot({
    required this.nodeId,
    this.moisture,
    this.temperature,
    this.ec,
    this.batteryPct,
    this.timestamp,
    this.resetReason,
    this.freeHeap,
    this.lastSeen,
    this.profile,
    this.detectionIssue,
    this.detectionConfidence,
    this.detectionAt,
    this.actuatorOn,
    this.actuatorReason,
    this.actuatorBound,
    this.actuatorMode,
    this.updateTick = 0,
  });

  factory TelemetrySnapshot.fromJson(Map<String, dynamic> json) {
    final rawProfile = json['profile'];
    Map<String, String>? profile;
    if (rawProfile is Map) {
      profile = rawProfile.map(
        (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
      );
    }
    final det = json['detection'];
    final act = json['actuator'];
    return TelemetrySnapshot(
      nodeId: json['node_id'] as String,
      moisture: (json['moisture'] as num?)?.toDouble(),
      temperature: (json['temperature'] as num?)?.toDouble(),
      ec: (json['ec'] as num?)?.toDouble(),
      batteryPct: (json['battery_pct'] as num?)?.toDouble(),
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String)
          : null,
      resetReason: json['reset_reason'] as String?,
      freeHeap: (json['free_heap'] as num?)?.toInt(),
      lastSeen: (json['last_seen'] as num?)?.toInt(),
      profile: profile,
      detectionIssue: det is Map ? det['issue'] as String? : null,
      detectionConfidence:
          det is Map ? (det['confidence'] as num?)?.toDouble() : null,
      detectionAt: det is Map && det['timestamp'] != null
          ? DateTime.tryParse(det['timestamp'] as String)
          : null,
      actuatorOn: act is Map ? act['on'] as bool? : null,
      actuatorReason: act is Map ? act['reason'] as String? : null,
      actuatorBound: act is Map ? act['bound'] as String? : null,
      actuatorMode: act is Map ? act['mode'] as String? : null,
    );
  }

  /// True when this node is a controllable irrigation zone (has actuator state).
  bool get hasActuator => actuatorOn != null;

  /// True when a camera detection is present.
  bool get hasDetection => detectionIssue != null && detectionIssue!.isNotEmpty;

  /// True when this node is a camera (by profile or by having a detection).
  bool get isCamera => profile?['kind'] == 'camera' || hasDetection;

  /// True when the latest detection is a healthy leaf (no disease).
  bool get detectionHealthy {
    final i = detectionIssue;
    if (i == null) return true;
    return i.toLowerCase().contains('healthy');
  }

  /// Human-friendly short label for the detection, e.g.
  /// "Tomato_Late_blight" -> "Late Blight".
  String get detectionShort {
    final i = detectionIssue;
    if (i == null) return '--';
    // Drop the crop prefix, collapse separators, title-case.
    var s = i.replaceAll(RegExp(r'^[A-Za-z]+[_]+'), '');
    s = s.replaceAll(RegExp(r'[_]+'), ' ').trim();
    if (s.isEmpty) s = i;
    return s
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  /// A placeholder snapshot for a node we know exists (paired) but haven't
  /// received telemetry from yet. The card renders with "--" values but stays
  /// pinned to the grid so operators always see every paired plant.
  factory TelemetrySnapshot.placeholder(String nodeId) =>
      TelemetrySnapshot(nodeId: nodeId);

  /// Seconds since last contact. `null` when we have no last_seen yet.
  int? get ageSeconds {
    if (lastSeen != null) {
      return (DateTime.now().millisecondsSinceEpoch ~/ 1000) - lastSeen!;
    }
    if (timestamp != null) {
      return DateTime.now().difference(timestamp!).inSeconds;
    }
    return null;
  }

  /// True if the node has not contacted the hub in the last 5 minutes.
  bool get isStale {
    final age = ageSeconds;
    return age != null && age > 300;
  }

  /// True if we have at least one numeric reading. Placeholder cards return false.
  bool get hasReadings =>
      moisture != null ||
      temperature != null ||
      ec != null ||
      batteryPct != null;

  /// Whether the last boot looks healthy. Anything other than the two normal
  /// reasons (cold power-on or scheduled deep-sleep wake) gets a DIAG badge.
  bool get bootHealthy {
    if (resetReason == null) return true; // unknown — don't alarm
    return resetReason == 'deepsleep' || resetReason == 'poweron';
  }

  /// Field-by-field copy. THE single place that knows the full field list —
  /// refresh merges and SSE events both build on it, so a new field added to
  /// the constructor cannot silently vanish in a hand-rolled copy elsewhere.
  TelemetrySnapshot copyWith({
    double? moisture,
    double? temperature,
    double? ec,
    double? batteryPct,
    DateTime? timestamp,
    String? resetReason,
    int? freeHeap,
    int? lastSeen,
    Map<String, String>? profile,
    String? detectionIssue,
    double? detectionConfidence,
    DateTime? detectionAt,
    bool? actuatorOn,
    String? actuatorReason,
    String? actuatorBound,
    String? actuatorMode,
    int? updateTick,
  }) =>
      TelemetrySnapshot(
        nodeId: nodeId,
        moisture: moisture ?? this.moisture,
        temperature: temperature ?? this.temperature,
        ec: ec ?? this.ec,
        batteryPct: batteryPct ?? this.batteryPct,
        timestamp: timestamp ?? this.timestamp,
        resetReason: resetReason ?? this.resetReason,
        freeHeap: freeHeap ?? this.freeHeap,
        lastSeen: lastSeen ?? this.lastSeen,
        profile: profile ?? this.profile,
        detectionIssue: detectionIssue ?? this.detectionIssue,
        detectionConfidence: detectionConfidence ?? this.detectionConfidence,
        detectionAt: detectionAt ?? this.detectionAt,
        actuatorOn: actuatorOn ?? this.actuatorOn,
        actuatorReason: actuatorReason ?? this.actuatorReason,
        actuatorBound: actuatorBound ?? this.actuatorBound,
        actuatorMode: actuatorMode ?? this.actuatorMode,
        updateTick: updateTick ?? this.updateTick,
      );

  /// Merge a freshly fetched snapshot over this one (pull-to-refresh path).
  /// Fresh non-null values win; prior values survive gaps in the response.
  /// `updateTick` is preserved so the "fresh delta" animation only fires on
  /// real SSE deltas, not on every page-refresh re-fetch.
  TelemetrySnapshot merge(TelemetrySnapshot fresh) => copyWith(
        moisture: fresh.moisture,
        temperature: fresh.temperature,
        ec: fresh.ec,
        batteryPct: fresh.batteryPct,
        timestamp: fresh.timestamp,
        resetReason: fresh.resetReason,
        freeHeap: fresh.freeHeap,
        lastSeen: fresh.lastSeen,
        profile: fresh.profile,
        detectionIssue: fresh.detectionIssue,
        detectionConfidence: fresh.detectionConfidence,
        detectionAt: fresh.detectionAt,
        actuatorOn: fresh.actuatorOn,
        actuatorReason: fresh.actuatorReason,
        actuatorBound: fresh.actuatorBound,
        actuatorMode: fresh.actuatorMode,
      );

  /// Apply one typed SSE event (`data.type` from the server envelope).
  ///
  /// Only `telemetry` events refresh liveness — a server-generated actuator
  /// or detection event proves nothing about the device being alive, and
  /// stamping lastSeen for them masked real outages.
  TelemetrySnapshot applyEvent(String type, Map<String, dynamic> payload) {
    switch (type) {
      case 'telemetry':
        return copyWith(
          moisture: (payload['moisture'] as num?)?.toDouble(),
          temperature: (payload['temperature'] as num?)?.toDouble(),
          ec: (payload['ec'] as num?)?.toDouble(),
          batteryPct: (payload['battery_pct'] as num?)?.toDouble(),
          timestamp: DateTime.now(),
          lastSeen: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          updateTick: updateTick + 1,
        );
      case 'detection':
        return copyWith(
          detectionIssue: payload['issue'] as String?,
          detectionConfidence: (payload['confidence'] as num?)?.toDouble(),
          detectionAt: payload['at'] != null
              ? DateTime.tryParse(payload['at'] as String)
              : null,
          updateTick: updateTick + 1,
        );
      case 'actuator':
        return copyWith(
          actuatorOn: payload['on'] as bool?,
          actuatorReason: payload['reason'] as String?,
          actuatorBound: payload['bound'] as String?,
          actuatorMode: payload['mode'] as String?,
          updateTick: updateTick + 1,
        );
      case 'online':
        final rawProfile = payload['profile'];
        return copyWith(
          profile: rawProfile is Map
              ? rawProfile.map(
                  (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
                )
              : null,
          // A hello IS device contact — it authenticated to the hub just now.
          lastSeen: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
      default:
        return this; // unknown event types don't mutate the snapshot
    }
  }

  Map<String, dynamic> toJson() => {
        'node_id': nodeId,
        'moisture': moisture,
        'temperature': temperature,
        'ec': ec,
        'battery_pct': batteryPct,
        'timestamp': timestamp?.toIso8601String(),
        'reset_reason': resetReason,
        'free_heap': freeHeap,
      };
}
