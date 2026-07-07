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

  /// Merge a delta payload from the SSE stream into this snapshot. The stream
  /// only carries the fields that changed in the latest publish. Bumps the
  /// `updateTick` so animated widgets can detect "a fresh value arrived" even
  /// when the numeric value happens to be identical to the previous reading.
  TelemetrySnapshot mergeDelta(Map<String, dynamic> delta) {
    // SSE detection events carry a nested {"detection": {issue, confidence, at}};
    // actuator events carry {"actuator": {on, reason, bound, since}}.
    final det = delta['detection'];
    final hasDet = det is Map;
    final act = delta['actuator'];
    final hasAct = act is Map;
    return TelemetrySnapshot(
      nodeId: nodeId,
      moisture: (delta['moisture'] as num?)?.toDouble() ?? moisture,
      temperature: (delta['temperature'] as num?)?.toDouble() ?? temperature,
      ec: (delta['ec'] as num?)?.toDouble() ?? ec,
      batteryPct: (delta['battery_pct'] as num?)?.toDouble() ?? batteryPct,
      timestamp: DateTime.now(),
      resetReason: resetReason,
      freeHeap: freeHeap,
      lastSeen: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      profile: profile,
      detectionIssue: hasDet ? det['issue'] as String? : detectionIssue,
      detectionConfidence: hasDet
          ? (det['confidence'] as num?)?.toDouble()
          : detectionConfidence,
      detectionAt: hasDet && det['at'] != null
          ? DateTime.tryParse(det['at'] as String)
          : detectionAt,
      actuatorOn: hasAct ? act['on'] as bool? ?? actuatorOn : actuatorOn,
      actuatorReason: hasAct ? act['reason'] as String? : actuatorReason,
      actuatorBound: hasAct ? act['bound'] as String? ?? actuatorBound : actuatorBound,
      actuatorMode: hasAct ? act['mode'] as String? ?? actuatorMode : actuatorMode,
      updateTick: updateTick + 1,
    );
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

class DiagnosticSnapshot {
  final String issue;
  final double confidence;

  DiagnosticSnapshot({required this.issue, required this.confidence});

  factory DiagnosticSnapshot.fromJson(Map<String, dynamic> json) {
    return DiagnosticSnapshot(
      issue: json['issue'] as String,
      confidence: (json['confidence'] as num).toDouble(),
    );
  }
}
