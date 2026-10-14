import 'exceptions.dart';
import 'internal/codec.dart' show GqlifyDecodeError;
import 'operation.dart';
import 'request.dart';
import 'response.dart';
import 'transport.dart';

/// Base class of generated clients.
///
/// gqlify generates a subclass (named `GqlifyClient` by default) and adds one
/// method per operation as an extension, so normal calls look like
/// `client.getProduct(sku: 'ABC')`. Use [execute] for the full response
/// (partial data, errors, extensions) or per-request options.
abstract class GqlifyClientBase {
  GqlifyClientBase({required this.transport});

  final GqlifyTransport transport;

  /// Sends [operation] and decodes the response.
  ///
  /// GraphQL errors are returned in [GqlifyResponse.errors], not thrown.
  /// Throws [GqlifyTransportException] if no GraphQL response was received and
  /// [GqlifyDecodingException] if the response cannot be decoded.
  Future<GqlifyResponse<TData>> execute<TData>(
    GqlifyOperation<TData> operation, {
    GqlifyRequestOptions? options,
  }) async {
    final body = await transport.send(
      GqlifyRequest.fromOperation(operation, options: options),
    );
    return decodeResponse(operation, body);
  }

  /// Closes the underlying transport.
  Future<void> close() => transport.close();
}

/// Interprets a GraphQL response [body] for [operation].
GqlifyResponse<TData> decodeResponse<TData>(
  GqlifyOperation<TData> operation,
  Map<String, Object?> body,
) {
  final rawErrors = body['errors'];
  if (rawErrors != null && rawErrors is! List) {
    throw GqlifyDecodingException('"errors" must be a list, got $rawErrors');
  }
  final errors = [
    for (final e in (rawErrors as List?) ?? const []) GraphQLError.fromJson(e),
  ];
  final rawExtensions = body['extensions'];
  final extensions =
      rawExtensions is Map<String, Object?> ? rawExtensions : null;
  final rawData = body['data'];

  if (rawData == null) {
    if (errors.isEmpty) {
      throw const GqlifyDecodingException(
        'GraphQL response contained neither "data" nor "errors"',
      );
    }
    return GqlifyResponse(errors: errors, extensions: extensions);
  }
  if (rawData is! Map<String, Object?>) {
    throw GqlifyDecodingException('"data" must be an object, got $rawData');
  }

  try {
    return GqlifyResponse(
      data: operation.parseData(rawData),
      errors: errors,
      extensions: extensions,
    );
  } on Object catch (e, st) {
    final failure = e is GqlifyDecodingException
        ? e
        : e is GqlifyDecodeError
            ? GqlifyDecodingException(e.message, cause: e, stackTrace: st)
            : GqlifyDecodingException(
                'Failed to decode data of ${operation.operationName}: $e',
                cause: e,
                stackTrace: st,
              );
    if (errors.isEmpty) throw failure;
    return GqlifyResponse(
      errors: errors,
      extensions: extensions,
      dataDecodingError: failure,
    );
  }
}
