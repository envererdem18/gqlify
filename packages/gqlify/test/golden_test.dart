import 'dart:io';

import 'package:gqlify/gqlify.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Regenerates every fixture under test/fixtures and compares with the
/// committed outputs. Set GQLIFY_UPDATE_GOLDENS=1 to rewrite them.
///
/// Committed outputs are also covered by `dart analyze`, which proves the
/// generated code compiles under strict analysis.
void main() {
  final update = Platform.environment['GQLIFY_UPDATE_GOLDENS'] == '1';
  final fixtures =
      Directory('test/fixtures').listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final dir in fixtures) {
    test('golden ${p.basename(dir.path)}', () {
      final files = dir.listSync().whereType<File>().toList();
      String read(String name) =>
          File(p.join(dir.path, name)).readAsStringSync();
      final result = GqlifyEngine().generate(
        GenerationInput(
          config: GqlifyConfig(schema: ['schema.graphql']),
          // Format like `dart format` would in this package.
          format: FormatSettings.fromProjectFiles(
            pubspecYaml: File('pubspec.yaml').readAsStringSync(),
          ),
          schema: [GqlifySource('schema.graphql', read('schema.graphql'))],
          documents: [
            for (final f in files)
              if (f.path.endsWith('.graphql') &&
                  p.basename(f.path) != 'schema.graphql')
                GqlifySource(p.basename(f.path), f.readAsStringSync()),
          ],
        ),
      );
      expect(result.diagnostics.where((d) => d.isError), isEmpty);

      final existing = {
        for (final f in files)
          if (f.path.endsWith('.dart')) p.basename(f.path),
      };
      if (update) {
        for (final name in existing.difference(result.outputs.keys.toSet())) {
          File(p.join(dir.path, name)).deleteSync();
        }
        result.outputs.forEach(
          (name, content) =>
              File(p.join(dir.path, name)).writeAsStringSync(content),
        );
        return;
      }
      expect(existing, result.outputs.keys.toSet());
      result.outputs.forEach((name, content) {
        expect(
          read(name),
          content,
          reason: '$name differs; rerun with GQLIFY_UPDATE_GOLDENS=1',
        );
      });
    });
  }
}
