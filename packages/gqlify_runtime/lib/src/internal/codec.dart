// Helpers used by generated code. Every helper validates eagerly so that a
// malformed response fails with a descriptive GqlifyDecodingException instead
// of a lazy cast error far from the response boundary.

import '../exceptions.dart';

/// Reads `json[key]` as [T] (which may be nullable).
T gqlifyRead<T>(Map<String, Object?> json, String key, String owner) {
  final value = json[key];
  if (value is T) return value;
  throw _mismatch('$owner.$key', T, value, json.containsKey(key));
}

/// Casts a list element or nested value [value] to [T].
T gqlifyCast<T>(Object? value, String location) {
  if (value is T) return value;
  throw _mismatch(location, T, value, true);
}

/// Reads a GraphQL `Float!`, accepting any JSON number.
double gqlifyReadDouble(Map<String, Object?> json, String key, String owner) =>
    gqlifyRead<num>(json, key, owner).toDouble();

/// Reads a nullable GraphQL `Float`, accepting any JSON number.
double? gqlifyReadDoubleOrNull(
  Map<String, Object?> json,
  String key,
  String owner,
) =>
    gqlifyRead<num?>(json, key, owner)?.toDouble();

/// Casts a `Float!` list element or nested value.
double gqlifyCastDouble(Object? value, String location) =>
    gqlifyCast<num>(value, location).toDouble();

/// Casts a nullable `Float` list element or nested value.
double? gqlifyCastDoubleOrNull(Object? value, String location) =>
    gqlifyCast<num?>(value, location)?.toDouble();

GqlifyDecodingException _mismatch(
  String location,
  Type expected,
  Object? value,
  bool present,
) =>
    GqlifyDecodingException(
      present
          ? 'Expected $expected at $location, got ${value.runtimeType}'
          : 'Missing required field $location (expected $expected)',
    );

/// Deep equality for (possibly nested) lists, maps and sets of generated or
/// JSON values.
bool gqlifyDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!gqlifyDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !gqlifyDeepEquals(a[key], b[key])) {
        return false;
      }
    }
    return true;
  }
  if (a is Set && b is Set) {
    return a.length == b.length && a.containsAll(b);
  }
  return a == b;
}

/// Hash consistent with [gqlifyDeepEquals].
int gqlifyDeepHash(Object? value) => switch (value) {
      List() => Object.hashAll(value.map(gqlifyDeepHash)),
      Map() => Object.hashAllUnordered(
          value.entries.map((e) => Object.hash(e.key, gqlifyDeepHash(e.value))),
        ),
      Set() => Object.hashAllUnordered(value),
      _ => value.hashCode,
    };

// -----------------------------------------------------------------------------
// Composable decoders (used by generated `fromJson` since 0.1.0-dev.5).
//
// Generated code reads every field as `gqlifyRead(json, 'key', decoder)` with
// a (usually `const`) decoder describing the field's type. The response path
// of a failure is collected while the error propagates, so the happy path
// does no bookkeeping, and messages name the location like GraphQL errors
// do: `product.categories[2].name`.

/// A decoding failure on its way up; converted to [GqlifyDecodingException]
/// with the full path by [gqlifyDecodeRoot] (and by `GqlifyClientBase`).
final class GqlifyDecodeError implements Exception {
  GqlifyDecodeError(this.expected, this.actual, {this.cause});

  final String expected;
  final Object? actual;
  final Object? cause;
  final List<Object> _path = [];
  bool _missing = false;

  /// Response path from the decoded root, e.g. `['product', 'tags', 2]`.
  List<Object> get path => _path.reversed.toList();

  GqlifyDecodeError _at(Object segment, {bool missing = false}) {
    if (_path.isEmpty && missing) _missing = true;
    _path.add(segment);
    return this;
  }

  String get message {
    final location = path.isEmpty
        ? '<root>'
        : path
            .map((s) => s is int ? '[$s]' : '.$s')
            .join()
            .replaceFirst('.', '');
    if (cause != null) return 'Cannot decode $expected at $location: $cause';
    if (_missing) {
      return 'Missing required field $location (expected $expected)';
    }
    return 'Expected $expected at $location, got ${actual.runtimeType}';
  }

  @override
  String toString() => message;
}

/// Decodes one JSON value into [T].
abstract base class GqlifyDecoder<T> {
  const GqlifyDecoder();

  T decode(Object? json);
}

final class _Cast<T> extends GqlifyDecoder<T> {
  const _Cast(this.name);

  final String name;

  @override
  T decode(Object? json) =>
      json is T ? json : throw GqlifyDecodeError(name, json);
}

final class _Double extends GqlifyDecoder<double> {
  const _Double();

  @override
  double decode(Object? json) =>
      json is num ? json.toDouble() : throw GqlifyDecodeError('double', json);
}

/// `String!` / `ID!`.
const GqlifyDecoder<String> gqlifyString = _Cast<String>('String');

/// `Int!`.
const GqlifyDecoder<int> gqlifyInt = _Cast<int>('int');

/// `Float!`: any JSON number.
const GqlifyDecoder<double> gqlifyDouble = _Double();

/// Any JSON number as `num`.
const GqlifyDecoder<num> gqlifyNum = _Cast<num>('num');

/// `Boolean!`.
const GqlifyDecoder<bool> gqlifyBool = _Cast<bool>('bool');

/// Any non-null JSON value (unmapped custom scalars).
const GqlifyDecoder<Object> gqlifyJson = _Cast<Object>('Object');

/// A JSON object, as-is.
const GqlifyDecoder<Map<String, Object?>> gqlifyJsonObject =
    _Cast<Map<String, Object?>>('Map<String, Object?>');

/// A JSON array, as-is.
const GqlifyDecoder<List<Object?>> gqlifyJsonList =
    _Cast<List<Object?>>('List<Object?>');

/// `null`, or [inner] for anything else.
final class GqlifyNullable<T extends Object> extends GqlifyDecoder<T?> {
  const GqlifyNullable(this.inner);

  final GqlifyDecoder<T> inner;

  @override
  T? decode(Object? json) => json == null ? null : inner.decode(json);
}

/// A JSON array of [inner] values.
final class GqlifyList<T> extends GqlifyDecoder<List<T>> {
  const GqlifyList(this.inner);

  final GqlifyDecoder<T> inner;

  @override
  List<T> decode(Object? json) {
    if (json is! List) throw GqlifyDecodeError('List', json);
    final result = <T>[];
    var i = 0;
    try {
      for (; i < json.length; i++) {
        result.add(inner.decode(json[i]));
      }
    } on GqlifyDecodeError catch (e) {
      throw e._at(i);
    }
    return result;
  }
}

/// A JSON object decoded by a generated `fromJson`.
final class GqlifyObject<T> extends GqlifyDecoder<T> {
  const GqlifyObject(this.fromJson);

  final T Function(Map<String, Object?> json) fromJson;

  @override
  T decode(Object? json) => json is Map<String, Object?>
      ? fromJson(json)
      : throw GqlifyDecodeError('object', json);
}

/// A [J] JSON value converted by [convert] (enums, custom scalars).
/// Exceptions thrown by [convert] become decoding errors.
final class GqlifyConvert<J, T> extends GqlifyDecoder<T> {
  const GqlifyConvert(this.convert, this.name);

  final T Function(J json) convert;
  final String name;

  @override
  T decode(Object? json) {
    if (json is! J) throw GqlifyDecodeError(name, json);
    try {
      return convert(json);
    } on GqlifyDecodeError {
      rethrow;
    } on Object catch (e) {
      throw GqlifyDecodeError(name, json, cause: e);
    }
  }
}

/// Reads `json[key]` with [decoder], adding [key] to the path of failures.
T gqlifyField<T>(
    Map<String, Object?> json, String key, GqlifyDecoder<T> decoder) {
  try {
    return decoder.decode(json[key]);
  } on GqlifyDecodeError catch (e) {
    throw e._at(key, missing: !json.containsKey(key));
  }
}

/// Runs [decode] on a response root, converting failures to
/// [GqlifyDecodingException] with the full response path.
T gqlifyDecodeRoot<T>(T Function() decode) {
  try {
    return decode();
  } on GqlifyDecodeError catch (e) {
    throw GqlifyDecodingException(e.message, cause: e);
  }
}

/// A GraphQL enum value decoded by the generated enum's `fromJson`.
final class GqlifyEnum<T> extends GqlifyDecoder<T> {
  const GqlifyEnum(this.fromJson);

  final T Function(String json) fromJson;

  @override
  T decode(Object? json) => json is String
      ? fromJson(json)
      : throw GqlifyDecodeError('enum value', json);
}
