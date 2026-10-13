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

/// Deep equality for (possibly nested) lists of generated values.
bool gqlifyDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!gqlifyDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Hash consistent with [gqlifyDeepEquals].
int gqlifyDeepHash(Object? value) =>
    value is List ? Object.hashAll(value.map(gqlifyDeepHash)) : value.hashCode;
