import 'dart:io';

import 'package:gqlify/gqlify.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Outputs must not depend on the order in which documents (or definitions
/// across documents) are supplied, nor on previous runs.
void main() {
  for (final fixture in ['shop', 'polymorphism']) {
    test(
      '$fixture: identical outputs for any input order and repeated runs',
      () {
        final dir = Directory('test/fixtures/$fixture');
        final sink = DiagnosticSink();
        final configFile = File(p.join(dir.path, 'gqlify.yaml'));
        final config = configFile.existsSync()
            ? GqlifyConfig.parse(configFile.readAsStringSync(), sink)!
            : GqlifyConfig(schema: ['schema.graphql']);
        final documents = [
          for (final f in dir.listSync().whereType<File>())
            if (f.path.endsWith('.graphql') &&
                !f.path.endsWith('schema.graphql'))
              GqlifySource(p.basename(f.path), f.readAsStringSync()),
        ];
        GenerationResult run(List<GqlifySource> docs) =>
            GqlifyEngine().generate(
              GenerationInput(
                config: config,
                schema: [
                  GqlifySource(
                    'schema.graphql',
                    File(p.join(dir.path, 'schema.graphql')).readAsStringSync(),
                  ),
                ],
                documents: docs,
              ),
            );

        final engine = run(documents);
        expect(engine.hasErrors, isFalse);
        expect(run(documents.reversed.toList()).outputs, engine.outputs);
        expect(run(documents).outputs, engine.outputs);
        expect(run(documents).diagnostics, engine.diagnostics);
      },
    );
  }
}
