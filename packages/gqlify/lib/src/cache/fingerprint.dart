import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// SHA-256 of [content] as lowercase hex.
String sha256Hex(List<int> content) => sha256.convert(content).toString();

/// SHA-256 of [text] encoded as UTF-8.
String sha256Text(String text) => sha256Hex(utf8.encode(text));

/// Identifies the generator implementation, so that cached results are never
/// reused across generator, formatter, parser or SDK changes.
///
/// It covers the full source of `package:gqlify` (not just its version, so
/// that local edits during development invalidate caches), the resolved
/// versions of the packages that shape output (`gql`, `dart_style`,
/// `analyzer`) and the Dart SDK version.
///
/// In an AOT-compiled executable (`dart compile exe`), packages cannot be
/// resolved; the executable itself then contains all generator code, so its
/// digest is the fingerprint. Returns `null` if neither works, in which case
/// caching is disabled.
Future<String?> generatorFingerprint() async {
  final gqlify = await Isolate.resolvePackageUri(
    Uri.parse('package:gqlify/gqlify.dart'),
  );
  if (gqlify == null || gqlify.scheme != 'file') {
    return _executableFingerprint();
  }
  final libDir = Directory(p.dirname(gqlify.toFilePath()));
  final files =
      libDir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final parts = <String>['gqlify-generator-fingerprint-1', Platform.version];
  for (final file in files) {
    final relative = p
        .relative(file.path, from: libDir.path)
        .replaceAll(r'\', '/');
    parts.add('$relative:${sha256Hex(file.readAsBytesSync())}');
  }
  for (final package in ['gql', 'dart_style', 'analyzer']) {
    final version = await _packageVersion(package);
    if (version == null) return null;
    parts.add('$package:$version');
  }
  return sha256Text(parts.join('\n'));
}

/// The `version` from [package]'s pubspec, plus its location (a path
/// dependency may change without a version bump).
Future<String?> _packageVersion(String package) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:$package/'));
  if (uri == null || uri.scheme != 'file') return null;
  final root = p.dirname(p.dirname(p.join(uri.toFilePath(), 'x')));
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return null;
  final version = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync())?.group(1);
  return version == null ? null : '$version@$root';
}

/// Digest of the running executable if it is a self-contained AOT binary
/// (not the `dart` VM, which runs code it does not contain).
String? _executableFingerprint() {
  final executable = File(Platform.resolvedExecutable);
  final name = p.basenameWithoutExtension(executable.path);
  if (name == 'dart' || name == 'dartaotruntime' || !executable.existsSync()) {
    return null;
  }
  return sha256Text(
    'gqlify-aot-fingerprint-1\n${sha256Hex(executable.readAsBytesSync())}',
  );
}
