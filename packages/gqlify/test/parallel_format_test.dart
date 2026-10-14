import 'dart:math';

import 'package:gqlify/gqlify.dart';
import 'package:test/test.dart';

import 'support/sandbox.dart';
import 'support/synthetic.dart';

void main() {
  test('parallel formatting produces exactly the sequential result', () async {
    final project = SyntheticProject(
      random: Random(5),
      types: 30,
      fragments: 20,
      documents: 30,
      operationsPerDocument: 4,
    );
    final sandbox = Sandbox();
    try {
      project.writeTo(sandbox, <String>{});
      String read(String path) => sandbox.read(path);
      final docs = [for (final path in sandbox.generatedFiles().keys) path];
      expect(docs, isEmpty);
      final input = GenerationInput(
        config: GqlifyConfig(schema: ['lib/gql/schema.graphql']),
        schema: [
          GqlifySource(
            'lib/gql/schema.graphql',
            read('lib/gql/schema.graphql'),
          ),
        ],
        documents: [
          for (final path in project.documents.keys)
            GqlifySource(path, read(path)),
          for (final path in project.fragmentHome.values.toSet())
            GqlifySource(path, read(path)),
        ],
      );
      final sequential = GqlifyEngine().generate(input);
      expect(
        sequential.hasErrors,
        isFalse,
        reason: sequential.diagnostics.join('\n'),
      );
      final size = sequential.outputs.values.fold(0, (n, o) => n + o.length);
      expect(
        size,
        greaterThan(256 * 1024),
        reason: 'large enough to use isolates',
      );

      for (final workers in [2, 3, 8]) {
        final parallel = await GqlifyEngine().generateAsync(
          input,
          concurrency: workers,
        );
        expect(
          parallel.outputs,
          sequential.outputs,
          reason: '$workers workers',
        );
        expect(parallel.diagnostics, sequential.diagnostics);
        expect(parallel.dependencies, sequential.dependencies);
      }
    } finally {
      sandbox.dispose();
    }
  });
}
