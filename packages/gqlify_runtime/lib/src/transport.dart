import 'request.dart';

/// Moves a [GqlifyRequest] to a GraphQL server and returns the decoded JSON
/// response body (the object containing `data`, `errors`, `extensions`).
///
/// Implementations should throw [GqlifyTransportException] for failures that
/// did not produce a GraphQL response (network errors, timeouts, non-GraphQL
/// HTTP error bodies). GraphQL `errors` are *not* transport failures; return
/// the body and let the client interpret it.
abstract interface class GqlifyTransport {
  Future<Map<String, Object?>> send(GqlifyRequest request);

  /// Releases resources held by the transport.
  Future<void> close();
}
