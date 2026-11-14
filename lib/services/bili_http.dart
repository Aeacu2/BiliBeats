import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Times out a request before headers and releases any request obtained after
/// the caller has given up waiting for a connection slot.
Future<HttpClientRequest> openHttpRequest(
    Future<HttpClientRequest> opening, Duration timeout) {
  var expired = false;
  return opening.then((request) {
    if (expired) {
      request.done.ignore();
      request.abort();
    }
    return request;
  }).timeout(timeout, onTimeout: () {
    expired = true;
    throw TimeoutException('HTTP connection timed out');
  });
}

Future<HttpClientResponse> closeHttpRequest(
        HttpClientRequest request, Duration timeout) =>
    request.close().timeout(timeout, onTimeout: () {
      request.abort();
      throw TimeoutException('HTTP response headers timed out');
    });

/// Reads a metadata response with an overall deadline and a cap on the
/// decoded bytes. Always cancels the response subscription on departure.
Future<String> readHttpBody(Stream<List<int>> response, Duration timeout,
    {int maxBytes = 4 << 20}) async {
  final reader = StreamIterator(response);
  final bytes = BytesBuilder(copy: false);
  final deadline = Stopwatch()..start();
  try {
    while (await reader.moveNext().timeout(timeout - deadline.elapsed)) {
      final chunk = reader.current;
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('HTTP response exceeded the size limit');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  } finally {
    await reader.cancel();
  }
}

Future<void> discardHttpBody(Stream<List<int>> response) =>
    response.listen((_) {}).cancel();
