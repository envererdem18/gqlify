# Implementation summary

All five milestones (A–E) are implemented; the packages are pre-release and
not published. This file summarizes what was built, how it was verified,
what is supported and what is not, measured performance, and remaining
risks. Details are in [ARCHITECTURE.md](ARCHITECTURE.md),
[BENCHMARKS.md](BENCHMARKS.md), [README.md](README.md) and
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

## What was built

| Component | Location |
| --- | --- |
| Deterministic generator engine (pure function: inputs → output files and diagnostics) | `packages/gqlify/lib/src/{schema,documents,ir,emit}`, `engine.dart` |
| CLI: `generate [--clean] [--explain]`, `check`, `cache verify/clear`, `--reporter json`, `-j`, `--lock-timeout` | `packages/gqlify/lib/src/cli`, `bin/gqlify.dart`, `lib/cli.dart` |
| Correctness-first CLI cache in `.dart_tool/gqlify/` | `packages/gqlify/lib/src/cache` |
| `build_runner` builder (per input, all inputs tracked) | `packages/gqlify/lib/builder.dart`, `build.yaml` |
| Pure-Dart runtime: client base, `HttpTransport`, `MockTransport`, typed responses, exceptions, decoders | `packages/gqlify_runtime` |
| Example application (CLI and `build_runner`) | `example/` |
| Benchmark harness, including the Magento 2.4 schema | `packages/gqlify/benchmark` |

## Tests run

The final run passed all 167 tests (`dart test` in each package):

| Package | Tests | What they cover |
| --- | --- | --- |
| `gqlify` | 138 | See the list below. |
| `gqlify_runtime` | 18 | Client semantics, `HttpTransport` (headers, non-2xx responses, timeouts, network errors), decoders with response-path errors. |
| `example` | 11 | The generated API used as an application would use it. |

The `gqlify` tests cover:

- **Schema and validation:**
  - every executable validation rule of the GraphQL spec, section 5
  - schema building, including legacy SDL
  - deprecation warnings
- **Generation:**
  - printer round-trips and naming rules
  - modes and scalar mappings
  - introspection ≡ SDL equivalence
- **Golden fixtures:** four committed fixtures; strict `dart analyze` over
  them proves the generated code compiles.
- **Runtime behavior of generated code:** fragments, sealed polymorphic
  hierarchies, covariant fields, enums, inputs with explicit `null`,
  `@oneOf`, custom scalars.
- **Determinism:** independent of input order.
- **CLI integration.**
- **Cache equivalence:** differential tests on every Milestone C scenario.
- **Failure injection:** interrupted writes, a full disk, read-only
  directories, leftover temporary files.
- **Concurrency:** separate processes, including a lock holder killed with
  SIGKILL.
- **Property-based fuzzing:** 4 seeds per run; 40 seeds (560 edit steps)
  passed locally.
- **Large fixture:** a 240-operation project.
- **Equivalence checks:**
  - parallel ≡ sequential formatting
  - `build_test` builder tests
  - real `build_runner build` and `watch` compared with clean CLI generation
  - an AOT-compiled CLI generating identically and getting warm hits

Also verified:

- `dart format --set-exit-if-changed` and `dart analyze --fatal-infos` with
  strict casts, inference and raw types.
- `gqlify check` and `build_runner build` in `example/` produce the same
  files.
- `dart pub publish --dry-run` for both packages. The only warning is the
  uncommitted working tree.

CI ([.github/workflows/ci.yaml](.github/workflows/ci.yaml)) runs all of the
above on Linux, macOS and Windows. **Windows and Linux have not been run
locally; they are covered only by CI**, which needs a push to run.

## GraphQL support

### Supported

- **Operations:** queries and mutations; named operations with variables,
  including defaults, lists and non-null.
- **Selections:** aliases, nested selections, `__typename`.
- **Fragments:** named and inline, nested, across files, conditional. They
  are generated as interfaces that response classes implement.
- **Interfaces and unions:** sealed classes decoded by `__typename`, with an
  `$Other` fallback for unknown types; per-type fragment variants;
  covariant field narrowing.
- **Directives:** `@skip`/`@include`, which make fields optional.
- **Enums:** an `$unknown` fallback for values the client does not know.
- **Input objects:** omitted vs explicit `null` (`withNull`) vs value;
  `@oneOf` with one constructor per field.
- **Scalars:** built-in scalars and configurable custom scalars with
  explicit decode/encode contracts.
- **Deprecation:** `@Deprecated` annotations and warnings.
- **Schemas:** SDL (multiple files, extensions, legacy `implements A, B`) and
  introspection JSON.
- **Modes:** `operations`, `schema_only`, `both`.
- **Validation:** the full executable-document rules (gqlify implements them
  because `package:gql` has none).
- **Errors:** GraphQL errors (also with partial data), transport errors and
  decoding errors are distinct exception types; no silent success.

### Not supported, or limited

- **Subscriptions:** rejected (`unsupported-subscription`). There are no
  persisted queries or APQ.
- **Anonymous operations:** rejected, because names are needed for Dart
  names.
- **Fragments:** they produce interfaces only, not standalone concrete
  classes.
- **Schema-only mode:** it does not generate object, interface or union
  types, by design. Response shapes exist only per operation and fragment.
- **Unknown enum values:** `$unknown` cannot be encoded back to the server.
- **Introspection diagnostics:** they have no line and column positions.

## Measured performance

Measured on macOS, Apple Silicon, 8 logical CPUs; see BENCHMARKS.md for the
method and the full tables.

| Project | Cold | Warm (no change) | One operation changed |
| --- | --- | --- | --- |
| Magento 2.4 schema, 300 operations, JIT | 3.0 s | 0.84 s | 1.5 s |
| Magento 2.4 schema, 300 operations, AOT | 1.3 s | 0.09 s | 0.33 s |
| Synthetic, 1,000 operations (~45 MiB of output), JIT | 13–14 s | 1.3 s | 4.1 s |
| Synthetic, 1,000 operations, AOT | 12–14 s | 0.49 s | 2.8 s |

- **Formatting dominates.** `dart_style` is 80–90% of a cold run.
- **Optimizations kept:** each was measured before being kept:
  - parallel formatting (2 isolates by default; more isolates use far more
    memory)
  - composable runtime decoders: 10% less generated code, about 18% faster
    formatting
  - no redundant hashing after edits: about 0.9 s saved per edit on the
    large fixture
- **Rust or another native engine is not justified.** The cost is in
  formatting, which a native engine could only remove by reimplementing
  `dart format` byte for byte.

## Remaining risks

- **Platforms:** Windows and Linux are tested only by CI. File locking,
  paths and line endings (now pinned with `.gitattributes`) are the areas to
  watch.
- **Formatter drift:** generated code is formatted with the `dart_style`
  version resolved for gqlify. If it differs from the SDK's `dart format`,
  `dart format` could reformat generated files. `analysis_options.yaml`
  `include:` chains are not followed for `formatter:` settings.
- **Large projects:**
  - Cold runs of very large outputs take 12–14 s.
  - Peak memory reaches 0.3–0.6 GiB with the default settings, and several
    GiB with `-j 4` under AOT.
  - Under `build_runner build`, a shared change reformats everything (15 s
    on the large fixture), because a new process has no memo; `watch` keeps
    one.
- **Rebuild scope:** IR building and emission run for every library on each
  change (about 1 s on the large fixture). Skipping unchanged libraries is
  possible but not implemented.
- **Adapter difference:** on an error, `build_runner` removes the generated
  files of that build until it is fixed; the CLI keeps them. This is
  inherent to `build_runner`.
- **Ownership scan:** the scan for stale outputs walks the whole package.
  This is cheap on the fixtures, but large unrelated trees cost time.
- **Runtime version:** generated code needs `gqlify_runtime` 0.1.0-dev.3 or
  later. gqlify warns (`runtime-version`) when `pubspec.lock` resolves an
  older version.
- **Name:** `gqlify` is free on pub.dev, but a JavaScript GraphQL project
  uses the same name (see RELEASE_CHECKLIST.md). Publishing requires the
  maintainer's decision.
- **Benchmark conditions:** benchmarks ran on a developer machine with other
  applications open. A re-run was discarded because heavy swapping made it
  unrepresentative.
