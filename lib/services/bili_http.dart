import 'dart:io';

/// The desktop-Chrome user-agent Bilibili's APIs expect. Their risk control
/// rejects requests that look like a bare Dart http client, so every service
/// that talks to them sends this exact string.
const kBiliUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

/// [url] over TLS. Bilibili answers with `http:` and scheme-relative
/// (`//i0.hdslb.com/…`) addresses; only the scheme is touched, never an
/// `http:` further on (a link carried in the query).
String secureUrl(String url) {
  if (url.startsWith('http:')) return 'https:${url.substring(5)}';
  if (url.startsWith('//')) return 'https:$url';
  return url;
}

/// Shared [HttpClient] factory. Every service previously declared its own
/// static client with slightly different timeouts; one factory keeps the
/// pooling knobs consistent and fixes the ones that forgot a connection
/// timeout (an unset timeout lets a dead host hang a request forever).
HttpClient biliHttpClient({
  Duration connectionTimeout = const Duration(seconds: 10),
  Duration idleTimeout = const Duration(seconds: 30),
  int maxConnectionsPerHost = 4,
}) =>
    HttpClient()
      ..connectionTimeout = connectionTimeout
      ..idleTimeout = idleTimeout
      ..maxConnectionsPerHost = maxConnectionsPerHost;
