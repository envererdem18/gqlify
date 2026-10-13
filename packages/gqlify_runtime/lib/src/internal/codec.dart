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
