import 'package:gqlify/gqlify.dart';

const testSchemaPath = 'lib/schema.graphql';

/// Runs the engine on in-memory sources.
GenerationResult generate(
  String schema,
  Map<String, String> documents, {
  GqlifyConfig? config,
}) => GqlifyEngine().generate(
  GenerationInput(
    config: config ?? GqlifyConfig(schema: [testSchemaPath]),
    schema: [GqlifySource(testSchemaPath, schema)],
    documents: [
      for (final MapEntry(:key, :value) in documents.entries)
        GqlifySource(key, value),
    ],
  ),
);

/// Diagnostic codes of errors produced for a single document [doc].
List<String> errorCodes(String schema, String doc) => [
  for (final d in generate(schema, {'lib/a.graphql': doc}).diagnostics)
    if (d.isError) d.code,
];

const shopSchema = r'''
interface Node { id: ID! }
type Product implements Node {
  id: ID!
  name: String!
  price(currency: String = "EUR"): Float
  tags: [String!]!
  related(first: Int!): [Product!]!
  status: Status!
}
type Category implements Node { id: ID! name: String products: [Product!]! }
union SearchResult = Product | Category
enum Status { ACTIVE ARCHIVED }
input ProductFilter { name: String, minPrice: Float, status: Status = ACTIVE, ids: [ID!] }
input Search @oneOf { byName: String byId: ID }
scalar DateTime
type Query {
  product(id: ID!): Product
  products(filter: ProductFilter, first: Int = 10): [Product!]!
  search(text: String!): [SearchResult!]!
  node(id: ID!): Node
  find(by: Search!): Product
  now: DateTime!
}
type Mutation { rename(id: ID!, name: String!): Product! }
''';
