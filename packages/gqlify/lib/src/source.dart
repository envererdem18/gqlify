import 'package:path/path.dart' as p;

/// An input file handed to the engine by an adapter.
///
/// [path] is project-relative and posix-normalized so that outputs and
/// diagnostics are identical across platforms and adapters.
final class GqlifySource {
  GqlifySource(String path, this.content) : path = normalizePath(path);

  final String path;
  final String content;
}

/// Normalizes [path] to a relative posix path (`lib/a/b.graphql`).
String normalizePath(String path) =>
    p.posix.normalize(path.replaceAll(r'\', '/'));
