import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/telemetry.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/painters.dart';
import '../widgets/telemetry_card.dart' show heroTagFor;

/// Full-screen technical readout for a single node. Reached by tapping a
/// telemetry card. Subscribes to the same SSE stream as the dashboard so the
/// figures here animate live as well — no polling.
class NodeDetailScreen extends StatefulWidget {
  final String nodeId;
  final TelemetrySnapshot initial;
  // Zone sibling (opposite kind) — soil for a camera, camera for a soil node.
  final TelemetrySnapshot? linked;

  const NodeDetailScreen({
    super.key,
    required this.nodeId,
    required this.initial,
    this.linked,
  });

  @override
  State<NodeDetailScreen> createState() => _NodeDetailScreenState();
}

class _NodeDetailScreenState extends State<NodeDetailScreen> {
  late TelemetrySnapshot _snapshot;
  TelemetrySnapshot? _linked;
  StreamSubscription<Map<String, dynamic>>? _liveSub;
  Timer? _staleTimer;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initial;
    _linked = widget.linked;
    _subscribeLive();
    // Re-render every 15 s so "LAST CONTACT" counters tick up even when no
    // SSE event arrives — otherwise the panel would freeze on whatever value
    // was last received and pretend it's still fresh.
    _staleTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  void _subscribeLive() {
    final api = context.read<AppState>().api;
    if (api == null) return;
    _liveSub = api.streamTelemetry().listen(
      (event) {
        if (!mounted) return;
        final nodeId = event['node_id'];
        final isSelf = nodeId == widget.nodeId;
        final isPeer = _linked != null && nodeId == _linked!.nodeId;
        if (!isSelf && !isPeer) return;
        final data = event['data'] as Map<String, dynamic>?;
        if (data == null) return;
        // Typed envelope — alerts are handled by the dashboard's alert bar,
        // everything else merges via the model's single dispatcher.
        final type = data['type'] as String? ?? '';
        if (type == 'alert') return;
        final payload =
            (data['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
        setState(() {
          if (isSelf) {
            _snapshot = _snapshot.applyEvent(type, payload);
          } else {
            _linked = _linked!.applyEvent(type, payload);
          }
        });
      },
      cancelOnError: false,
    );
  }

  Future<void> _sendCommand(String action) async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    HapticFeedback.mediumImpact();
    try {
      final res = await api.sendZoneCommand(widget.nodeId, action);
      if (!mounted) return;
      // Optimistic local update; the SSE actuator event confirms shortly after.
      setState(() => _snapshot = _snapshot.applyEvent('actuator', {
            'on': res['on'],
            'reason': res['reason'] ?? res['blocked'],
            'bound': _snapshot.actuatorBound ?? 'virtual',
            'mode': _snapshot.actuatorMode,
          }));
      _toast(res['blocked'] != null
          ? 'Blocked: ${res['blocked']}'
          : 'Irrigation ${action.toUpperCase()}');
    } catch (e) {
      _toast('Command failed: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: AppText.monoValue),
        backgroundColor: AppColors.bgLift,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    _staleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _snapshot;
    return Scaffold(
      body: NatureBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailHeader(snapshot: s),
                const SizedBox(height: AppSpace.lg),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (s.isCamera) ...[
                          _VisionPanel(nodeId: widget.nodeId, snapshot: s),
                          const SizedBox(height: AppSpace.lg),
                        ] else ...[
                          _HeroPanel(snapshot: s),
                          const SizedBox(height: AppSpace.lg),
                          _ReadingsPanel(snapshot: s),
                          const SizedBox(height: AppSpace.lg),
                          _ActuatorPanel(
                            snapshot: s,
                            onOn: () => _sendCommand('on'),
                            onOff: () => _sendCommand('off'),
                          ),
                          const SizedBox(height: AppSpace.lg),
                          _HistoryChartPanel(nodeId: widget.nodeId),
                          const SizedBox(height: AppSpace.lg),
                        ],
                        if (_linked != null) ...[
                          _ZonePanel(self: s, peer: _linked!),
                          const SizedBox(height: AppSpace.lg),
                        ],
                        _DiagnosticsPanel(snapshot: s),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  const _DetailHeader({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final stale = snapshot.isStale;
    final color = stale ? AppColors.warning : AppColors.health;
    return Container(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.glassBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back,
                size: 16, color: AppColors.textSecondary),
            tooltip: 'Back to grid',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('Node Detail // Live Readout'),
                const SizedBox(height: AppSpace.xs),
                Text(snapshot.nodeId.toUpperCase(), style: AppText.title),
              ],
            ),
          ),
          LiveIndicator(color: color),
          const SizedBox(width: AppSpace.sm),
          Text(
            stale ? 'STALE' : 'LIVE',
            style: AppText.monoCaption.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// Moisture-state accent color, matching the telemetry card's gauge so the
/// Hero flight morphs geometry without a color jump.
Color _moistureColor(double? m) {
  if (m == null) return AppColors.textSecondary;
  if (m >= 40 && m <= 70) return AppColors.health;
  if ((m >= 25 && m < 40) || (m > 70 && m <= 85)) return AppColors.warning;
  return AppColors.alert;
}

/// Headline moisture, scaled up vs the card view. The gauge is the shared Hero
/// element that flies in from the tapped card.
class _HeroPanel extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  const _HeroPanel({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final m = snapshot.moisture;
    final c = _moistureColor(m);
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Hero(
            tag: heroTagFor(snapshot.nodeId),
            child: MoistureGauge(
              moisture: m,
              color: c,
              size: 148,
              valueFontSize: 46,
            ),
          ),
          const SizedBox(width: AppSpace.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('Soil Moisture'),
                const SizedBox(height: AppSpace.md),
                MicroBar(
                  label: 'Saturation',
                  valueText: m == null ? '--' : '${m.toStringAsFixed(1)}%',
                  ratio: (m ?? 0) / 100.0,
                  color: c,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Four-quadrant grid of supporting readings.
class _ReadingsPanel extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  const _ReadingsPanel({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Telemetry'),
          const SizedBox(height: AppSpace.md),
          // No temp sensor on the current hardware; mains-powered nodes report
          // no battery, so power reads full.
          Row(
            children: [
              Expanded(child: _Stat(label: 'EC', value: snapshot.ec, unit: 'mS/cm')),
              Expanded(
                child: snapshot.isMains
                    ? const _Stat(label: 'Power // Mains', value: 100, unit: '%')
                    : _Stat(label: 'Battery', value: snapshot.batteryPct, unit: '%'),
              ),
            ],
          ),
          const TechnicalDivider(),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: 'Free Heap',
                  value: snapshot.freeHeap?.toDouble(),
                  unit: 'bytes',
                  isInt: true,
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final double? value;
  final String unit;
  final bool isInt;
  const _Stat({
    required this.label,
    required this.value,
    required this.unit,
    this.isInt = false,
  });

  @override
  Widget build(BuildContext context) {
    final v = value;
    String text;
    if (v == null) {
      text = '--';
    } else if (isInt) {
      text = v.toInt().toString();
    } else {
      text = v.toStringAsFixed(1);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: AppText.monoCaption),
          const SizedBox(height: AppSpace.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(text,
                  style: AppText.monoValue.copyWith(
                      fontSize: 24, color: AppColors.textPrimary)),
              const SizedBox(width: 4),
              Text(unit, style: AppText.monoCaption),
            ],
          ),
        ],
      ),
    );
  }
}

/// InfluxDB-backed moisture history with a range selector, rendered with
/// fl_chart. Replaces the old client-side sparkline — this is real persisted
/// time-series queried from the backend.
class _HistoryChartPanel extends StatefulWidget {
  final String nodeId;
  const _HistoryChartPanel({required this.nodeId});

  @override
  State<_HistoryChartPanel> createState() => _HistoryChartPanelState();
}

class _HistoryChartPanelState extends State<_HistoryChartPanel> {
  static const _ranges = ['1h', '24h', '7d'];
  String _range = '24h';
  List<({DateTime t, double v})> _points = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() => _loading = true);
    try {
      final pts = await api.fetchHistory(widget.nodeId, 'moisture', _range);
      if (!mounted) return;
      setState(() {
        _points = pts;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _points = const [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                  child: SectionLabel('Moisture History // InfluxDB')),
              for (final r in _ranges) _RangeChip(
                label: r,
                selected: r == _range,
                onTap: () {
                  setState(() => _range = r);
                  _load();
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          SizedBox(height: 160, child: _chartBody()),
          if (_points.length >= 2) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              'MIN ${_min().toStringAsFixed(1)}%  //  MAX ${_max().toStringAsFixed(1)}%  //  ${_points.length} PTS',
              style: AppText.monoCaption,
            ),
          ],
        ],
      ),
    );
  }

  Widget _chartBody() {
    if (_loading) {
      return Center(child: Text('LOADING HISTORY...', style: AppText.monoCaption));
    }
    if (_points.length < 2) {
      return Center(
        child: Text('NOT ENOUGH DATA FOR THIS RANGE', style: AppText.monoCaption),
      );
    }
    final spots = <FlSpot>[
      for (var i = 0; i < _points.length; i++)
        FlSpot(i.toDouble(), _points[i].v),
    ];
    final minY = (_min() - 5).clamp(0, 100).toDouble();
    final maxY = (_max() + 5).clamp(0, 100).toDouble();
    return LineChart(
      duration: AppMotion.draw,
      curve: AppMotion.emphasize,
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: AppColors.sageFaint, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          bottomTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(0),
                style: AppText.monoCaption.copyWith(fontSize: 9),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: AppColors.health,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.health.withValues(alpha: 0.28),
                  AppColors.health.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _min() => _points.map((p) => p.v).reduce((a, b) => a < b ? a : b);
  double _max() => _points.map((p) => p.v).reduce((a, b) => a > b ? a : b);
}

class _RangeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = selected ? AppColors.health : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(left: AppSpace.sm),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.health.withValues(alpha: 0.10)
                  : Colors.transparent,
              border: Border.all(color: c.withValues(alpha: 0.4)),
            ),
            child: Text(
              label.toUpperCase(),
              style: AppText.monoCaption.copyWith(color: c),
            ),
          ),
        ),
      ),
    );
  }
}

/// Irrigation actuator panel for a soil zone: current state + manual ON/OFF.
/// Shows a VIRTUAL badge when no controller node is bound, so the operator
/// knows the relay is simulated.
class _ActuatorPanel extends StatefulWidget {
  final TelemetrySnapshot snapshot;
  final VoidCallback onOn;
  final VoidCallback onOff;
  const _ActuatorPanel({
    required this.snapshot,
    required this.onOn,
    required this.onOff,
  });

  @override
  State<_ActuatorPanel> createState() => _ActuatorPanelState();
}

class _ActuatorPanelState extends State<_ActuatorPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final on = snapshot.actuatorOn == true;
    final virtual = snapshot.actuatorBound != 'hardware';
    final c = on ? AppColors.health : AppColors.textSecondary;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('Irrigation // Actuator')),
              if (virtual)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.5)),
                  ),
                  child: Text('VIRTUAL',
                      style: AppText.monoCaption.copyWith(
                          color: AppColors.warning, fontSize: 9, letterSpacing: 1.5)),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Icon(Icons.water_drop, size: 28, color: c),
              const SizedBox(width: AppSpace.sm),
              Text(on ? 'ON' : 'OFF',
                  style: AppText.metric.copyWith(fontSize: 36, color: c)),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            'MODE ${(snapshot.actuatorMode ?? '--').toUpperCase()}  //  ${(snapshot.actuatorReason ?? '--').toUpperCase()}',
            style: AppText.monoCaption,
          ),
          const SizedBox(height: AppSpace.md),
          // Marching-dash flow line: animates left→right while irrigating, a
          // faint static rule when off.
          SizedBox(
            height: 8,
            child: AnimatedBuilder(
              animation: _flow,
              builder: (_, __) => CustomPaint(
                painter: FlowLinePainter(
                  phase: _flow.value,
                  active: on,
                  color: AppColors.health,
                ),
              ),
            ),
          ),
          const TechnicalDivider(),
          Row(
            children: [
              Expanded(
                child: CommandButton(
                  label: 'IRRIGATE ON',
                  color: AppColors.health,
                  expand: true,
                  onTap: widget.onOn,
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: CommandButton(
                  label: 'STOP OFF',
                  color: AppColors.alert,
                  expand: true,
                  onTap: widget.onOff,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Camera node: the latest captured frame plus the disease detection and
/// recommended treatments. Fetches the image bytes and diagnostics once on
/// mount (both are auth-gated, so they go through ApiService, not a bare
/// Image.network).
class _VisionPanel extends StatefulWidget {
  final String nodeId;
  final TelemetrySnapshot snapshot;
  const _VisionPanel({required this.nodeId, required this.snapshot});

  @override
  State<_VisionPanel> createState() => _VisionPanelState();
}

class _VisionPanelState extends State<_VisionPanel>
    with SingleTickerProviderStateMixin {
  Uint8List? _image;
  bool _loadingImage = true;
  List<dynamic>? _treatments;

  late final AnimationController _scan = AnimationController(
    vsync: this,
    duration: AppMotion.draw,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _VisionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A fresh detection (new timestamp) re-runs the analysis scanline sweep.
    if (widget.snapshot.detectionAt != oldWidget.snapshot.detectionAt) {
      _scan.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    final img = await api.fetchCameraFrame(widget.nodeId);
    final diag = await api.fetchDiagnostics(widget.nodeId);
    if (!mounted) return;
    setState(() {
      _image = img;
      _loadingImage = false;
      _treatments = diag?['treatments'] as List<dynamic>?;
    });
    // Sweep once the frame is on screen.
    if (_image != null) _scan.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final healthy = s.detectionHealthy;
    final c = s.hasDetection
        ? (healthy ? AppColors.health : AppColors.alert)
        : AppColors.textSecondary;
    final conf = (s.detectionConfidence ?? 0).clamp(0.0, 1.0);

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Crop Vision // Latest Detection'),
          const SizedBox(height: AppSpace.md),
          // Captured frame — the shared Hero element flying in from the card,
          // with viewfinder brackets and an analysis scanline sweep.
          Hero(
            tag: heroTagFor(widget.nodeId),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.insetFill,
                  border: Border.all(color: c.withValues(alpha: 0.4)),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_loadingImage)
                      Center(
                          child: Text('LOADING FRAME...',
                              style: AppText.monoCaption))
                    else if (_image != null)
                      Image.memory(_image!, fit: BoxFit.cover)
                    else
                      Center(
                          child: Text('NO FRAME CACHED',
                              style: AppText.monoCaption)),
                    if (_image != null) ...[
                      AnimatedBuilder(
                        animation: _scan,
                        builder: (_, __) => CustomPaint(
                          painter: ScanlinePainter(t: _scan.value, color: c),
                        ),
                      ),
                      CustomPaint(painter: CornerBracketsPainter(color: c)),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          if (s.hasDetection) ...[
            Text(s.detectionShort,
                style: AppText.title.copyWith(color: c, fontSize: 28)),
            const SizedBox(height: AppSpace.xs),
            Text(s.detectionIssue!.toUpperCase(), style: AppText.monoCaption),
            const SizedBox(height: AppSpace.md),
            MicroBar(
              label: 'Confidence',
              valueText: '${(conf * 100).toStringAsFixed(1)}%',
              ratio: conf,
              color: c,
            ),
          ] else
            Text('NO DETECTION YET', style: AppText.monoCaption),
          if (_treatments != null && _treatments!.isNotEmpty) ...[
            const TechnicalDivider(),
            const SectionLabel('Recommended Treatment'),
            const SizedBox(height: AppSpace.sm),
            for (final t in _treatments!)
              _TreatmentBlock(treatment: t as Map<String, dynamic>),
          ],
        ],
      ),
    );
  }
}

class _TreatmentBlock extends StatelessWidget {
  final Map<String, dynamic> treatment;
  const _TreatmentBlock({required this.treatment});

  @override
  Widget build(BuildContext context) {
    final type = (treatment['type'] as String? ?? '').toUpperCase();
    final actions = (treatment['actions'] as List<dynamic>? ?? []).cast<String>();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('[$type]',
              style: AppText.monoCaption.copyWith(color: AppColors.health)),
          const SizedBox(height: AppSpace.xs),
          for (final a in actions)
            Padding(
              padding: const EdgeInsets.only(left: AppSpace.sm, bottom: 2),
              child: Text('- $a',
                  style: AppText.monoValue.copyWith(height: 1.4)),
            ),
        ],
      ),
    );
  }
}

/// Zone link panel: the linked sibling of the opposite kind. On a camera detail
/// it shows the zone's live soil readings; on a soil detail, the zone camera's
/// latest diagnosis. [peer] is the sibling's own snapshot, kept live via SSE.
class _ZonePanel extends StatelessWidget {
  final TelemetrySnapshot self;
  final TelemetrySnapshot peer;
  const _ZonePanel({required this.self, required this.peer});

  @override
  Widget build(BuildContext context) {
    final showSoil = self.isCamera;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.link, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: SectionLabel(
                    '${showSoil ? 'Zone Soil' : 'Zone Vision'} // ${peer.nodeId}'),
              ),
              _JumpChip(nodeId: peer.nodeId, initial: peer, linked: self),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          if (showSoil) ...[
            Row(
              children: [
                Expanded(child: _Stat(label: 'Soil Moisture', value: peer.moisture, unit: '%')),
                Expanded(child: _Stat(label: 'EC', value: peer.ec, unit: 'mS/cm')),
              ],
            ),
            const TechnicalDivider(),
            Row(
              children: [
                Expanded(
                  child: peer.isMains
                      ? const _Stat(label: 'Power // Mains', value: 100, unit: '%')
                      : _Stat(label: 'Battery', value: peer.batteryPct, unit: '%'),
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ] else
            _visionSummary(),
        ],
      ),
    );
  }

  Widget _visionSummary() {
    if (!peer.hasDetection) {
      return Text('NO SCAN YET FROM ZONE CAMERA', style: AppText.monoCaption);
    }
    final c = peer.detectionHealthy ? AppColors.health : AppColors.alert;
    final conf = (peer.detectionConfidence ?? 0).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(peer.detectionShort,
            style: AppText.title.copyWith(color: c, fontSize: 24)),
        const SizedBox(height: AppSpace.sm),
        MicroBar(
          label: 'Confidence',
          valueText: '${(conf * 100).toStringAsFixed(0)}%',
          ratio: conf,
          color: c,
        ),
      ],
    );
  }
}

/// Small "open" chip that navigates to the linked node's own detail screen.
class _JumpChip extends StatelessWidget {
  final String nodeId;
  final TelemetrySnapshot initial;
  final TelemetrySnapshot linked;
  const _JumpChip(
      {required this.nodeId, required this.initial, required this.linked});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                NodeDetailScreen(nodeId: nodeId, initial: initial, linked: linked),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Text('OPEN',
              style: AppText.monoCaption
                  .copyWith(fontSize: 9, letterSpacing: 1.2)),
        ),
      ),
    );
  }
}

class _DiagnosticsPanel extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  const _DiagnosticsPanel({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final profile = snapshot.profile ?? const <String, String>{};
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Firmware & Pairing'),
          const SizedBox(height: AppSpace.md),
          _kv('Kind', profile['kind'] ?? '—'),
          _kv('Label', profile['label']?.isNotEmpty == true
              ? profile['label']!
              : '—'),
          _kv('Firmware', profile['fw']?.isNotEmpty == true
              ? profile['fw']!
              : '—'),
          _kv('Last Reset', snapshot.resetReason ?? '—'),
          _kv('Last Contact',
              snapshot.ageSeconds == null
                  ? '—'
                  : '${snapshot.ageSeconds!} s ago'),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k.toUpperCase(), style: AppText.monoCaption),
            Text(v, style: AppText.monoValue),
          ],
        ),
      );
}
