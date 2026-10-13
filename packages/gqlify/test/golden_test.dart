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
      final configFile = File(p.join(dir.path, 'gqlify.yaml'));
      final sink = DiagnosticSink();
      final config = configFile.existsSync()
          ? GqlifyConfig.parse(configFile.readAsStringSync(), sink)!
          : GqlifyConfig(schema: ['schema.graphql']);
      final result = GqlifyEngine().generate(
        GenerationInput(
          config: config,
          schema: [for (final s in config.schema) GqlifySource(s, read(s))],
          documents: [
            for (final f in files)
              if (f.path.endsWith('.graphql') &&
                  !config.schema.contains(p.basename(f.path)))
                GqlifySource(p.basename(f.path), f.readAsStringSync()),
          ],
          // Format like `dart format` would in this package.
          format: FormatSettings.fromProjectFiles(
            pubspecYaml: File('pubspec.yaml').readAsStringSync(),
          ),
        ),
      );
      expect(result.diagnostics.where((d) => d.isError), isEmpty);

      // Hand-written Dart files (e.g. scalar codecs) are not outputs.
      final existing = {
        for (final f in files)
          if (f.path.endsWith('.graphql.dart') || f.path.endsWith('.json.dart'))
            p.basename(f.path),
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
