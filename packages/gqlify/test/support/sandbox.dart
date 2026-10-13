import 'dart:convert';
import 'dart:io';

import 'package:gqlify/src/cli/output_sync.dart';
import 'package:gqlify/src/cli/project.dart';
import 'package:gqlify/src/cli/runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Everything observable about a generation: exit code, diagnostics and the
/// complete mapping of generated files on disk (path -> bytes).
final class Snapshot {
  Snapshot(this.exitCode, this.diagnostics, this.outputs, this.report);

  final int exitCode;
  final List<Object?> diagnostics;
  final Map<String, String> outputs;
  final Map<String, Object?> report;

  @override
  String toString() =>
      'exit $exitCode, ${outputs.length} outputs, diagnostics: $diagnostics';
}

/// A temporary package to run the CLI in.
final class Sandbox {
  Sandbox() : dir = Directory.systemTemp.createTempSync('gqlify_sandbox_') {
    write('pubspec.yaml', 'name: sandbox\nenvironment:\n  sdk: ^3.8.0\n');
  }

  final Directory dir;

  String path(String relative) => p.joinAll([dir.path, ...relative.split('/')]);

  void write(String relative, String content) {
    final file = File(path(relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String read(String relative) => File(path(relative)).readAsStringSync();

  bool exists(String relative) => File(path(relative)).existsSync();

  void delete(String relative) {
    final file = File(path(relative));
    if (file.existsSync()) file.deleteSync();
  }

  void dispose() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// Runs the CLI in-process and captures a [Snapshot].
  Future<Snapshot> run(
    List<String> args, {
    OutputIO io = const OutputIO(),
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await GqlifyCommandRunner(
      out: out,
      err: err,
      io: io,
    ).run(['-C', dir.path, '--reporter', 'json', ...args]);
    final Map<String, Object?> report = out.isEmpty
        ? {'raw': err.toString()}
        : jsonDecode(out.toString()) as Map<String, Object?>;
    return Snapshot(
      code,
      (report['diagnostics'] as List<Object?>?) ?? [err.toString()],
      generatedFiles(),
      report,
    );
  }

  /// Every gqlify-generated file in the package, path -> content.
  Map<String, String> generatedFiles() => {
    for (final path in Project(dir.path).ownedOutputs()) path: read(path),
  };

  /// Copies the package sources (no generated files, no caches) into a fresh
  /// sandbox.
  Sandbox cloneSources() {
    final clone = Sandbox();
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p
          .relative(entity.path, from: dir.path)
          .replaceAll(r'\', '/');
      if (relative.startsWith('.dart_tool/')) continue;
      if (generatedSuffixes.any(relative.endsWith) &&
          Project.isGenerated(entity)) {
        continue;
      }
      clone.write(relative, entity.readAsStringSync());
    }
    return clone;
  }
}

/// Generates incrementally in [sandbox] and from scratch in a copy of its
/// sources, and requires identical exit codes, diagnostics and — for
/// successful runs — identical generated file trees.
///
/// On failure the incremental tree is compared with the tree before the run
/// instead: failed generations must not change any file.
Future<Snapshot> expectMatchesClean(
  Sandbox sandbox, {
  List<String> args = const [],
  String? reason,
}) async {
  final before = sandbox.generatedFiles();
  final incremental = await sandbox.run(['generate', ...args]);
  final clone = sandbox.cloneSources();
  try {
    final clean = await clone.run(['generate']);
    expect(
      incremental.exitCode,
      clean.exitCode,
      reason: '$reason: exit codes ($incremental / $clean)',
    );
    expect(
      incremental.diagnostics,
      clean.diagnostics,
      reason: '$reason: diagnostics',
    );
    if (clean.exitCode == 0) {
      expect(
        incremental.outputs.keys,
        clean.outputs.keys,
        reason: '$reason: output paths',
      );
      expect(
        incremental.outputs,
        clean.outputs,
        reason: '$reason: output contents',
      );
    } else {
      expect(
        incremental.outputs,
        before,
        reason: '$reason: a failed generation must not change files',
      );
    }
  } finally {
    clone.dispose();
  }
  return incremental;
}
