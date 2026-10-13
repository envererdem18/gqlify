import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'project.dart';

/// Differences between generated outputs and the files on disk.
final class OutputPlan {
  OutputPlan({
    required this.created,
    required this.changed,
    required this.unchanged,
    required this.stale,
    required this.conflicts,
  });

  /// Outputs that do not exist yet.
  final List<String> created;

  /// Outputs whose content differs.
  final List<String> changed;
  final List<String> unchanged;

  /// Previously generated files that are no longer produced.
  final List<String> stale;

  /// Outputs whose path is taken by a file gqlify did not generate.
  final List<String> conflicts;

  bool get isUpToDate =>
      created.isEmpty && changed.isEmpty && stale.isEmpty && conflicts.isEmpty;

  /// Compares [outputs] with [project]'s files.
  static OutputPlan compute(Project project, Map<String, String> outputs) {
    final created = <String>[];
    final changed = <String>[];
    final unchanged = <String>[];
    final conflicts = <String>[];
    for (final MapEntry(key: path, value: content) in outputs.entries) {
      final file = File(project.absolute(path));
      if (!file.existsSync()) {
        created.add(path);
      } else if (!Project.isGenerated(file)) {
        conflicts.add(path);
      } else if (_sameContent(file, content)) {
        unchanged.add(path);
      } else {
        changed.add(path);
      }
    }
    final stale = [
      for (final path in project.ownedOutputs())
        if (!outputs.containsKey(path)) path,
    ];
    return OutputPlan(
      created: created,
      changed: changed,
      unchanged: unchanged,
      stale: stale,
      conflicts: conflicts,
    );
  }

  static bool _sameContent(File file, String content) {
    final expected = utf8.encode(content);
    final actual = file.readAsBytesSync();
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  /// Writes created/changed outputs and deletes stale ones. Unchanged files
  /// are not touched, so file watchers do not see spurious changes.
  void apply(Project project, Map<String, String> outputs) {
    for (final path in [...created, ...changed]) {
      writeAtomically(project.absolute(path), outputs[path]!);
    }
    for (final path in stale) {
      final file = File(project.absolute(path));
      if (file.existsSync()) file.deleteSync();
    }
  }
}

/// Writes [content] to a temporary sibling file and renames it over [path],
/// so readers never observe a partially written library.
void writeAtomically(String path, String content) {
  final target = File(path);
  target.parent.createSync(recursive: true);
  final temp = File(
    p.join(target.parent.path, '.${p.basename(path)}.$pid.gqlify-tmp'),
  );
  try {
    temp.writeAsBytesSync(utf8.encode(content), flush: true);
    temp.renameSync(path);
  } catch (_) {
    if (temp.existsSync()) temp.deleteSync();
    rethrow;
  }
}
