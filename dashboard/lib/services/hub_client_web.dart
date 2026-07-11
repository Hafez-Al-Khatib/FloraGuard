import 'package:http/http.dart' as http;

/// Web implementation. The browser performs TLS validation itself (and the
/// kiosk is launched trusting the hub), so there is nothing to override —
/// `dart:io`/`HttpClient` are not available on web anyway.
http.Client createHubClient(String hubHost) => http.Client();
