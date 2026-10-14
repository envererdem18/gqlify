import 'package:test/test.dart';

import 'support/helpers.dart';

/// The names used in README.md must be the names gqlify actually generates.
void main() {
  test('README examples match generated names', () {
    const schema = '''
      type Person { id: ID! name: String! email: String }
      type Product { sku: ID! }
      type Category { name: String! }
      union Result = Product | Category
      type Query { person(id: ID!): Person results: [Result!]! }
    ''';
    final result = generate(schema, {
      'lib/graphql/person.graphql': r'''
        query FetchPerson($id: ID!) { person(id: $id) { name email ...PersonSummary } }
        fragment PersonSummary on Person { name }
        query Find { results { ... on Product { sku } ... on Category { name } } }
      ''',
    });
    expect(result.hasErrors, isFalse, reason: result.diagnostics.join('\n'));
    final code = result.outputs['lib/graphql/person.graphql.dart']!;
    for (final snippet in [
      'Future<FetchPersonData> fetchPerson({required String id})',
      'abstract interface class PersonSummary',
      'final class FetchPersonPerson implements PersonSummary',
      r'final class FindResults$Product extends FindResults',
      r'final class FindResults$Category extends FindResults',
      r'final class FindResults$Other extends FindResults',
    ]) {
      expect(code, contains(snippet));
    }
  });
}
