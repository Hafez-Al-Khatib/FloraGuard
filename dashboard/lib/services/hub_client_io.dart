import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Mobile/desktop implementation. Returns an HTTP client that trusts a
/// self-signed certificate **only** for [hubHost] — the user's own edge
/// appliance, which they authenticate to with a bearer token. Every other host
/// keeps normal certificate validation.
///
/// This is deliberate, host-scoped trust for a self-hosted appliance: the edge
/// server ships a self-signed cert (no public CA), so strict validation would
/// otherwise reject it on both untrusted-CA and (currently) missing-SAN grounds.
/// The callback fires only when the platform's own validation has already
/// failed, and we accept it solely for the configured hub.
http.Client createHubClient(String hubHost) {
  final inner = HttpClient()
    ..badCertificateCallback = (cert, host, port) => host == hubHost;
  return IOClient(inner);
}
