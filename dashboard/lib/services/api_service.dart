import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

import '../models/telemetry.dart';
// Platform-conditional: on mobile/desktop this trusts the hub's self-signed
// cert (host-scoped); on web it returns a plain browser client.
import 'hub_client_io.dart' if (dart.library.html) 'hub_client_web.dart';

/// Outcome of validating the hub URL + token at login.
enum AuthResult { ok, badToken, noHub }

/// Thin wrapper around the FastAPI backend.
/// Set [baseUrl] to the Nginx HTTPS endpoint (e.g., https://plant-hub.local).
class ApiService {
  final String baseUrl;
  final String token;

  /// One client for the whole service so the hub-trust override (mobile/
  /// desktop) applies to every request, streams included. Scoped to the host
  /// the operator entered at login.
  late final http.Client _client = createHubClient(Uri.parse(baseUrl).host);

  ApiService({required this.baseUrl, required this.token});

  /// One place that builds auth headers — every request path uses it, so a
  /// token-scheme change cannot miss a hand-rolled header site.
  Map<String, String> _authHeaders({String? contentType}) => {
        'Authorization': 'Bearer $token',
        if (contentType != null) 'Content-Type': contentType,
      };

  /// Shared GET boilerplate: URL build, auth, timeout, status check, decode.
  Future<Map<String, dynamic>> _getJson(
    String path, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final response = await _client
        .get(Uri.parse('$baseUrl/api/v1$path'), headers: _authHeaders())
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw Exception('GET $path failed: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Shared POST/PUT boilerplate for JSON bodies.
  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1$path');
    final headers = _authHeaders(contentType: 'application/json');
    final encoded = body != null ? jsonEncode(body) : null;
    final response = await (method == 'PUT'
            ? _client.put(uri, headers: headers, body: encoded)
            : _client.post(uri, headers: headers, body: encoded))
        .timeout(timeout);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
          '$method $path failed: ${response.statusCode} ${response.body}');
    }
    return response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<bool> healthCheck() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/api/v1/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Result of validating connectivity + token at login time.
  ///   ok        -> reachable and token accepted
  ///   badToken  -> reachable but the token was rejected (401/403)
  ///   noHub     -> could not reach the hub at all
  Future<AuthResult> verifyConnection() async {
    // /health is unauthenticated — proves the hub is reachable.
    final reachable = await healthCheck();
    if (!reachable) return AuthResult.noHub;
    // /nodes IS authenticated — proves the token is valid. Without this check a
    // wrong token would still "log in" (health passes) and then every data call
    // would 403 on the dashboard.
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/api/v1/nodes'), headers: _authHeaders())
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) return AuthResult.ok;
      if (response.statusCode == 401 || response.statusCode == 403) {
        return AuthResult.badToken;
      }
      return AuthResult.noHub;
    } catch (_) {
      return AuthResult.noHub;
    }
  }

  /// List node ids known to the hub (paired + telemetry-bearing).
  Future<List<String>> fetchNodes() async {
    final body = await _getJson('/nodes');
    return (body['nodes'] as List<dynamic>).cast<String>();
  }

  /// Latest cached telemetry for a single node.
  Future<TelemetrySnapshot> fetchTelemetry(String nodeId) async {
    return TelemetrySnapshot.fromJson(await _getJson('/node/$nodeId/telemetry'));
  }

  /// Every paired node's latest telemetry in ONE request (bulk endpoint) —
  /// the previous implementation was one HTTP call per node.
  Future<List<TelemetrySnapshot>> fetchLatestTelemetry() async {
    final body = await _getJson('/nodes/telemetry');
    return (body['nodes'] as List<dynamic>)
        .map((n) => TelemetrySnapshot.fromJson(n as Map<String, dynamic>))
        .toList();
  }

  /// Latest cached disease diagnosis for a camera node, including treatments.
  /// Returns the decoded body, or null on any error (node has no detection yet).
  Future<Map<String, dynamic>?> fetchDiagnostics(String nodeId) async {
    try {
      return await _getJson('/node/$nodeId/diagnostics');
    } catch (_) {
      return null;
    }
  }

  /// Fetch the latest cached camera frame as raw JPEG bytes (auth header is
  /// required, so this goes through http rather than Image.network). Returns
  /// null when no frame is cached.
  Future<Uint8List?> fetchCameraFrame(String nodeId) async {
    try {
      final response = await _client
          .get(
            Uri.parse('$baseUrl/api/v1/node/$nodeId/frame'),
            headers: _authHeaders(),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Upload a JPEG frame for a node (raw binary body, image/jpeg), as the
  /// in-app camera capture does. Returns true on HTTP 200.
  Future<bool> uploadFrame(String nodeId, Uint8List jpegBytes) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/node/$nodeId/upload-frame'),
          headers: _authHeaders(contentType: 'image/jpeg'),
          body: jpegBytes,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Upload failed: ${response.statusCode} ${response.body}');
    }
    return true;
  }

  /// Downsampled history for one field of a node from InfluxDB.
  /// `field` in {moisture, temperature, ec, battery_pct}; `range` in {1h,24h,7d}.
  Future<List<({DateTime t, double v})>> fetchHistory(
    String nodeId,
    String field,
    String range,
  ) async {
    final body = await _getJson(
      '/node/$nodeId/history?field=$field&range=$range',
      timeout: const Duration(seconds: 12),
    );
    final pts = (body['points'] as List<dynamic>);
    return pts.map((p) {
      final m = p as Map<String, dynamic>;
      return (
        t: DateTime.tryParse(m['t'] as String? ?? '') ?? DateTime.now(),
        v: (m['v'] as num).toDouble(),
      );
    }).toList();
  }

  /// Manual actuator override (admin token). action = "on" | "off".
  Future<Map<String, dynamic>> sendZoneCommand(String zone, String action) {
    return _sendJson('POST', '/zone/$zone/command', body: {'action': action});
  }

  Future<Map<String, dynamic>> fetchAutomationConfig() {
    return _getJson('/automation/config');
  }

  Future<void> updateAutomationConfig(Map<String, dynamic> updates) async {
    await _sendJson('PUT', '/automation/config', body: updates);
  }

  Future<List<Map<String, dynamic>>> fetchAutomationLog({int count = 50}) async {
    try {
      final body = await _getJson('/automation/log?count=$count');
      return (body['log'] as List<dynamic>)
          .map((a) => (a as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Most recent alerts (offline / dry / battery / disease), newest first.
  Future<List<Map<String, dynamic>>> fetchAlerts({int count = 30}) async {
    try {
      final body = await _getJson('/alerts?count=$count');
      return (body['alerts'] as List<dynamic>)
          .map((a) => (a as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Subscribe to the SSE live event feed.
  ///
  /// Emits one decoded JSON envelope per event, of the shape:
  /// `{"node_id": "...", "data": {"type": "telemetry", "payload": {...}}}`.
  /// The caller is responsible for cancelling the subscription on dispose —
  /// `StreamSubscription.cancel()` closes the underlying HTTP connection.
  Stream<Map<String, dynamic>> streamTelemetry() async* {
    final request = http.Request(
      'GET',
      Uri.parse('$baseUrl/api/v1/stream'),
    );
    request.headers.addAll(_authHeaders());
    request.headers['Accept'] = 'text/event-stream';

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw Exception('Telemetry stream failed: ${response.statusCode}');
    }

    // SSE framing: events are separated by blank lines; payload lines start
    // with "data: ". Lines starting with ":" are heartbeat comments.
    final lineStream = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    final buffer = StringBuffer();
    await for (final line in lineStream) {
      if (line.isEmpty) {
        // End of an event — flush the buffer
        final raw = buffer.toString();
        buffer.clear();
        if (raw.isEmpty) continue;
        try {
          yield jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          // Malformed event — skip rather than crash the stream
        }
      } else if (line.startsWith('data: ')) {
        buffer.write(line.substring(6));
      }
      // Lines starting with ":" (comments / heartbeats) are intentionally ignored
    }
  }

  Stream<String> streamAgronomistChat(String nodeId, String query) async* {
    final request = http.Request(
      'GET',
      Uri.parse(
        '$baseUrl/api/v1/agronomist/chat?node_id=$nodeId&user_query=${Uri.encodeComponent(query)}',
      ),
    );
    request.headers.addAll(_authHeaders());
    request.headers['Accept'] = 'text/event-stream';

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw Exception('Chat failed: ${response.statusCode}');
    }

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      yield chunk;
    }
  }
}
