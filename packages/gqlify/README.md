<p align="center">
  <img src="https://raw.githubusercontent.com/envererdem18/gqlify/main/assets/gqlify-banner.png" alt="gqlify — GraphQL, simplified for Dart" width="480">
</p>

<p align="center">
  <a href="https://pub.dev/packages/gqlify"><img src="https://img.shields.io/pub/v/gqlify.svg" alt="pub package"></a>
  <a href="https://github.com/envererdem18/gqlify/actions/workflows/ci.yaml"><img src="https://github.com/envererdem18/gqlify/actions/workflows/ci.yaml/badge.svg" alt="CI"></a>
  <a href="https://github.com/envererdem18/gqlify/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

---

If you've used GraphQL code generation in Dart, you've probably written
something like this at some point:

```dart
final result = await client.query$FetchPerson(
  Options$Query$FetchPerson(
    variables: Variables$Query$FetchPerson(id: '1'),
  ),
);
```

It works. It just doesn't read like Dart.

With gqlify, the same call looks like this:

```dart
final data = await api.fetchPerson(id: '1');
print(data.person?.name);
```

You write `.graphql` files. gqlify checks them against your schema and
generates a small, fully typed Dart API at build time: no strings parsed at
runtime and no wrappers to build. It works for Flutter, server and CLI apps
alike.

## Quick start

**1. Add the packages**

```yaml
dependencies:
  gqlify_runtime: ^0.1.0

dev_dependencies:
  gqlify: ^0.1.0
```

**2. Point gqlify at your schema** (in `pubspec.yaml`)

```yaml
gqlify:
  schema: lib/graphql/schema.graphql
```

**3. Write a query**

```graphql
# lib/graphql/person.graphql
query FetchPerson($id: ID!) {
  person(id: $id) {
    name
    email
  }
}
```

**4. Generate**

```bash
dart run gqlify generate
```

**5. Use it**

```dart
import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'graphql/schema.graphql.dart';
import 'graphql/person.graphql.dart';

final api = GqlifyClient(
  transport: HttpTransport(Uri.parse('https://api.example.com/graphql')),
);

final data = await api.fetchPerson(id: '1');
```

That's it. Each `.graphql` file gets a `.graphql.dart` file next to it, and
your schema gets one for the client, enums and input types.

## What you get

- **Plain method calls.** Every operation becomes a method on your client,
  with named parameters for its variables.
- **Real types.** Nullability comes straight from your schema, and fields
  under `@skip`/`@include` are nullable because they may be missing.
- **Fragments you can reuse.** Every fragment becomes an interface, so one
  widget can take data from any query that spreads it.

  ```dart
  Widget personTile(PersonSummary p) => Text(p.name);
  ```

- **Unions and interfaces as sealed classes.** Switch over them and the
  compiler checks you covered every case. Types the server adds later land
  in an `$Other` case instead of crashing your app.

  ```dart
  // query Find { results { ... on Product { sku } ... on Category { name } } }
  switch (result) {
    FindResults$Product(:final sku) => showProduct(sku),
    FindResults$Category(:final name) => showCategory(name),
    FindResults$Other() => const SizedBox.shrink(),
  }
  ```

- **Enums and input objects.** Leaving an optional input field out and
  sending an explicit `null` are different things in GraphQL, and gqlify
  keeps them apart: `ProductFilter(search: 'mug').withNull(minPrice: true)`.
- **Custom scalars.** Map `DateTime`, `Decimal` or anything else to your own
  Dart types.
- **Honest errors.** GraphQL errors, network failures and malformed
  responses each get their own exception. Partial data never pretends to be
  a success, and decoding errors tell you exactly where things went wrong:
  `Expected String at person.friends[2].name, got int`.

## CLI or build_runner? Either.

Use whichever fits your workflow. Both produce exactly the same files.

```bash
dart run gqlify generate       # fast, with a smart cache
dart run gqlify check          # for CI: fails if generated code is stale

dart run build_runner build    # or `watch`, if you already use build_runner
```

The CLI keeps a small cache in `.dart_tool/`:

- **Nothing changed:** it verifies the generated files and is done in about
  a second, or a fraction of that with an
  [AOT build](https://github.com/envererdem18/gqlify/blob/main/BENCHMARKS.md).
- **Something changed:** everything is validated again, but code that comes
  out the same isn't reformatted or rewritten.

Deleting the cache only makes the next run slower; it never changes the
result.

## Testing without a server

```dart
import 'package:gqlify_runtime/testing.dart';

final api = GqlifyClient(
  transport: MockTransport((request) => {
    'data': {
      'person': {'name': 'Ada', 'email': 'ada@example.com'},
    },
  }),
);

expect((await api.fetchPerson(id: '1')).person?.name, 'Ada');
```

## Configuration

A few useful settings; all of them are optional except `schema`:

```yaml
gqlify:
  schema: lib/graphql/schema.graphql   # SDL file(s) or an introspection .json
  documents: [lib/graphql/**.graphql]  # where your queries live
  mode: operations                     # or: schema_only, both
  client_name: GqlifyClient
  scalars:
    DateTime:
      type: DateTime
      json_type: String
      from_json: DateTime.parse
```

Prefer a separate file? Put the same settings in `gqlify.yaml`, without the
`gqlify:` key.

## Good to know

- Subscriptions aren't supported yet. Queries and mutations are.
- Every operation needs a name: gqlify uses it to name your Dart API.
- Use matching versions of `gqlify` and `gqlify_runtime` (0.1.x with 0.1.x).
  gqlify warns you if they drift apart.

## Want the details?

- [ARCHITECTURE.md](https://github.com/envererdem18/gqlify/blob/main/ARCHITECTURE.md):
  how it all works, including validation, naming, the cache and the
  build_runner integration.
- [BENCHMARKS.md](https://github.com/envererdem18/gqlify/blob/main/BENCHMARKS.md):
  measured numbers, including the full Magento schema.
- [example/](https://github.com/envererdem18/gqlify/tree/main/example): a
  small app you can run.

Found a bug or have an idea?
[Open an issue](https://github.com/envererdem18/gqlify/issues). It's very
welcome.
