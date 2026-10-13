import 'exceptions.dart';

/// A location in a GraphQL document referenced by a [GraphQLError].
final class GraphQLErrorLocation {
  const GraphQLErrorLocation(this.line, this.column);

  final int line;
  final int column;

  @override
  bool operator ==(Object other) =>
      other is GraphQLErrorLocation &&
      other.line == line &&
      other.column == column;

  @override
  int get hashCode => Object.hash(line, column);

  @override
  String toString() => '$line:$column';
}

/// An entry of a GraphQL response's `errors` list.
final class GraphQLError {
  const GraphQLError({
    required this.message,
    this.locations = const [],
    this.path,
    this.extensions,
  });

  /// Decodes an error entry leniently: unknown members are ignored and
  /// malformed optional members are dropped, but a missing message is kept
  /// visible rather than silently discarded.
  factory GraphQLError.fromJson(Object? json) {
    if (json is! Map) {
      return GraphQLError(message: 'Malformed GraphQL error: $json');
    }
    final message = json['message'];
    final locations = json['locations'];
    final path = json['path'];
    final extensions = json['extensions'];
    return GraphQLError(
      message: message is String ? message : 'GraphQL error without message',
      locations: [
        if (locations is List)
          for (final l in locations)
            if (l is Map && l['line'] is int && l['column'] is int)
              GraphQLErrorLocation(l['line'] as int, l['column'] as int),
      ],
      path: path is List
          ? List<Object>.unmodifiable(path.whereType<Object>())
          : null,
      extensions: extensions is Map<String, Object?> ? extensions : null,
    );
  }

  final String message;
  final List<GraphQLErrorLocation> locations;

  /// Response path segments (`String` field keys and `int` list indices).
  final List<Object>? path;
  final Map<String, Object?>? extensions;

  @override
  String toString() => path == null
      ? 'GraphQLError: $message'
      : 'GraphQLError at ${path!.join('.')}: $message';
}

/// A complete GraphQL response with typed [data].
final class GqlifyResponse<TData> {
  const GqlifyResponse({
    this.data,
    this.errors = const [],
    this.extensions,
    this.dataDecodingError,
  });

  /// Decoded `data`, or `null` if the server returned none or it could not be
  /// decoded alongside GraphQL [errors] (see [dataDecodingError]).
  final TData? data;
  final List<GraphQLError> errors;
  final Map<String, Object?>? extensions;

  /// Set when [errors] were present and the accompanying partial data could
  /// not be decoded. Without errors, decoding failures throw instead.
  final GqlifyDecodingException? dataDecodingError;

  bool get hasErrors => errors.isNotEmpty;

  /// Returns [data], or throws [GraphQLResponseException] if the response has
  /// any errors or no data. Partial data is never silently treated as success.
  TData get dataOrThrow {
    final data = this.data;
    if (errors.isNotEmpty || data == null) {
      throw GraphQLResponseException(errors,
          data: data, extensions: extensions);
    }
    return data;
  }
}
