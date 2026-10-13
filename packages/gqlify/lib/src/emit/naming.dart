/// Deterministic GraphQL-to-Dart naming rules.
///
/// Names never depend on generation order or on other documents, so adding a
/// document can not rename existing API. Conflicts are reported as
/// diagnostics instead of being resolved with numeric suffixes.
library;

/// Words that can never be identifiers, plus `await`/`yield`, which are
/// unusable inside the `async` methods gqlify generates. Contextual keywords
/// such as `type`, `get` or `required` are valid member names and are kept.
const dartReservedWords = {
  'assert',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

/// Built-in identifiers: valid member names, but not valid type names.
const dartBuiltInIdentifiers = {
  'abstract',
  'as',
  'covariant',
  'deferred',
  'dynamic',
  'export',
  'extension',
  'external',
  'factory',
  'Function',
  'get',
  'implements',
  'import',
  'interface',
  'late',
  'library',
  'mixin',
  'operator',
  'part',
  'required',
  'set',
  'static',
  'typedef',
};

/// Names that generated code refers to unqualified. A generated type with
/// one of these names would shadow it, so such types get a `$` suffix.
const reservedTypeNames = {
  // dart:core
  'Object', 'String', 'int', 'double', 'num', 'bool', 'Map', 'List',
  'Iterable', 'Future', 'Null', 'Never', 'Type', 'Deprecated', 'override',
  'identical', 'Symbol', 'Record', 'Enum', 'Comparable', 'Invocation',
  // package:gqlify_runtime
  'GqlifyOperation', 'GqlifyOperationType', 'GqlifyClientBase',
  'GqlifyTransport', 'GqlifyResponse', 'GqlifyRequestOptions',
  'GraphQLResponseException',
};

/// Instance members of every generated class or inherited from Object.
const objectMembers = {'hashCode', 'runtimeType', 'toString', 'noSuchMethod'};

/// `UpperCamelCase` from a GraphQL name: `price_range` -> `PriceRange`,
/// `getProduct` -> `GetProduct`, `IN_STOCK` -> `InStock`, `URL` -> `URL`.
String pascalCase(String name) {
  final parts = _parts(name);
  if (parts.isEmpty) return name;
  return parts.map(_capitalize).join();
}

/// `lowerCamelCase` from a GraphQL name: `cart_id` -> `cartId`,
/// `URL` -> `url`, `IN_STOCK` -> `inStock`, `SKU_code` -> `skuCode`.
String camelCase(String name) {
  final parts = _parts(name);
  if (parts.isEmpty) return name;
  final first = parts.first;
  final head = first == first.toUpperCase()
      ? first.toLowerCase()
      : '${first[0].toLowerCase()}${first.substring(1)}';
  return head + parts.skip(1).map(_capitalize).join();
}

/// Underscore-separated parts; SCREAMING_SNAKE_CASE parts are lowercased so
/// that they capitalize as words.
List<String> _parts(String name) {
  final parts = name.split('_').where((p) => p.isNotEmpty).toList();
  final screaming = name.contains('_') && name == name.toUpperCase();
  return screaming ? [for (final p in parts) p.toLowerCase()] : parts;
}

String _capitalize(String s) => '${s[0].toUpperCase()}${s.substring(1)}';

/// Escapes a member, parameter or variable name. Names that are reserved,
/// start with a digit or collide with [extraReserved] get a `$` prefix.
String escapeMember(String name, [Set<String> extraReserved = const {}]) {
  if (name.isEmpty ||
      dartReservedWords.contains(name) ||
      extraReserved.contains(name) ||
      RegExp(r'^[0-9]').hasMatch(name)) {
    return '\$$name';
  }
  return name;
}

/// Escapes a type name; reserved names get a `$` suffix.
String escapeType(String name) =>
    dartReservedWords.contains(name) ||
        dartBuiltInIdentifiers.contains(name) ||
        reservedTypeNames.contains(name)
    ? '$name\$'
    : name;

/// A single-quoted Dart string literal for [value].
String dartString(String value) {
  final out = StringBuffer("'");
  for (final c in value.runes) {
    switch (c) {
      case 0x27:
        out.write(r"\'");
      case 0x5C:
        out.write(r'\\');
      case 0x24:
        out.write(r'\$');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (c < 0x20 || c == 0x7F) {
          out.write('\\u{${c.toRadixString(16)}}');
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.write("'");
  return out.toString();
}

/// `///` doc comment lines for [text], or an empty string.
String docComment(String? text, {String indent = ''}) {
  if (text == null || text.trim().isEmpty) return '';
  final lines = text.trim().split(RegExp(r'\r\n?|\n'));
  return lines
      .map(
        (l) => l.trimRight().isEmpty
            ? '$indent///\n'
            : '$indent/// ${l.trimRight()}\n',
      )
      .join();
}
