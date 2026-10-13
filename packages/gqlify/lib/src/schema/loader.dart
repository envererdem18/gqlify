import 'package:gql/ast.dart' as ast;
import 'package:gql/language.dart' as lang;
import 'package:source_span/source_span.dart';

import '../diagnostics.dart';
import '../source.dart';
import 'introspection.dart';
import 'schema.dart';
import 'sdl_builder.dart';

/// Loads the schema from SDL files (`.graphql`, `.gql`, merged in order) or
/// from a single introspection result (`.json`).
Schema? loadSchema(List<GqlifySource> sources, DiagnosticSink sink) {
  final json = sources.where((s) => s.path.endsWith('.json')).toList();
  if (json.isNotEmpty && sources.length > 1) {
    sink.error(
      'invalid-config',
      'An introspection JSON schema must be the only schema file.',
      path: json.first.path,
    );
    return null;
  }
  final documents = <(String, ast.DocumentNode)>[];
  for (final source in sources) {
    if (source.path.endsWith('.json')) {
      final doc = introspectionToSdl(source.content, source.path, sink);
      if (doc != null) documents.add((source.path, doc));
      continue;
    }
    try {
      documents.add((
        source.path,
        lang.parseString(source.content, url: source.path),
      ));
    } on SourceSpanException catch (e) {
      sink.add(
        Diagnostic.error(
          'syntax-error',
          e.message,
          path: source.path,
          span: e.span,
        ),
      );
    }
  }
  if (sink.hasErrors) return null;
  return buildSchema(documents, sink);
}
