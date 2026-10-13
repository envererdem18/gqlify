import 'package:gqlify/gqlify.dart';
import 'package:gqlify/src/documents/document_set.dart';
import 'package:gqlify/src/documents/validator.dart';
import 'package:gqlify/src/schema/sdl_builder.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

List<Diagnostic> validate(Map<String, String> docs) {
  final sink = DiagnosticSink();
  final schema = parseSchema(shopSchema, sink)!;
  final set = DocumentSet.parse([
    for (final e in docs.entries) GqlifySource(e.key, e.value),
  ], sink);
  validateDocuments(schema, set, sink);
  return sink.sorted();
}

List<String> codes(String doc) => [
  for (final d in validate({'a.graphql': doc})) d.code,
];

void main() {
  test('accepts valid documents', () {
    expect(
      codes(r'''
      query Q($id: ID!, $filter: ProductFilter, $withTags: Boolean!) {
        product(id: $id) { id name price(currency: "USD") tags @include(if: $withTags) status }
        products(filter: $filter) { ...P }
        search(text: "x") { __typename ... on Product { id } ... on Category { name } }
        node(id: $id) { id ... on Product { name } }
        find(by: {byName: "x"}) { id }
        now
      }
      fragment P on Product { id related(first: 2) { id } }
      mutation M { rename(id: "1", name: "n") { id } }
    '''),
      isEmpty,
    );
  });

  final cases = {
    'anonymous-operation': '{ now }',
    'duplicate-operation': 'query Q { now } query Q { now }',
    'unknown-field': 'query Q { nope }',
    'unknown-field ': 'query Q { search(text: "") { id } }',
    'selection-on-leaf': 'query Q { now { a } }',
    'missing-selection': r'query Q($id: ID!) { product(id: $id) }',
    'unknown-argument': 'query Q { now(x: 1) }',
    'missing-argument': 'query Q { product { id } }',
    'duplicate-argument': 'query Q { product(id: "1", id: "2") { id } }',
    'invalid-value': 'query Q { product(id: true) { id } }',
    'invalid-value ': 'query Q { products(first: 99999999999) { id } }',
    'invalid-value  ': 'query Q { products(filter: {status: NOPE}) { id } }',
    'unknown-input-field': 'query Q { products(filter: {nope: 1}) { id } }',
    'invalid-one-of': 'query Q { find(by: {byName: "a", byId: "b"}) { id } }',
    'undefined-variable': r'query Q { product(id: $id) { id } }',
    'unused-variable': r'query Q($id: ID) { now }',
    'duplicate-variable':
        r'query Q($id: ID!, $id: ID!) { product(id: $id) { id } }',
    'invalid-variable-type': r'query Q($p: Product) { now }',
    'invalid-variable-usage': r'query Q($id: ID) { product(id: $id) { id } }',
    'invalid-variable-usage ':
        r'query Q($id: Int!) { product(id: $id) { id } }',
    'unknown-fragment': 'query Q { products { ...Nope } }',
    'impossible-fragment-spread':
        'query Q { products { ... on Category { id } } }',
    'invalid-type-condition': 'query Q { products { ... on Status { id } } }',
    'fragment-cycle':
        'query Q { products { ...A } } fragment A on Product { ...B } fragment B on Product { ...A }',
    'unknown-directive': 'query Q { now @nope }',
    'misplaced-directive': 'query Q @include(if: true) { now }',
    'field-conflict': 'query Q { products { x: id x: name } }',
    'field-conflict ':
        'query Q { products { price(currency: "A") price(currency: "B") } }',
    'unsupported-subscription': 'subscription S { now }',
    'type-system-in-document': 'type X { a: Int } query Q { now }',
    'syntax-error': 'query Q {',
  };
  for (final MapEntry(key: code, value: doc) in cases.entries) {
    test('reports ${code.trim()}: $doc', () {
      expect(codes(doc), contains(code.trim()));
    });
  }

  test('allows nullable variables with defaults in non-null positions', () {
    expect(
      codes(r'query Q($id: ID = "1") { product(id: $id) { id } }'),
      isEmpty,
    );
  });

  test('allows nullable variables where the argument has a default', () {
    expect(codes(r'query Q($n: Int) { products(first: $n) { id } }'), isEmpty);
  });

  test('allows differing fields on mutually exclusive types', () {
    expect(
      codes(
        'query Q { search(text: "") { '
        '... on Product { x: related(first: 1) { id } } '
        '... on Category { x: products { id } } } }',
      ),
      isEmpty,
    );
  });

  test('requires the same response shape even on exclusive types', () {
    expect(
      codes(
        'query Q { search(text: "") { '
        '... on Product { x: name } ... on Category { x: id } } }',
      ),
      ['field-conflict'],
    );
  });

  test('tracks variables and fragments across documents', () {
    final diagnostics = validate({
      'a.graphql':
          r'query Q($id: ID!, $first: Int!) { product(id: $id) { ...P } }',
      'b.graphql': r'fragment P on Product { related(first: $first) { id } }',
    });
    expect(diagnostics, isEmpty);
  });

  test('warns about unused fragments', () {
    expect(codes('query Q { now } fragment F on Product { id }'), [
      'unused-fragment',
    ]);
  });

  test('warns about deprecated fields, arguments and enum values', () {
    final sink = DiagnosticSink();
    final schema = parseSchema('''
      enum E { A B @deprecated(reason: "Use A.") }
      input I { x: Int @deprecated(reason: "Gone.") y: Int }
      type Query {
        old: Int @deprecated(reason: "Use new.")
        f(e: E, i: I, legacy: Int @deprecated): Int
      }
    ''', sink)!;
    final set = DocumentSet.parse([
      GqlifySource(
        'a.graphql',
        'query Q { old f(e: B, i: {x: 1}, legacy: 1) }',
      ),
    ], sink);
    validateDocuments(schema, set, sink);
    final diagnostics = sink.sorted();
    expect(diagnostics.every((d) => d.severity == Severity.warning), isTrue);
    expect(diagnostics.map((d) => d.code), [
      'deprecated-field',
      'deprecated-enum-value',
      'deprecated-input-field',
      'deprecated-argument',
    ]);
    expect(
      diagnostics.first.message,
      'Field "Query.old" is deprecated: Use new.',
    );
  });

  test('locates diagnostics', () {
    final d = validate({'lib/q.graphql': 'query Q {\n  nope\n}'}).single;
    expect(
      d.toString(),
      'lib/q.graphql:2:3: error[unknown-field]: Cannot query field "nope" on type "Query".',
    );
  });
}
