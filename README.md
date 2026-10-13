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

> **Status: early development (Milestone C of 5). Not published to pub.dev.**
> Queries, mutations, fragments, enums, input objects, interfaces/unions,
> custom scalars, introspection input, schema-only mode and a
> correctness-first incremental CLI cache work end to end. The
> `build_runner` builder is planned. See [Supported today](#supported-today).

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

2. Add your schema (SDL, or an introspection `.json`) and operations:

   ```graphql
   # lib/graphql/products.graphql
   query GetProduct($sku: ID!) {
     product(sku: $sku) {
       ...ProductSummary
       categories { id name }
     }
   }

   fragment ProductSummary on Product {
     sku
     name
     price
   }
   ```

3. Create `gqlify.yaml` next to `pubspec.yaml`:

   ```yaml
   schema: lib/graphql/schema.graphql
   ```

4. Generate:

   ```bash
   dart run gqlify generate
   ```

   This writes `lib/graphql/schema.graphql.dart` (client, enums, inputs) and one
   `*.graphql.dart` library next to each operation document. Import the
   libraries whose operations you call.

## Configuration

```yaml
schema: lib/graphql/schema.graphql   # or a list of SDL files, or one introspection .json
documents:                           # optional, default: lib/**.graphql and lib/**.gql
  - lib/graphql/**.graphql
mode: operations                     # operations | schema_only | both
client_name: GqlifyClient            # optional
scalars:                             # optional custom scalar mappings
  DateTime:
    type: DateTime
    json_type: String                # String, int, double, num, bool, Map, List, Object
    from_json: DateTime.parse
    to_json: encodeDateTime          # optional
    import: package:my_app/scalars.dart
```

Unknown settings are errors, so typos never pass silently.

### Modes

| Mode | Generates |
| --- | --- |
| `operations` (default) | Client, operations and fragments, plus the enums and inputs they use |
| `schema_only` | Every enum and input object of the schema. No operations are read. |
| `both` | Everything from `operations` plus every enum and input object |

Response classes only exist for operations and fragments. A response contains
exactly the fields you selected, so gqlify does not generate a "full" class per
schema object type that would pretend otherwise.

### Formatting

Generated code is formatted to match `dart format` in your package. gqlify uses
your `pubspec.yaml` SDK constraint and the `formatter:` section of
`analysis_options.yaml`.

## Command line

| Command | What it does |
| --- | --- |
| `dart run gqlify generate` | Validates and generates. It writes only files whose content changed, removes outputs that are no longer produced (for example after deleting a document or switching mode), and never overwrites files it did not generate. On any error, no file is changed. |
| `dart run gqlify generate --explain` | Also reports, for each output, why it was regenerated, reused or removed, and the time spent per phase. |
| `dart run gqlify generate --clean` | Recomputes everything without using cached results, reconciles outputs and rebuilds the cache. It never deletes unrelated files. |
| `dart run gqlify check` | Validates and verifies that generated files are up to date without writing anything, not even cache files. Exits with `1` otherwise. Use this in CI. |
| `dart run gqlify cache verify` | Checks the integrity of the CLI cache. Exits with `1` if it is corrupt. |
| `dart run gqlify cache clear` | Deletes the CLI cache. Generated files are kept. |
| `--reporter json` | Prints one machine-readable JSON object (diagnostics, files, cache status, and with `--explain` the reasons and timings) to stdout. |
| `-C <dir>` | Runs for the package in `<dir>`. |
| `--lock-timeout <s>` | Sets how long to wait for another gqlify process on the same package (default 120). |

### Caching

The CLI keeps a disposable cache in `.dart_tool/gqlify/`. The cache never
changes results; deleting it only costs time:

- **Nothing changed:** if no input changed since the last successful run and
  every generated file still has the recorded content, gqlify verifies this
  and exits without regenerating.
- **Anything changed:** gqlify validates every document against the schema
  again (a cache can never hide an error). It then reuses previously
  formatted code for libraries whose generated source is identical, which
  is the expensive part.
- **On doubt:** a corrupt, outdated or inconsistent cache is ignored and
  rebuilt, and `--explain` reports why.
- **Safe under failure:** concurrent `gqlify` processes on one package wait
  for each other, and interrupted runs repair themselves on the next run.

`.dart_tool/` should not be committed.

Diagnostics use the format
`lib/graphql/products.graphql:3:5: error[unknown-field]: Cannot query field "nme" on type "Product".`
Warnings, for example `warning[deprecated-field]`, do not fail generation.

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

### Fragments

Every fragment becomes an `abstract interface class`. Every generated class
that spreads the fragment implements it, so you can write code against the
fragment once:

```dart
Widget productTile(ProductSummary p) => Text('${p.name} – ${p.price}');

productTile(data.product!);                 // from GetProduct
productTile(searchData.results.first);      // from SearchProducts
```

Fragments can live in any document and spread other fragments. Nested
selections and type conditions are typed too.

### Interfaces and unions

Fields of interface or union type decode by `__typename` into a sealed class
hierarchy. gqlify adds `__typename` to the request automatically. Every
hierarchy has an `$Other` class for types without their own selection,
including types added to the server later, so switches are exhaustive and
decoding never breaks on schema growth:

```dart
for (final hit in (await api.search(text: 'mug')).search) {
  switch (hit) {
    SearchSearch$Product() => productTile(hit),
    SearchSearch$Category(:final name) => print('Category $name'),
    SearchSearch$Other(:final typename) => print('Unhandled $typename'),
  }
}
```

### Enums

```dart
product.stockStatus == StockStatus.inStock;   // IN_STOCK -> inStock
StockStatus.inStock.value;                    // 'IN_STOCK'
```

Values unknown to the client decode to `$unknown` instead of failing.
Encoding `$unknown` throws, because it cannot be sent to the server.

### Input objects, variables and `null`

Optional fields and variables are **omitted** when you leave them `null`, so
server defaults apply. To send an explicit `null`, use `withNull`:

```dart
const filter = ProductFilter(search: 'mug', stockStatus: StockStatus.inStock);
await api.searchProducts(filter: filter);                     // {search, stock_status}
await api.searchProducts(filter: filter.withNull(minPrice: true)); // + "min_price": null
await api.execute(const SearchProductsQuery().withNull(filter: true)); // "filter": null
```

`@oneOf` inputs get one constructor per field, for example
`Lookup.sku('MUG')`.

### Custom scalars

Unmapped custom scalars are passed through as JSON (`Object`). Map them in
`gqlify.yaml` (see [Configuration](#configuration)). gqlify checks the wire
type, then calls `from_json`. A failing conversion surfaces as a
`GqlifyDecodingException`.

### Errors

| Exception | When |
| --- | --- |
| `GraphQLResponseException` | The response has GraphQL `errors`, even with partial `data`. It carries the `errors`, the partial `data` and `extensions`. |
| `GqlifyTransportException` | No GraphQL response was received: network error, timeout, or an HTTP error without a GraphQL body. |
| `GqlifyDecodingException` | The response does not match the generated types: a missing non-null field, a wrong type, or a missing `__typename`. The message names the location, e.g. `GetProductProduct.categories[]`. |

All three extend the sealed `GqlifyException`.

### Types and naming

- `Int` → `int`, `Float` → `double`, `String`/`ID` → `String`, `Boolean` →
  `bool`.
- Nullable GraphQL types are nullable in Dart. Fields under `@skip`/`@include`
  are nullable because they may be absent.
- Field names become `lowerCamelCase` (`stock_quantity` → `stockQuantity`).
  Aliases become field names.
- Response classes, inputs and operations have value equality and
  `toString`. Response classes also have `toJson`/`fromJson`.
- Generated names never depend on other files. Name clashes are reported as
  errors with a suggestion (usually an alias) instead of being renamed.

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
| Queries, mutations, variables (defaults, lists, non-null), aliases, nested selections | ✅ |
| Fragments (named, inline, nested, across files) as interfaces | ✅ |
| Interfaces and unions, sealed classes decoded by `__typename`, unknown-type fallback | ✅ |
| Enums (with unknown-value fallback), input objects, `@oneOf`, explicit `null` vs omitted | ✅ |
| Custom scalar mappings | ✅ |
| `@skip`/`@include` (optional fields), deprecation annotations and warnings | ✅ |
| SDL (multiple files, extensions) and introspection JSON schemas | ✅ |
| Modes `operations`, `schema_only`, `both` | ✅ |
| Full executable-document validation against the schema | ✅ |
| CLI `generate`, `check`, JSON reporter | ✅ |
| Incremental cache, `--clean`, `--explain`, `cache verify/clear`, process locking, crash recovery | ✅ |
| `build_runner` builder (`build`/`watch`) | Planned (Milestone D, required for 1.0) |
| Subscriptions, persisted queries | Later |

## Development

```bash
dart pub get                     # resolves the whole workspace
dart analyze                     # strict analysis, including generated goldens
dart test packages/gqlify packages/gqlify_runtime example
(cd example && dart run gqlify check)
GQLIFY_UPDATE_GOLDENS=1 dart test packages/gqlify/test/golden_test.dart  # refresh goldens
GQLIFY_FUZZ_SEEDS=1-200 dart test packages/gqlify/test/cache_fuzz_test.dart  # longer fuzzing
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.
