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
