import 'package:gql/ast.dart' as ast;
import 'package:gql/language.dart' as lang;
import 'package:source_span/source_span.dart';

import '../diagnostics.dart';
import '../source.dart';

/// An operation or fragment together with the document it was defined in.
final class Defined<T extends ast.ExecutableDefinitionNode> {
  Defined(this.path, this.node);

  final String path;
  final T node;
}

/// A parsed operation document file.
final class ParsedDocument {
  ParsedDocument(this.path, this.node);

  final String path;
  final ast.DocumentNode node;

  Iterable<ast.OperationDefinitionNode> get operations =>
      node.definitions.whereType<ast.OperationDefinitionNode>();

  Iterable<ast.FragmentDefinitionNode> get fragments =>
      node.definitions.whereType<ast.FragmentDefinitionNode>();
}

/// All operation documents of one generation, with global name indexes.
///
/// Operation and fragment names share one namespace across every document,
/// matching how the documents are combined when sent to a server.
final class DocumentSet {
  DocumentSet(this.documents);

  final List<ParsedDocument> documents;

  late final Map<String, Defined<ast.OperationDefinitionNode>> operations = {
    for (final d in documents)
      for (final op in d.operations)
        if (op.name != null) op.name!.value: Defined(d.path, op),
  };

  late final Map<String, Defined<ast.FragmentDefinitionNode>> fragments = {
    for (final d in documents)
      for (final f in d.fragments) f.name.value: Defined(d.path, f),
  };

  /// Parses [sources]; syntax errors are reported to [sink] and the failing
  /// files are left out.
  static DocumentSet parse(List<GqlifySource> sources, DiagnosticSink sink) {
    final documents = <ParsedDocument>[];
    for (final source in sources) {
      try {
        final node = lang.parseString(source.content, url: source.path);
        documents.add(ParsedDocument(source.path, node));
        for (final def in node.definitions) {
          if (def is! ast.ExecutableDefinitionNode) {
            sink.error(
              'type-system-in-document',
              'Operation documents may only contain operations and fragments. '
                  'Is a schema file matched by the "documents" globs?',
              path: source.path,
              at: def,
            );
          }
        }
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
    return DocumentSet(documents);
  }
}
