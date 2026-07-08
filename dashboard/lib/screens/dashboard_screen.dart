import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/telemetry.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import '../widgets/telemetry_card.dart';
import 'automation_screen.dart';
import 'login_screen.dart';
import 'node_detail_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Live state: keyed by node_id, mutated by both the initial snapshot fetch
  // and the SSE stream. _loading is true until the first fetch completes.
  final Map<String, TelemetrySnapshot> _telemetry = {};
  bool _loading = true;
  String? _loadError;
  StreamSubscription<Map<String, dynamic>>? _liveSub;
  bool _liveConnected = false;
  bool _capturing = false;
  List<Map<String, dynamic>> _alerts = [];

  List<String> _nodes = [];
  String? _selectedNode;

  // Mobile bottom-nav tab index (GRID / ALERTS / AUTOMATION / AGRONOMIST).
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _subscribeLive();
  }

  Future<void> _refresh() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final list = await api.fetchLatestTelemetry();
      final alerts = await api.fetchAlerts();
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
        // MERGE rather than clear: a paired node should remain on the grid
        // even if its cache TTL expired between refreshes. merge() lives on
        // the model next to the field list, so new fields (the actuator ones
        // once vanished here) can't be silently dropped by a hand-rolled copy.
        for (final fresh in list) {
          final prior = _telemetry[fresh.nodeId];
          _telemetry[fresh.nodeId] = prior?.merge(fresh) ?? fresh;
        }
        _nodes = _telemetry.keys.toList()..sort();
        if (_selectedNode == null || !_nodes.contains(_selectedNode)) {
          _selectedNode = _nodes.isNotEmpty ? _nodes.first : null;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  void _openNodeDetail(String nodeId) {
    final snapshot = _telemetry[nodeId];
    if (snapshot == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NodeDetailScreen(nodeId: nodeId, initial: snapshot),
      ),
    );
  }

  /// Capture a leaf with the device camera and run disease analysis — the
  /// in-app replacement for the ESP32-CAM. The image is normalized to a small
  /// JPEG (same shape the firmware would send) before upload.
  static const String _phoneCamNode = 'cam-phone-a';

  Future<void> _captureLeaf() async {
    if (_capturing) return;
    final api = context.read<AppState>().api;
    if (api == null) return;

    XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        imageQuality: 90,
      );
    } catch (_) {
      // Some browsers/devices block direct camera; fall back to gallery/file.
      shot = await ImagePicker().pickImage(source: ImageSource.gallery);
    }
    if (shot == null) return;

    HapticFeedback.mediumImpact();
    setState(() => _capturing = true);
    _toast('Analyzing leaf...');
    try {
      final raw = await shot.readAsBytes();
      final jpeg = _normalizeJpeg(raw);
      // The edge auto-analyzes on upload, so no separate /analyze call needed.
      await api.uploadFrame(_phoneCamNode, jpeg);
      await _refresh();
      if (!mounted) return;
      _openNodeDetail(_phoneCamNode);
    } catch (e) {
      _toast('Capture failed: $e');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// Decode any captured image and re-encode as a downscaled JPEG so it is a
  /// valid image under the API's 2 MB limit regardless of source format/size.
  Uint8List _normalizeJpeg(Uint8List raw) {
    final decoded = img.decodeImage(raw);
    if (decoded == null) return raw; // let the server validate/reject
    final resized = decoded.width > 1024
        ? img.copyResize(decoded, width: 1024)
        : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  }

  void _toast(String msg) {
    if (!mounted) return;
    showAppToast(context, msg);
  }

  /// Open the SSE feed and apply each event as a delta to the matching card.
  /// If the connection drops, schedule a single retry — repeated reconnects are
  /// driven by the user pressing Refresh, to avoid hammering a downed backend.
  void _subscribeLive() {
    final api = context.read<AppState>().api;
    if (api == null) return;

    _liveSub?.cancel();
    _liveSub = api.streamTelemetry().listen(
      (event) {
        if (!mounted) return;
        final nodeId = event['node_id'] as String?;
        final data = event['data'] as Map<String, dynamic>?;
        if (nodeId == null || data == null) return;
        // Typed envelope: {"type": telemetry|alert|detection|actuator|online,
        // "payload": {...}} — dispatch on type, never sniff payload keys.
        final type = data['type'] as String? ?? '';
        final payload =
            (data['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
        if (type == 'alert') {
          setState(() {
            _liveConnected = true;
            _alerts.insert(0, payload);
            if (_alerts.length > 50) _alerts.removeRange(50, _alerts.length);
          });
          return;
        }
        setState(() {
          _liveConnected = true;
          final existing = _telemetry[nodeId] ??
              TelemetrySnapshot(nodeId: nodeId);
          _telemetry[nodeId] = existing.applyEvent(type, payload);
          if (!_nodes.contains(nodeId)) _nodes = [..._nodes, nodeId];
        });
      },
      onError: (_) {
        if (mounted) setState(() => _liveConnected = false);
      },
      onDone: () {
        if (mounted) setState(() => _liveConnected = false);
      },
      cancelOnError: true,
    );
  }

  void _openAutomation() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AutomationScreen()),
    );
  }

  void _logout() {
    context.read<AppState>().logout();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Stable order: alphabetical by node id so cards never re-shuffle when an
    // SSE delta arrives. Mutating the map's iteration order would cause cards
    // to jump positions on every update — visually disorienting.
    final cards = _telemetry.values.toList()
      ..sort((a, b) => a.nodeId.compareTo(b.nodeId));
    return Scaffold(
      body: NatureBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Below 700px is a phone: switch to a tabbed shell with bottom nav.
              return constraints.maxWidth < 700
                  ? _mobileBody(cards)
                  : _desktopBody(cards);
            },
          ),
        ),
      ),
    );
  }

  _ChatPanel _chat() => _ChatPanel(
        nodes: _nodes,
        selectedNode: _selectedNode,
        onNodeChanged: (n) => setState(() => _selectedNode = n),
      );

  Widget _desktopBody(List<TelemetrySnapshot> cards) {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            onRefresh: () {
              _refresh();
              _subscribeLive();
            },
            onCapture: _captureLeaf,
            capturing: _capturing,
            onAutomation: _openAutomation,
            onLogout: _logout,
            liveConnected: _liveConnected,
          ),
          _AlertsBar(alerts: _alerts),
          const SizedBox(height: AppSpace.lg),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final grid = _TelemetryGrid(
                  cards: cards,
                  loading: _loading,
                  error: _loadError,
                  onTap: _openNodeDetail,
                );
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: grid),
                      const SizedBox(width: AppSpace.lg),
                      SizedBox(width: 380, child: _chat()),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(flex: 3, child: grid),
                    const SizedBox(height: AppSpace.lg),
                    Expanded(flex: 2, child: _chat()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileBody(List<TelemetrySnapshot> cards) {
    // GRID tab: pull-to-refresh over the card grid.
    final grid = RefreshIndicator(
      color: AppColors.health,
      backgroundColor: AppColors.bgLift,
      onRefresh: () async {
        await _refresh();
        _subscribeLive();
      },
      child: _TelemetryGrid(
        cards: cards,
        loading: _loading,
        error: _loadError,
        onTap: _openNodeDetail,
      ),
    );
    final tabs = <Widget>[
      grid,
      _AlertsList(alerts: _alerts),
      const AutomationScreen(embedded: true),
      _chat(),
    ];
    final alertCount =
        _alerts.where((a) => a['state'] == 'raised').length;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            onRefresh: () {
              _refresh();
              _subscribeLive();
            },
            onCapture: _captureLeaf,
            capturing: _capturing,
            onAutomation: _openAutomation,
            onLogout: _logout,
            liveConnected: _liveConnected,
            showAutomation: false,
          ),
          const SizedBox(height: AppSpace.md),
          Expanded(child: IndexedStack(index: _tab, children: tabs)),
          _BottomNav(
            index: _tab,
            alertCount: alertCount,
            onChanged: (i) => setState(() => _tab = i),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    super.dispose();
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onRefresh;
  final VoidCallback onCapture;
  final bool capturing;
  final VoidCallback onAutomation;
  final VoidCallback onLogout;
  final bool liveConnected;
  final bool showAutomation;
  const _Header({
    required this.onRefresh,
    required this.onCapture,
    required this.capturing,
    required this.onAutomation,
    required this.onLogout,
    required this.liveConnected,
    this.showAutomation = true,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = liveConnected ? AppColors.health : AppColors.warning;
    final statusLabel = liveConnected ? 'SYSTEM LIVE' : 'STREAM OFFLINE';

    const title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel('Telemetry Hub // Edge Node Grid'),
        SizedBox(height: AppSpace.xs),
        Text('Crop Health Matrix',
            style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );

    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LiveIndicator(color: statusColor),
        const SizedBox(width: AppSpace.sm),
        Text(statusLabel,
            style: AppText.monoCaption.copyWith(color: statusColor)),
      ],
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconAction(
          icon: capturing ? Icons.hourglass_empty : Icons.photo_camera,
          tooltip: 'Capture leaf & diagnose',
          onTap: capturing ? null : onCapture,
        ),
        if (showAutomation) ...[
          const SizedBox(width: AppSpace.sm),
          _IconAction(
              icon: Icons.tune,
              tooltip: 'Irrigation automation',
              onTap: onAutomation),
        ],
        const SizedBox(width: AppSpace.sm),
        _IconAction(icon: Icons.refresh, tooltip: 'Refresh', onTap: onRefresh),
        const SizedBox(width: AppSpace.sm),
        _IconAction(
            icon: Icons.power_settings_new, tooltip: 'Disconnect', onTap: onLogout),
      ],
    );

    return Container(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      decoration: const Border(
        bottom: BorderSide(color: AppColors.glassBorder),
      ).toBoxDecoration(),
      // Phone-narrow screens can't fit title + status + 4 actions on one row,
      // so stack the title above a status/actions row below ~560px.
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: AppSpace.md),
                Row(children: [status, const Spacer(), actions]),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Expanded(child: title),
              status,
              const SizedBox(width: AppSpace.lg),
              actions,
            ],
          );
        },
      ),
    );
  }
}

/// Collapsible strip of recent alerts below the header. Shows the latest alert
/// inline with a count; tap to expand the full recent list. Hidden when empty.
class _AlertsBar extends StatefulWidget {
  final List<Map<String, dynamic>> alerts;
  const _AlertsBar({required this.alerts});

  @override
  State<_AlertsBar> createState() => _AlertsBarState();
}

class _AlertsBarState extends State<_AlertsBar> {
  bool _expanded = false;

  Color _severityColor(String? sev) {
    switch (sev) {
      case 'critical':
        return AppColors.alert;
      case 'warning':
        return AppColors.warning;
      default:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only "raised" alerts are actionable; "cleared"/"info" recoveries are
    // recorded but not surfaced as active warnings.
    final active =
        widget.alerts.where((a) => a['state'] == 'raised').toList();

    // Slide + fade the bar in when the first alert is raised, and out when the
    // last one clears — keyed on the latest alert so a new top alert re-fires.
    final Widget content = active.isEmpty
        ? const SizedBox(width: double.infinity, key: ValueKey('alerts-none'))
        : _bar(active, active.first);
    return AnimatedSwitcher(
      duration: AppMotion.base,
      switchInCurve: AppMotion.curve,
      switchOutCurve: AppMotion.curve,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SizeTransition(sizeFactor: anim, child: child),
      ),
      child: content,
    );
  }

  Widget _bar(List<Map<String, dynamic>> active, Map<String, dynamic> latest) {
    return Padding(
      key: ValueKey(
          'alerts-${active.length}-${latest['node_id']}-${latest['message']}'),
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.insetFill,
          border: Border.all(
            color: _severityColor(latest['severity'] as String?)
                .withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md, vertical: AppSpace.sm),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber,
                        size: 16,
                        color: _severityColor(latest['severity'] as String?)),
                    const SizedBox(width: AppSpace.sm),
                    Text('${active.length} ALERT${active.length == 1 ? '' : 'S'}',
                        style: AppText.monoCaption.copyWith(
                            color: _severityColor(
                                latest['severity'] as String?))),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Text(
                        '${(latest['node_id'] ?? '').toString().toUpperCase()} // ${latest['message'] ?? ''}',
                        style: AppText.monoCaption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ),
            if (_expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final a in active)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.md, vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              color: _severityColor(a['severity'] as String?),
                            ),
                            const SizedBox(width: AppSpace.sm),
                            Expanded(
                              child: Text(
                                '${(a['node_id'] ?? '').toString().toUpperCase()} // ${a['kind']} // ${a['message'] ?? ''}',
                                style: AppText.monoCaption,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  const _IconAction({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Icon(
              icon,
              size: 16,
              color: disabled ? AppColors.sageFaint : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _TelemetryGrid extends StatelessWidget {
  final List<TelemetrySnapshot> cards;
  final bool loading;
  final String? error;
  final ValueChanged<String> onTap;

  const _TelemetryGrid({
    required this.cards,
    required this.loading,
    required this.error,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (loading && cards.isEmpty) {
      return const _StatusNote('SCANNING NODE GRID...');
    }
    if (error != null && cards.isEmpty) {
      return _StatusNote('LINK ERROR // $error', color: AppColors.alert);
    }
    if (cards.isEmpty) {
      return const _StatusNote('NO PAIRED NODES — FLASH A DEVICE TO BEGIN');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // On a phone the fixed 340px card is wider than the viewport and
        // overflows; clamp it to the available width so it fills one column.
        final cardWidth =
            constraints.maxWidth < 340 ? constraints.maxWidth : 340.0;
        return SingleChildScrollView(
          // Always scrollable so a mobile RefreshIndicator can pull even when
          // the grid is short; harmless on desktop.
          physics: const AlwaysScrollableScrollPhysics(),
          child: Wrap(
            spacing: AppSpace.lg,
            runSpacing: AppSpace.lg,
            children: [
              for (var i = 0; i < cards.length; i++)
                SizedBox(
                  width: cardWidth,
              // Key by node id so Flutter recycles widgets correctly when the
              // sorted list shifts. Without the key, AnimatedSwitchers inside
              // cards re-fire on every list reorder instead of only on data
              // changes.
                  child: TelemetryCard(
                    key: ValueKey('card-${cards[i].nodeId}'),
                    snapshot: cards[i],
                    index: i + 1,
                    onTap: () => onTap(cards[i].nodeId),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusNote extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusNote(this.text, {this.color = AppColors.textSecondary});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: AppText.monoCaption.copyWith(color: color)),
    );
  }
}

/// Full-height alerts list for the mobile ALERTS tab — every alert newest
/// first, raised ones accented, recoveries muted.
class _AlertsList extends StatelessWidget {
  final List<Map<String, dynamic>> alerts;
  const _AlertsList({required this.alerts});

  Color _sev(String? s) {
    switch (s) {
      case 'critical':
        return AppColors.alert;
      case 'warning':
        return AppColors.warning;
      default:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) {
      return Center(child: Text('NO ALERTS', style: AppText.monoCaption));
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: alerts.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpace.sm),
      itemBuilder: (_, i) {
        final a = alerts[i];
        final raised = a['state'] == 'raised';
        final c = raised ? _sev(a['severity'] as String?) : AppColors.textSecondary;
        return Container(
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(
            color: AppColors.insetFill,
            border: Border(left: BorderSide(color: c, width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(raised ? Icons.warning_amber : Icons.check,
                      size: 14, color: c),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      '${(a['node_id'] ?? '').toString().toUpperCase()} // ${a['kind'] ?? ''}',
                      style: AppText.monoCaption.copyWith(color: c),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    (a['state'] ?? '').toString().toUpperCase(),
                    style: AppText.monoCaption.copyWith(color: c, fontSize: 9),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              Text('${a['message'] ?? ''}', style: AppText.monoValue),
            ],
          ),
        );
      },
    );
  }
}

/// Sharp, mono-labelled bottom navigation for the phone shell. No rounded
/// pills — a top rule and four evenly-spaced destinations.
class _BottomNav extends StatelessWidget {
  final int index;
  final int alertCount;
  final ValueChanged<int> onChanged;
  const _BottomNav({
    required this.index,
    required this.alertCount,
    required this.onChanged,
  });

  static const _items = <({IconData icon, String label})>[
    (icon: Icons.grid_view, label: 'GRID'),
    (icon: Icons.warning_amber, label: 'ALERTS'),
    (icon: Icons.tune, label: 'AUTO'),
    (icon: Icons.chat_bubble_outline, label: 'ADVISOR'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.glassBorder)),
      ),
      padding: const EdgeInsets.only(top: AppSpace.sm),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(child: _item(i)),
        ],
      ),
    );
  }

  Widget _item(int i) {
    final sel = i == index;
    final c = sel ? AppColors.health : AppColors.textSecondary;
    final showBadge = i == 1 && alertCount > 0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(_items[i].icon, size: 18, color: c),
                  if (showBadge)
                    Positioned(
                      right: -8,
                      top: -4,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                        color: AppColors.alert,
                        child: Text('$alertCount',
                            style: AppText.monoCaption.copyWith(
                                color: AppColors.bgBase, fontSize: 8)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(_items[i].label,
                  style: AppText.monoCaption
                      .copyWith(color: c, fontSize: 9, letterSpacing: 1)),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Role { user, assistant }

class _ChatMessage {
  final _Role role;
  String text;
  _ChatMessage({required this.role, required this.text});
}

/// Owns its transcript + streaming state, so per-token setState calls during
/// a streamed reply rebuild ONLY this panel — a 200-token answer used to force
/// 200 full card-grid rebuilds (with sort) via the parent screen's setState.
class _ChatPanel extends StatefulWidget {
  final List<String> nodes;
  final String? selectedNode;
  final ValueChanged<String?> onNodeChanged;

  const _ChatPanel({
    required this.nodes,
    required this.selectedNode,
    required this.onNodeChanged,
  });

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_ChatMessage> _history = [];
  bool _loading = false;

  Future<void> _send() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _loading) return;
    final targetNode = widget.selectedNode ?? 'node-01';

    setState(() {
      _history.add(_ChatMessage(role: _Role.user, text: query));
      _loading = true;
    });
    _controller.clear();
    _scrollToEnd();

    final api = context.read<AppState>().api;
    if (api == null) return;

    final buffer = StringBuffer();
    final msg = _ChatMessage(role: _Role.assistant, text: '');
    setState(() => _history.add(msg));

    try {
      await for (final chunk in api.streamAgronomistChat(targetNode, query)) {
        buffer.write(chunk);
        if (mounted) {
          setState(() => msg.text = buffer.toString());
          _scrollToEnd();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => msg.text = '${buffer.toString()}\n[LINK ERROR: $e]');
      }
    }

    if (mounted) setState(() => _loading = false);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('AI Agronomist // Advisory')),
              if (_loading) const LiveIndicator(color: AppColors.warning),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          _NodeSelector(
            nodes: widget.nodes,
            selected: widget.selectedNode,
            onChanged: widget.onNodeChanged,
          ),
          const TechnicalDivider(vertical: AppSpace.sm),
          Expanded(
            child: _history.isEmpty
                ? Center(
                    child: Text(
                      'AWAITING QUERY',
                      style: AppText.monoCaption,
                    ),
                  )
                : ListView.separated(
                    controller: _scroll,
                    itemCount: _history.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpace.sm),
                    itemBuilder: (_, i) => _ChatBubble(message: _history[i]),
                  ),
          ),
          const SizedBox(height: AppSpace.sm),
          _ChatInput(controller: _controller, onSend: _send),
        ],
      ),
    );
  }
}

class _NodeSelector extends StatelessWidget {
  final List<String> nodes;
  final String? selected;
  final ValueChanged<String?> onChanged;

  const _NodeSelector({
    required this.nodes,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('CONTEXT NODE', style: AppText.monoCaption),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
            decoration: BoxDecoration(
              color: AppColors.insetFill,
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                isDense: true,
                value: selected,
                dropdownColor: AppColors.bgLift,
                borderRadius: BorderRadius.zero,
                icon: const Icon(Icons.expand_more,
                    size: 16, color: AppColors.textSecondary),
                hint: Text('no nodes', style: AppText.monoCaption),
                style: AppText.monoValue,
                items: [
                  for (final n in nodes)
                    DropdownMenuItem(
                      value: n,
                      child: Text(n.toUpperCase(), style: AppText.monoValue),
                    ),
                ],
                onChanged: nodes.isEmpty ? null : onChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final _ChatMessage message;
  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == _Role.user;
    final accent = isUser ? AppColors.textSecondary : AppColors.health;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.insetFill,
        border: Border(left: BorderSide(color: accent, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isUser ? 'OPERATOR' : 'AGRONOMIST',
            style: AppText.monoCaption.copyWith(color: accent),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            message.text.isEmpty ? '...' : message.text,
            style: AppText.monoValue.copyWith(height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _ChatInput extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  const _ChatInput({required this.controller, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: AppText.monoValue,
            cursorColor: AppColors.health,
            onSubmitted: (_) => onSend(),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'query the agronomist',
              hintStyle: AppText.monoCaption,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md, vertical: 12),
              filled: true,
              fillColor: AppColors.insetFill,
              enabledBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: AppColors.glassBorder),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: AppColors.health),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        CommandButton(icon: Icons.arrow_upward, onTap: onSend),
      ],
    );
  }
}

/// Lets a [Border] be used as a [BoxDecoration] for a bottom rule.
extension on Border {
  BoxDecoration toBoxDecoration() => BoxDecoration(border: this);
}
