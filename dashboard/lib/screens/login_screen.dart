import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'dashboard_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _baseUrlController =
      TextEditingController(text: 'https://plant-hub.local');
  final _tokenController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Prefill last-used credentials (mobile / returning users — no retyping).
    final appState = context.read<AppState>();
    if (appState.savedBaseUrl?.isNotEmpty ?? false) {
      _baseUrlController.text = appState.savedBaseUrl!;
    }
    if (appState.savedToken?.isNotEmpty ?? false) {
      _tokenController.text = appState.savedToken!;
    }
    // Kiosk / deep-link support (web): a wall-mounted display can be pointed at
    // `?hub=<url>&token=<token>` to prefill and auto-connect. Overrides saved
    // values. On non-web platforms there are simply no query params.
    final params = Uri.base.queryParameters;
    final hub = params['hub'];
    final token = params['token'];
    if (hub != null && hub.isNotEmpty) _baseUrlController.text = hub;
    if (token != null && token.isNotEmpty) _tokenController.text = token;
    if (hub != null && hub.isNotEmpty && token != null && token.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _login());
    }
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final appState = context.read<AppState>();
    await appState.login(
      baseUrl: _baseUrlController.text.trim(),
      token: _tokenController.text.trim(),
    );

    // Validate BOTH connectivity and the token. /health alone is unauthenticated,
    // so a wrong token would otherwise slip through and fail later on /nodes.
    final result = await appState.api!.verifyConnection();
    if (!mounted) return;
    setState(() => _loading = false);

    switch (result) {
      case AuthResult.ok:
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DashboardScreen()),
        );
      case AuthResult.badToken:
        setState(() => _error = 'ACCESS DENIED // INVALID TOKEN');
        appState.logout();
      case AuthResult.noHub:
        setState(() => _error = 'NO RESPONSE FROM HUB // VERIFY URL');
        appState.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: NatureBackground(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: GlassCard(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionLabel('Autonomous Plant Grid'),
                    const SizedBox(height: AppSpace.sm),
                    const Text('Crop Health Matrix', style: AppText.title),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      'Edge agronomist console // offline-secure',
                      style: AppText.monoCaption,
                    ),
                    const TechnicalDivider(vertical: AppSpace.lg),
                    _FieldLabel('Hub Endpoint'),
                    const SizedBox(height: AppSpace.sm),
                    _GlassField(
                      controller: _baseUrlController,
                      hint: 'https://plant-hub.local',
                    ),
                    const SizedBox(height: AppSpace.md),
                    _FieldLabel('Access Token'),
                    const SizedBox(height: AppSpace.sm),
                    _GlassField(
                      controller: _tokenController,
                      hint: 'bearer token',
                      obscure: true,
                      onSubmitted: (_) => _loading ? null : _login(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpace.md),
                      Text(
                        _error!,
                        style: AppText.monoCaption
                            .copyWith(color: AppColors.alert),
                      ),
                    ],
                    const SizedBox(height: AppSpace.lg),
                    _ConnectButton(loading: _loading, onTap: _login),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: AppText.microLabel);
}

class _GlassField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final ValueChanged<String>? onSubmitted;

  const _GlassField({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      onSubmitted: onSubmitted,
      style: AppText.monoValue,
      cursorColor: AppColors.health,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: AppText.monoCaption,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md, vertical: 14),
        filled: true,
        fillColor: const Color.fromRGBO(10, 18, 11, 0.6),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: AppColors.glassBorder),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: AppColors.health),
        ),
      ),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;
  const _ConnectButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.health.withValues(alpha: 0.12),
              border: Border.all(
                  color: AppColors.health.withValues(alpha: 0.45), width: 1),
            ),
            child: loading
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.health,
                    ),
                  )
                : Text(
                    'ESTABLISH LINK',
                    style: AppText.monoCaption.copyWith(
                      color: AppColors.health,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
