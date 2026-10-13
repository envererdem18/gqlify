import 'package:gql/ast.dart' as ast;
import 'package:source_span/source_span.dart';

enum Severity { error, warning, info }

/// A located message produced by the engine.
///
/// Diagnostics are plain values so that adapters can print, serialize or
/// compare them (differential tests compare clean and incremental runs).
final class Diagnostic implements Comparable<Diagnostic> {
  const Diagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.path,
    this.line,
    this.column,
  });

  factory Diagnostic.error(
    String code,
    String message, {
    String? path,
    SourceSpan? span,
  }) => Diagnostic._located(Severity.error, code, message, path, span);

  factory Diagnostic.warning(
    String code,
    String message, {
    String? path,
    SourceSpan? span,
  }) => Diagnostic._located(Severity.warning, code, message, path, span);

  factory Diagnostic._located(
    Severity severity,
    String code,
    String message,
    String? path,
    SourceSpan? span,
  ) => Diagnostic(
    severity: severity,
    code: code,
    message: message,
    path: path ?? span?.sourceUrl?.toString(),
    line: span == null ? null : span.start.line + 1,
    column: span == null ? null : span.start.column + 1,
  );

  final Severity severity;

  /// Stable kebab-case identifier, e.g. `unknown-field`.
  final String code;
  final String message;

  /// Normalized (posix, project-relative) source path, if any.
  final String? path;

  /// 1-based position, if known.
  final int? line;
  final int? column;

  bool get isError => severity == Severity.error;

  @override
  int compareTo(Diagnostic other) {
    int cmp(Comparable<Object>? a, Comparable<Object>? b) =>
        a == null ? (b == null ? 0 : -1) : (b == null ? 1 : a.compareTo(b));
    for (final c in [
      cmp(path, other.path),
      cmp(line, other.line),
      cmp(column, other.column),
      severity.index.compareTo(other.severity.index),
      code.compareTo(other.code),
      message.compareTo(other.message),
    ]) {
      if (c != 0) return c;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is Diagnostic && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(severity, code, message, path, line, column);

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    'code': code,
    'message': message,
    if (path != null) 'path': path,
    if (line != null) 'line': line,
    if (column != null) 'column': column,
  };

  /// `path:line:column: severity[code]: message`
  @override
  String toString() {
    final location = [
      ?path,
      if (line != null) '$line',
      if (column != null) '$column',
    ].join(':');
    return '${location.isEmpty ? '' : '$location: '}'
        '${severity.name}[$code]: $message';
  }
}

/// Collects diagnostics for one engine run.
final class DiagnosticSink {
  final List<Diagnostic> _items = [];

  List<Diagnostic> get items => List.unmodifiable(_items);
  bool get hasErrors => _items.any((d) => d.isError);

  void add(Diagnostic diagnostic) => _items.add(diagnostic);

  void error(String code, String message, {String? path, ast.Node? at}) =>
      add(Diagnostic.error(code, message, path: path, span: spanOf(at)));

  void warning(String code, String message, {String? path, ast.Node? at}) =>
      add(Diagnostic.warning(code, message, path: path, span: spanOf(at)));

  /// Sorted, de-duplicated diagnostics.
  List<Diagnostic> sorted() => (_items.toSet().toList()..sort());
}

/// Best-effort source span of [node]. The `gql` parser only records spans on
/// name tokens, so container nodes fall back to their name.
FileSpan? spanOf(ast.Node? node) => switch (node) {
  null => null,
  ast.Node(span: final FileSpan span) => span,
  ast.OperationDefinitionNode(:final name) => name?.span,
  ast.FieldNode(:final alias, :final name) => (alias ?? name).span,
  ast.FragmentDefinitionNode(:final name) => name.span,
  ast.FragmentSpreadNode(:final name) => name.span,
  ast.InlineFragmentNode(:final typeCondition) => typeCondition?.on.name.span,
  ast.ArgumentNode(:final name) => name.span,
  ast.ObjectFieldNode(:final name) => name.span,
  ast.VariableDefinitionNode(:final variable) => variable.name.span,
  ast.VariableNode(:final name) => name.span,
  ast.DirectiveNode(:final name) => name.span,
  ast.NamedTypeNode(:final name) => name.span,
  ast.ListTypeNode(:final type) => spanOf(type),
  ast.TypeDefinitionNode(:final name) => name.span,
  ast.TypeExtensionNode(:final name) => name.span,
  ast.FieldDefinitionNode(:final name) => name.span,
  ast.InputValueDefinitionNode(:final name) => name.span,
  ast.DirectiveDefinitionNode(:final name) => name.span,
  ast.EnumValueNode(:final name) => name.span,
  _ => null,
};
