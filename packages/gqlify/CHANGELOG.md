## 0.1.0-dev.4 (unreleased)

Milestone D: build_runner support.

- `build_runner` builder (`package:gqlify/builder.dart`, auto-applied):
  per-input outputs, all inputs tracked through `BuildStep`, one engine run
  per build, byte-identical to the CLI.
- Configuration may live in the `gqlify:` section of `pubspec.yaml` (visible
  to build_runner without extra setup); both sources at once is an error.
- `build_test` unit tests and real `build_runner build`/`watch` integration
  tests compared against clean CLI generation.

## 0.1.0-dev.3 (unreleased)

Milestone C: correctness-first CLI caching.

- Cache in `.dart_tool/gqlify/`: verified warm hits skip generation entirely;
  otherwise validation always runs in full and only formatting is memoized
  (content-addressed, self-verifying artifacts).
- `generate --clean`, `--explain` (per-output reasons, per-phase timings),
  `check --clean/--explain`, `cache verify`, `cache clear`, `--lock-timeout`.
- Inter-process locking, atomic manifest written only after verified outputs,
  recovery from interrupted writes, leftover temp files and corrupt caches.
- Canonical emission order: a library's output depends only on its own
  document and the fragments it uses.
- Differential, failure-injection, concurrency and property-based tests.

## 0.1.0-dev.2 (unreleased)

Milestone B: semantic coverage and modes.

- Fragments (named, inline, nested, across files) generate interfaces that
  response classes implement.
- Interface and union fields decode by `__typename` into sealed hierarchies
  with a `$Other` fallback; `__typename` is added to requests automatically.
- Enums (with `$unknown` fallback), input objects with `withNull` for explicit
  `null`, `@oneOf` inputs with one constructor per field.
- Custom scalar mappings (`scalars:` in `gqlify.yaml`).
- Introspection JSON schemas.
- Modes `schema_only` and `both`.
- Deprecation warnings; `--reporter json`.
- Covariant interface fields are narrowed per runtime type.

## 0.1.0-dev.1 (unreleased)

- Milestone A: working vertical slice. Queries and mutations with scalar,
  object and list fields; CLI `generate` and `check`; mock and HTTP
  transports.
