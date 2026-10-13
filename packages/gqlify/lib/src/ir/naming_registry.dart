import 'package:gql/ast.dart' as ast;

import '../diagnostics.dart';

/// Tracks every generated top-level Dart name of one generation.
///
/// All generated libraries may be imported together, so names must be
/// unique across libraries. Collisions are reported, never resolved by
/// renaming, which keeps names independent of unrelated documents.
final class NamingRegistry {
  NamingRegistry(this.sink);

  final DiagnosticSink sink;
  final Map<String, String> _owners = {};

  /// Registers [name] for [origin]; reports a collision and returns `false`
  /// if it is taken.
  bool claim(String name, String origin, {String? path, ast.Node? at}) {
    final previous = _owners[name];
    if (previous != null) {
      sink.error(
        'name-collision',
        'Generated name "$name" for $origin collides with $previous. '
            'Rename one of them or use a field alias.',
        path: path,
        at: at,
      );
      return false;
    }
    _owners[name] = path == null ? origin : '$origin ($path)';
    return true;
  }
}
