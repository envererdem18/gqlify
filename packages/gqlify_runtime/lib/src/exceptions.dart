import 'response.dart';

/// Base type for all errors thrown by gqlify runtime and generated code.
sealed class GqlifyException implements Exception {
  const GqlifyException();

  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The server answered with GraphQL `errors`.
///
/// Thrown by the generated short methods (and [GqlifyResponse.dataOrThrow])
/// whenever `errors` is non-empty, even if partial [data] was returned.
final class GraphQLResponseException extends GqlifyException {
  const GraphQLResponseException(this.errors, {this.data, this.extensions});

  final List<GraphQLError> errors;

  /// Decoded partial data, if the server returned any and it could be decoded.
  final Object? data;

  final Map<String, Object?>? extensions;

  @override
  String get message => errors.isEmpty
      ? 'GraphQL response contained no data'
      : errors.map((e) => e.message).join('; ');
}

/// The request did not produce a GraphQL response (network failure, timeout,
/// HTTP error without a GraphQL body, ...).
final class GqlifyTransportException extends GqlifyException {
  const GqlifyTransportException(
    this.message, {
    this.statusCode,
    this.body,
    this.cause,
  });

  @override
  final String message;
  final int? statusCode;
  final String? body;
  final Object? cause;
}

/// The response could not be decoded into the generated types: malformed
/// JSON, a value of the wrong type, or a missing non-null field.
final class GqlifyDecodingException extends GqlifyException {
  const GqlifyDecodingException(this.message, {this.cause, this.stackTrace});

  @override
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;
}
