import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../engine.dart';
import 'fingerprint.dart';
import 'manifest.dart';

/// The CLI's private, disposable cache in `.dart_tool/gqlify/`.
///
/// ```text
/// .dart_tool/gqlify/
///   manifest.json               last successful run (see Manifest)
///   artifacts/<generator>/<key> memoized formatter results
///   tmp/                        files being written
///   lock                        process lock (never deleted while held)
/// ```
///
/// Everything here may be deleted at any time; that only costs speed.
final class CacheStore {
  CacheStore(String projectRoot)
    : root = p.join(projectRoot, '.dart_tool', 'gqlify');

  final String root;

  String get manifestPath => p.join(root, 'manifest.json');
  String get lockPath => p.join(root, 'lock');
  String get _tmp => p.join(root, 'tmp');
  String _artifacts(String generator) => p.join(root, 'artifacts', generator);

  /// Reads the manifest. Returns the manifest, or `null` and the reason it
  /// cannot be used.
  (Manifest?, String) readManifest() {
    final file = File(manifestPath);
    if (!file.existsSync()) return (null, 'no previous cache');
    try {
      return (Manifest.decode(file.readAsStringSync()), 'cache loaded');
    } on CacheCorruptException catch (e) {
      return (null, 'cache ignored: $e');
    } on FileSystemException catch (e) {
      return (null, 'cache unreadable: ${e.message}');
    }
  }

  /// Deletes the manifest so that an interrupted run is never mistaken for
  /// a complete one.
  void invalidate() {
    final file = File(manifestPath);
    if (file.existsSync()) file.deleteSync();
  }

  /// Atomically replaces the manifest.
  void writeManifest(Manifest manifest) =>
      _writeAtomically(manifestPath, manifest.encode());

  /// A memo over the artifacts of [generator]. With [readOnly], new results
  /// are not stored; with [ignoreExisting], stored results are not used.
  CacheMemo memo(
    String generator, {
    bool readOnly = false,
    bool ignoreExisting = false,
  }) => CacheMemo._(
    this,
    generator,
    readOnly: readOnly,
    ignoreExisting: ignoreExisting,
  );

  /// Removes artifacts that [memo] did not use, and those of other generator
  /// versions.
  void pruneArtifacts(CacheMemo memo) {
    final all = Directory(p.join(root, 'artifacts'));
    if (!all.existsSync()) return;
    for (final dir in all.listSync()) {
      if (p.basename(dir.path) != memo.generator) {
        dir.deleteSync(recursive: true);
        continue;
      }
      if (dir is! Directory) continue;
      for (final file in dir.listSync()) {
        if (!memo.used.contains(p.basename(file.path))) file.deleteSync();
      }
    }
  }

  /// Deletes everything except the lock file (which may be held).
  void clear() {
    final dir = Directory(root);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync()) {
      if (p.equals(entity.path, lockPath)) continue;
      entity.deleteSync(recursive: true);
    }
  }

  /// Validates every artifact; returns problems found (empty if healthy).
  List<String> verifyArtifacts() {
    final problems = <String>[];
    final all = Directory(p.join(root, 'artifacts'));
    if (!all.existsSync()) return problems;
    for (final file in all.listSync(recursive: true).whereType<File>()) {
      if (_readArtifact(file) == null) {
        problems.add('corrupt artifact ${p.relative(file.path, from: root)}');
      }
    }
    return problems;
  }

  void _writeAtomically(String path, String content) {
    Directory(_tmp).createSync(recursive: true);
    final temp = File(
      p.join(
        _tmp,
        '${p.basename(path)}.$pid.${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      temp.writeAsBytesSync(utf8.encode(content), flush: true);
      File(path).parent.createSync(recursive: true);
      temp.renameSync(path);
    } catch (_) {
      if (temp.existsSync()) temp.deleteSync();
      rethrow;
    }
  }

  /// Artifact files are `<sha256 of content>\n<content>`, so truncation or
  /// corruption is always detected.
  static String? _readArtifact(File file) {
    try {
      final text = utf8.decode(file.readAsBytesSync());
      final newline = text.indexOf('\n');
      if (newline != 64) return null;
      final content = text.substring(65);
      return sha256Text(content) == text.substring(0, 64) ? content : null;
    } on Object {
      return null;
    }
  }
}

/// [FormatMemo] backed by self-verifying artifact files.
final class CacheMemo implements FormatMemo {
  CacheMemo._(
    this._store,
    this.generator, {
    required this.readOnly,
    required this.ignoreExisting,
  });

  final CacheStore _store;
  final String generator;
  final bool readOnly;
  final bool ignoreExisting;

  /// Keys looked up or stored during this run.
  final Set<String> used = {};

  File _file(String key) => File(p.join(_store._artifacts(generator), key));

  @override
  String? lookup(String key) {
    if (ignoreExisting) return null;
    final file = _file(key);
    if (!file.existsSync()) return null;
    final content = CacheStore._readArtifact(file);
    if (content == null) {
      if (!readOnly) file.deleteSync();
      return null;
    }
    used.add(key);
    return content;
  }

  @override
  void store(String key, String formatted) {
    if (readOnly) return;
    used.add(key);
    try {
      _store._writeAtomically(
        _file(key).path,
        '${sha256Text(formatted)}\n$formatted',
      );
    } on FileSystemException {
      // A cache write failure only costs speed.
    }
  }
}
