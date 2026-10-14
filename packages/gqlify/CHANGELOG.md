## 0.1.0

First release.

- Generates a typed Dart API from a GraphQL schema (SDL or introspection
  JSON) and your `.graphql` operations: `await api.fetchPerson(id: '1')`.
- Fragments become interfaces; unions and interfaces become sealed classes
  with a fallback for types added later; enums, input objects (with explicit
  `null` vs omitted), `@oneOf` and custom scalars are supported.
- Full validation of your operations against the schema, with clear,
  located errors and deprecation warnings.
- `dart run gqlify generate` / `check` with a correctness-first cache, plus
  `--clean`, `--explain`, `cache verify` and `cache clear`.
- A `build_runner` builder that produces exactly the same files as the CLI.
- Modes for operations, schema types only, or both.
