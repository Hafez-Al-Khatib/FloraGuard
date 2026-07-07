import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

import '../models/telemetry.dart';

/// Outcome of validating the hub URL + token at login.
enum AuthResult { ok, badToken, noHub }

/// Thin wrapper around the FastAPI backend.
/// Set [baseUrl] to the Nginx HTTPS endpoint (e.g., https://plant-hub.local).
class ApiService {
  final String baseUrl;
  final String token;

  ApiService({required this.baseUrl, required this.token});

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  Future<bool> healthCheck() async {
    try {
      final response = await http
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
      final response = await http
          .get(Uri.parse('$baseUrl/api/v1/nodes'), headers: _headers)
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

  /// List node ids that currently have cached telemetry.
  Future<List<String>> fetchNodes() async {
    final response = await http
        .get(Uri.parse('$baseUrl/api/v1/nodes'), headers: _headers)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Node list failed: ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['nodes'] as List<dynamic>).cast<String>();
  }

  /// Latest cached telemetry for a single node.
  Future<TelemetrySnapshot> fetchTelemetry(String nodeId) async {
    final response = await http
        .get(
          Uri.parse('$baseUrl/api/v1/node/$nodeId/telemetry'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Telemetry failed: ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TelemetrySnapshot.fromJson(body);
  }

  /// Fetch every paired node's latest telemetry for the dashboard grid.
  ///
  /// Nodes registered with the hub but missing telemetry (just-flashed devices,
  /// nodes asleep between cycles) come back as placeholder snapshots so the
  /// card stays pinned to the grid. Only an explicit operator action should
  /// remove a paired card.
  Future<List<TelemetrySnapshot>> fetchLatestTelemetry() async {
    final nodes = await fetchNodes();
    if (nodes.isEmpty) return [];
    final results = await Future.wait(
      nodes.map((n) => fetchTelemetry(n).catchError(
        (_) => TelemetrySnapshot.placeholder(n),
      )),
      eagerError: false,
    );
    return results;
  }

  /// Latest cached disease diagnosis for a camera node, including treatments.
  /// Returns the decoded body, or null on any error (node has no detection yet).
  Future<Map<String, dynamic>?> fetchDiagnostics(String nodeId) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/api/v1/node/$nodeId/diagnostics'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Fetch the latest cached camera frame as raw JPEG bytes (auth header is
  /// required, so this goes through http rather than Image.network). Returns
  /// null when no frame is cached.
  Future<Uint8List?> fetchCameraFrame(String nodeId) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/api/v1/node/$nodeId/frame'),
            headers: {'Authorization': 'Bearer $token'},
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
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/v1/node/$nodeId/upload-frame'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'image/jpeg',
          },
          body: jpegBytes,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Upload failed: ${response.statusCode} ${response.body}');
    }
    return true;
  }

  Future<DiagnosticSnapshot> analyzeCamera(String nodeId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/v1/node/$nodeId/analyze'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception('Analyze failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return DiagnosticSnapshot.fromJson(
      body['anomalies'] as Map<String, dynamic>,
    );
  }

  /// Downsampled history for one field of a node from InfluxDB.
  /// `field` in {moisture, temperature, ec, battery_pct}; `range` in {1h,24h,7d}.
  Future<List<({DateTime t, double v})>> fetchHistory(
    String nodeId,
    String field,
    String range,
  ) async {
    final response = await http
        .get(
          Uri.parse(
              '$baseUrl/api/v1/node/$nodeId/history?field=$field&range=$range'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('History failed: ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
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
  Future<Map<String, dynamic>> sendZoneCommand(String zone, String action) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/v1/zone/$zone/command'),
          headers: _headers,
          body: jsonEncode({'action': action}),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Command failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> fetchAutomationConfig() async {
    final response = await http
        .get(Uri.parse('$baseUrl/api/v1/automation/config'), headers: _headers)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Config fetch failed: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> updateAutomationConfig(Map<String, dynamic> updates) async {
    final response = await http
        .put(
          Uri.parse('$baseUrl/api/v1/automation/config'),
          headers: _headers,
          body: jsonEncode(updates),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Config update failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<List<Map<String, dynamic>>> fetchAutomationLog({int count = 50}) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/api/v1/automation/log?count=$count'),
              headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];
      final body = jsonDecode(response.body) as Map<String, dynamic>;
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
      final response = await http
          .get(Uri.parse('$baseUrl/api/v1/alerts?count=$count'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return (body['alerts'] as List<dynamic>)
          .map((a) => (a as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Subscribe to the SSE live-telemetry feed.
  ///
  /// Emits one decoded JSON event per published reading, of the shape:
  /// `{"node_id": "...", "data": {"moisture": 58.4, ...}}`.
  /// The caller is responsible for cancelling the subscription on dispose —
  /// `StreamSubscription.cancel()` closes the underlying HTTP connection.
  Stream<Map<String, dynamic>> streamTelemetry() async* {
    final request = http.Request(
      'GET',
      Uri.parse('$baseUrl/api/v1/stream'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'text/event-stream';

    final response = await http.Client().send(request);
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
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'text/event-stream';

    final response = await http.Client().send(request);
    if (response.statusCode != 200) {
      throw Exception('Chat failed: ${response.statusCode}');
    }

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      yield chunk;
    }
  }
}
