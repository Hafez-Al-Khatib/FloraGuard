import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';

class AppState extends ChangeNotifier {
  static const _kBaseUrl = 'pms_base_url';
  static const _kToken = 'pms_token';

  String? _token;
  String _baseUrl = 'https://plant-hub.local';
  ApiService? _api;

  // Last-used credentials, restored from disk for prefill on launch. On mobile
  // there is no kiosk deep-link, so persisting these saves retyping the hub IP
  // and token every time the app opens.
  String? savedBaseUrl;
  String? savedToken;

  String? get token => _token;
  String get baseUrl => _baseUrl;
  ApiService? get api => _api;
  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  /// Load saved credentials at startup (call before runApp).
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    savedBaseUrl = prefs.getString(_kBaseUrl);
    savedToken = prefs.getString(_kToken);
    notifyListeners();
  }

  Future<void> login({required String baseUrl, required String token}) async {
    // Set in-memory state first (synchronously, before any await) so callers can
    // use `api` immediately after invoking login.
    _baseUrl = baseUrl;
    _token = token;
    _api = ApiService(baseUrl: baseUrl, token: token);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, baseUrl);
    await prefs.setString(_kToken, token);
    savedBaseUrl = baseUrl;
    savedToken = token;
  }

  Future<void> logout() async {
    _token = null;
    _api = null;
    savedToken = null;
    notifyListeners();
    // Drop the token but keep the hub URL — operators reconnect to the same hub.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
  }
}
