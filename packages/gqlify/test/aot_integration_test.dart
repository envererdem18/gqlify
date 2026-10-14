@Tags(['integration'])
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/sandbox.dart';

/// An AOT-compiled CLI (`dart compile exe` of `package:gqlify/cli.dart`)
/// cannot resolve packages at runtime; its cache must still work, keyed by
/// the executable's digest, and produce the same files as `dart run`.
void main() {
  test('AOT-compiled CLI generates identically and uses the cache', () async {
    final out = Directory.systemTemp.createTempSync('gqlify_aot_');
    final exe = p.join(out.path, Platform.isWindows ? 'gqlify.exe' : 'gqlify');
    final sandbox = Sandbox()
      ..write('gqlify.yaml', 'schema: lib/schema.graphql\n')
      ..write('lib/schema.graphql', 'type Query { a: Int b: String }')
      ..write('lib/q.graphql', 'query Q { a b }');
    try {
      final tool = File(p.join(out.path, 'tool.dart'))
        ..writeAsStringSync(
          "import 'package:gqlify/cli.dart';\n"
          'Future<void> main(List<String> args) => runGqlify(args);\n',
        );
      // Compile from within this package so that package:gqlify resolves.
      final local = File(p.join('tool', '_aot_test_entry.dart'));
      local.parent.createSync(recursive: true);
      local.writeAsStringSync(tool.readAsStringSync());
      try {
        final compile = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'exe',
          local.path,
          '-o',
          exe,
        ]);
        expect(
          compile.exitCode,
          0,
          reason: '${compile.stdout}${compile.stderr}',
        );
      } finally {
        local.deleteSync();
      }

      Future<Map<String, Object?>> run() async {
        final r = await Process.run(exe, [
          '-C',
          sandbox.dir.path,
          '--reporter',
          'json',
          'generate',
          '--explain',
        ]);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        return jsonDecode(r.stdout as String) as Map<String, Object?>;
      }

      final first = await run();
      expect(first['cache'], isNot(contains('disabled')));
      final second = await run();
      expect(second['cache'], startsWith('hit'));

      final aotOutputs = sandbox.generatedFiles();
      final clone = sandbox.cloneSources();
      try {
        expect((await clone.run(['generate'])).outputs, aotOutputs);
      } finally {
        clone.dispose();
      }
    } finally {
      sandbox.dispose();
      out.deleteSync(recursive: true);
    }
  });
}
