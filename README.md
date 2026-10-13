# gqlify

**GraphQL, simplified for Dart.**

gqlify generates a small, strongly typed Dart API from a GraphQL schema and
your `.graphql` operations, at build time:

```dart
final api = GqlifyClient(transport: HttpTransport(Uri.parse('https://shop.example/graphql')));

final data = await api.getProduct(sku: 'ABC123');
print(data.product?.name);

await api.addToCart(cartId: cartId, sku: 'ABC123', quantity: 2);
```

There are no `Options$Query$...` or `Variables$Query$...` wrappers to build, no
`.graphql` assets read at runtime, and no query strings parsed at runtime.

> **Status: early development (Milestone A of 5). Not published to pub.dev.**
> Queries and mutations with scalar, object and list fields work end to end.
> Fragments, enums, input objects, interfaces/unions, schema-only mode, the
> `build_runner` builder and incremental caching are planned. See
> [Supported today](#supported-today).

## Packages

| Package | Add as | Purpose |
| --- | --- | --- |
| [`gqlify`](packages/gqlify) | `dev_dependencies` | Generator and `gqlify` command line tool |
| [`gqlify_runtime`](packages/gqlify_runtime) | `dependencies` | Tiny pure-Dart runtime used by generated code (works with Flutter, server and CLI apps) |

## Getting started

1. Add the packages. They are not on pub.dev yet; use path or git
   dependencies for now:

   ```yaml
   dependencies:
     gqlify_runtime: ^0.1.0
   dev_dependencies:
     gqlify: ^0.1.0
   ```

2. Add your schema (SDL) and operations:

   ```graphql
   # lib/graphql/products.graphql
   query GetProduct($sku: ID!) {
     product(sku: $sku) {
       sku
       name
       price
     }
   }
   ```

3. Create `gqlify.yaml` next to `pubspec.yaml`:

   ```yaml
   schema: lib/graphql/schema.graphql
   documents:             # optional, default: lib/**.graphql and lib/**.gql
     - lib/graphql/**.graphql
   client_name: GqlifyClient   # optional
   ```

4. Generate:

   ```bash
   dart run gqlify generate
   ```

   This writes `lib/graphql/schema.graphql.dart` (the client) and one
   `*.graphql.dart` library next to each operation document. Import the
   libraries whose operations you call.

## Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `schema` | (required) | SDL file, or a list of files (merged in order, `extend type` supported). |
| `documents` | `[lib/**.graphql, lib/**.gql]` | Glob patterns for operation documents. Schema files are excluded automatically. |
| `mode` | `operations` | `operations`. `schema_only` and `both` are planned for Milestone B. |
| `client_name` | `GqlifyClient` | Name of the generated client class. |

Unknown settings are errors, so typos never pass silently. Generated code is
formatted to match `dart format` in your package: gqlify uses your
`pubspec.yaml` SDK constraint and the `formatter:` section of
`analysis_options.yaml`.

## Command line

| Command | What it does |
| --- | --- |
| `dart run gqlify generate` | Validates and generates. Writes only files whose content changed, removes outputs of deleted documents, and never overwrites files it did not generate. On any error, no file is changed. |
| `dart run gqlify check` | Validates and verifies that generated files are up to date without writing anything. Exits with `1` otherwise. Use this in CI. |
| `-C <dir>` | Run for the package in `<dir>`. |

Diagnostics use the format
`lib/graphql/products.graphql:3:5: error[unknown-field]: Cannot query field "nme" on type "Product".`

## Using the generated API

```dart
import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'graphql/schema.graphql.dart';
import 'graphql/products.graphql.dart';

final api = GqlifyClient(
  transport: HttpTransport(
    Uri.parse('https://shop.example/graphql'),
    headersBuilder: (_) async => {'authorization': 'Bearer ${await token()}'},
    timeout: const Duration(seconds: 15),
  ),
);

// Short form: returns typed data, throws on any GraphQL error.
final data = await api.getProduct(sku: 'ABC123');

// Full form: errors, partial data, extensions, per-request options.
final response = await api.execute(
  const GetProductQuery(sku: 'ABC123'),
  options: const GqlifyRequestOptions(headers: {'x-store': 'de'}),
);
if (response.hasErrors) print(response.errors);
```

### Errors

| Exception | When |
| --- | --- |
| `GraphQLResponseException` | The response has GraphQL `errors`, even if partial `data` came with them. Carries `errors`, the partial `data` and `extensions`. |
| `GqlifyTransportException` | No GraphQL response: network error, timeout, or an HTTP error without a GraphQL body. |
| `GqlifyDecodingException` | The response does not match the generated types, for example a missing non-null field. The message names the location, e.g. `GetProductProduct.categories[]`. |

All three extend the sealed `GqlifyException`.

### Types

- `Int` → `int`, `Float` → `double`, `String`/`ID` → `String`, `Boolean` →
  `bool`. Custom scalars are passed through as JSON (`Object`) for now.
- Nullable GraphQL types are nullable in Dart. Fields under `@skip`/`@include`
  are nullable because they may be absent.
- Field names become `lowerCamelCase` (`stock_quantity` → `stockQuantity`),
  and aliases become field names.
- Response classes have value equality, `toString` and `toJson`/`fromJson`.
- Nullable variables are optional parameters and are omitted from the request
  when `null`.

### Testing without a server

```dart
import 'package:gqlify_runtime/testing.dart';

final transport = MockTransport((request) => {
  'data': {'product': {'sku': 'A', 'name': 'Mug', 'price': 9.5}},
});
final api = GqlifyClient(transport: transport);
expect((await api.getProduct(sku: 'A')).product?.name, 'Mug');
expect(transport.requests.single.variables, {'sku': 'A'});
```

## Supported today

| Feature | Status |
| --- | --- |
| Queries and mutations, variables, aliases, nested objects and lists, nullability, `@skip`/`@include` | ✅ |
| Full executable-document validation against the schema | ✅ |
| SDL schemas, multiple files, type extensions | ✅ |
| CLI `generate` and `check` | ✅ |
| Fragments, enums, input objects, interfaces/unions, custom scalar mapping | Planned (Milestone B) |
| Schema-only mode, introspection JSON | Planned (Milestone B) |
| Incremental cache, `--clean`, `--explain`, `cache verify/clear` | Planned (Milestone C) |
| `build_runner` builder (`build`/`watch`) | Planned (Milestone D, required for 1.0) |
| Subscriptions, persisted queries | Later |

Unsupported constructs are reported as `unsupported-feature` errors; they are
never silently mis-generated.

## Development

```bash
dart pub get                     # resolves the whole workspace
dart analyze                     # strict analysis, including generated goldens
dart test packages/gqlify packages/gqlify_runtime example
(cd example && dart run gqlify check)
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.
