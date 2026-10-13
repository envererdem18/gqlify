import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'exceptions.dart';
import 'request.dart';
import 'transport.dart';

/// Computes headers per request, e.g. a fresh authentication token.
typedef HeadersBuilder = FutureOr<Map<String, String>> Function(
    GqlifyRequest request);

/// A pure-Dart GraphQL-over-HTTP transport (POST, JSON) built on
/// `package:http`. Works on the Dart VM, Flutter and the web.
///
/// Header precedence (lowest to highest): defaults, [headers],
/// [headersBuilder], per-request `GqlifyRequestOptions.headers`.
final class HttpTransport implements GqlifyTransport {
  HttpTransport(
    this.endpoint, {
    http.Client? client,
    this.headers = const {},
    this.headersBuilder,
    this.timeout,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Uri endpoint;
  final Map<String, String> headers;
  final HeadersBuilder? headersBuilder;

  /// Default timeout. On expiry a [GqlifyTransportException] is thrown; the
  /// underlying HTTP request is not guaranteed to be aborted.
  final Duration? timeout;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<Map<String, Object?>> send(GqlifyRequest request) async {
    final requestHeaders = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/graphql-response+json, application/json',
      ...headers,
      if (headersBuilder != null) ...await headersBuilder!(request),
      ...request.headers,
    };

    var future = _client.post(
      endpoint,
      headers: requestHeaders,
      body: jsonEncode(request.toJson()),
    );
    final effectiveTimeout = request.timeout ?? timeout;
    if (effectiveTimeout != null) {
      future = future.timeout(
        effectiveTimeout,
        onTimeout: () => throw GqlifyTransportException(
          'Request ${request.operationName} timed out after $effectiveTimeout',
        ),
      );
    }

    final http.Response response;
    try {
      response = await future;
    } on GqlifyException {
      rethrow;
    } on Object catch (e) {
      throw GqlifyTransportException(
        'HTTP request ${request.operationName} failed: $e',
        cause: e,
      );
    }

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      if (!ok) throw _httpError(response, body);
      throw GqlifyDecodingException(
        'Response body is not valid JSON: ${e.message}',
        cause: e,
      );
    }

    // A non-2xx status still carries a GraphQL response if the body has the
    // GraphQL shape (GraphQL over HTTP, application/graphql-response+json).
    final isGraphQLBody = decoded is Map<String, Object?> &&
        (decoded.containsKey('data') || decoded.containsKey('errors'));
    if (isGraphQLBody) return decoded;
    if (!ok) throw _httpError(response, body);
    throw GqlifyDecodingException(
      'Response body is not a GraphQL response object',
    );
  }

  GqlifyTransportException _httpError(http.Response response, String body) =>
      GqlifyTransportException(
        'HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}'.trim(),
        statusCode: response.statusCode,
        body: body,
      );

  @override
  Future<void> close() async {
    if (_ownsClient) _client.close();
  }
}
