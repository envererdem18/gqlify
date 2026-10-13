/// Programmatic API of the gqlify generator engine.
///
/// Most projects use the `gqlify` command line tool instead. The engine is a
/// pure function from [GenerationInput] to [GenerationResult].
library;

export 'src/config.dart'
    show GqlifyConfig, GenerationMode, ScalarConfig, ScalarJsonType;
export 'src/diagnostics.dart' show Diagnostic, DiagnosticSink, Severity;
export 'src/emit/formatter.dart' show FormatSettings;
export 'src/engine.dart'
    show FormatMemo, GenerationInput, GenerationResult, GqlifyEngine;
export 'src/source.dart' show GqlifySource, normalizePath;
