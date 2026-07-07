import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';

/// Automation control room: mode (advisory/auto), emergency stop, setpoints +
/// safety interlocks, and the audit log of every automation decision. All
/// writes go through the admin-gated /automation/config endpoint.
class AutomationScreen extends StatefulWidget {
  const AutomationScreen({super.key});

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  Map<String, dynamic> _config = {};
  List<Map<String, dynamic>> _log = [];
  bool _loading = true;
  bool _saving = false;

  final _setpoint = TextEditingController();
  final _target = TextEditingController();
  final _maxRun = TextEditingController();
  final _cooldown = TextEditingController();
  final _dailyCap = TextEditingController();

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
      final cfg = await api.fetchAutomationConfig();
      final log = await api.fetchAutomationLog();
      if (!mounted) return;
      setState(() {
        _config = cfg;
        _log = log;
        _setpoint.text = '${cfg['moisture_setpoint'] ?? ''}';
        _target.text = '${cfg['moisture_target'] ?? ''}';
        _maxRun.text = '${cfg['max_run_seconds'] ?? ''}';
        _cooldown.text = '${cfg['cooldown_seconds'] ?? ''}';
        _dailyCap.text = '${cfg['daily_cap_seconds'] ?? ''}';
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _patch(Map<String, dynamic> updates) async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() => _saving = true);
    try {
      await api.updateAutomationConfig(updates);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e', style: AppText.monoValue)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _saveSetpoints() {
    final updates = <String, dynamic>{};
    void addNum(String key, TextEditingController c) {
      final v = num.tryParse(c.text.trim());
      if (v != null) updates[key] = v;
    }

    addNum('moisture_setpoint', _setpoint);
    addNum('moisture_target', _target);
    addNum('max_run_seconds', _maxRun);
    addNum('cooldown_seconds', _cooldown);
    addNum('daily_cap_seconds', _dailyCap);
    if (updates.isNotEmpty) _patch(updates);
  }

  @override
  void dispose() {
    for (final c in [_setpoint, _target, _maxRun, _cooldown, _dailyCap]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = _config['mode'] as String? ?? 'advisory';
    final estop = _config['emergency_stop'] == true;
    return Scaffold(
      body: NatureBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context),
                const SizedBox(height: AppSpace.lg),
                Expanded(
                  child: _loading
                      ? Center(
                          child: Text('LOADING...', style: AppText.monoCaption))
                      : SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _emergencyCard(estop),
                              const SizedBox(height: AppSpace.lg),
                              _modeCard(mode),
                              const SizedBox(height: AppSpace.lg),
                              _setpointsCard(),
                              const SizedBox(height: AppSpace.lg),
                              _auditCard(),
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

  Widget _header(BuildContext context) {
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
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('Automation // Control Room'),
                const SizedBox(height: AppSpace.xs),
                const Text('Irrigation Automation', style: AppText.title),
              ],
            ),
          ),
          if (_saving) const LiveIndicator(color: AppColors.warning),
        ],
      ),
    );
  }

  Widget _emergencyCard(bool estop) {
    return GlassCard(
      child: Row(
        children: [
          Icon(Icons.emergency, color: estop ? AppColors.alert : AppColors.textSecondary),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('EMERGENCY STOP',
                    style: AppText.monoValue.copyWith(
                        color: estop ? AppColors.alert : AppColors.textPrimary)),
                Text(
                  estop
                      ? 'All actuation blocked.'
                      : 'Automation + manual actuation enabled.',
                  style: AppText.monoCaption,
                ),
              ],
            ),
          ),
          Switch(
            value: estop,
            activeThumbColor: AppColors.alert,
            onChanged: (v) => _patch({'emergency_stop': v ? 1 : 0}),
          ),
        ],
      ),
    );
  }

  Widget _modeCard(String mode) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Control Mode'),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              _modeButton('advisory', mode, 'ADVISORY',
                  'Log suggestions only — a human acts.'),
              const SizedBox(width: AppSpace.md),
              _modeButton('auto', mode, 'AUTO',
                  'Actuate automatically within safety interlocks.'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeButton(String value, String current, String label, String desc) {
    final selected = value == current;
    final c = value == 'auto' ? AppColors.health : AppColors.textSecondary;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: selected ? null : () => _patch({'mode': value}),
          child: Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: selected ? c.withValues(alpha: 0.12) : Colors.transparent,
              border: Border.all(
                  color: selected ? c : AppColors.glassBorder, width: selected ? 1.5 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: AppText.monoValue.copyWith(
                        color: selected ? c : AppColors.textPrimary,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpace.xs),
                Text(desc, style: AppText.monoCaption),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _setpointsCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Setpoints & Safety Interlocks'),
          const SizedBox(height: AppSpace.md),
          _field('Moisture setpoint (irrigate below, %)', _setpoint),
          _field('Moisture target (stop at, %)', _target),
          _field('Max single run (seconds)', _maxRun),
          _field('Cooldown between runs (seconds)', _cooldown),
          _field('Daily runtime cap (seconds)', _dailyCap),
          const SizedBox(height: AppSpace.md),
          CommandButton(label: 'SAVE SETPOINTS', onTap: _saving ? null : _saveSetpoints),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.monoCaption)),
          SizedBox(
            width: 90,
            child: TextField(
              controller: c,
              keyboardType: TextInputType.number,
              style: AppText.monoValue,
              cursorColor: AppColors.health,
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
        ],
      ),
    );
  }

  Widget _auditCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('Audit Log // Decisions')),
              CommandButton(label: 'REFRESH', onTap: _load),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (_log.isEmpty)
            Text('NO DECISIONS YET', style: AppText.monoCaption)
          else
            for (final e in _log.take(40))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${e['timestamp'] ?? ''}  ${(e['node_id'] ?? '').toString().toUpperCase()}  ${e['decision'] ?? ''}',
                  style: AppText.monoCaption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
        ],
      ),
    );
  }
}

