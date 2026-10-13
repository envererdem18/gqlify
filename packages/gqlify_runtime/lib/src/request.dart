import 'operation.dart';

/// Optional per-request settings for [GqlifyClientBase.execute].
final class GqlifyRequestOptions {
  const GqlifyRequestOptions({this.headers = const {}, this.timeout});

  /// Extra headers for this request; they override transport defaults.
  final Map<String, String> headers;

  /// Overrides the transport's timeout for this request.
  final Duration? timeout;
}

/// A request handed to a [GqlifyTransport].
final class GqlifyRequest {
  const GqlifyRequest({
    required this.operationName,
    required this.operationType,
    required this.document,
    this.variables = const {},
    this.headers = const {},
    this.timeout,
  });

  factory GqlifyRequest.fromOperation(
    GqlifyOperation<Object?> operation, {
    GqlifyRequestOptions? options,
  }) =>
      GqlifyRequest(
        operationName: operation.operationName,
        operationType: operation.operationType,
        document: operation.document,
        variables: operation.variables,
        headers: options?.headers ?? const {},
        timeout: options?.timeout,
      );

  final String operationName;
  final GqlifyOperationType operationType;
  final String document;
  final Map<String, Object?> variables;
  final Map<String, String> headers;
  final Duration? timeout;

  /// The standard GraphQL-over-HTTP request body.
  Map<String, Object?> toJson() => {
        'query': document,
        'operationName': operationName,
        if (variables.isNotEmpty) 'variables': variables,
      };
}
