import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:gqlify/gqlify.dart';
import 'package:gqlify/src/builder/gqlify_builder.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _package = 'shop';

typedef BuildOutcome = ({
  bool succeeded,
  Map<String, String> outputs,
  List<String> severe,
  List<String> warnings,
  TestBuilderResult result,
});

Future<BuildOutcome> runBuilder(Map<String, String> files) async {
  final logs = <LogRecord>[];
  final result = await testBuilder(
    GqlifyBuilder(),
    {
      for (final MapEntry(:key, :value) in files.entries)
        '$_package|$key': value,
    },
    rootPackage: _package,
    flattenOutput: true,
    onLog: logs.add,
  );
  return (
    succeeded: result.succeeded,
    outputs: {
      for (final id in result.outputs)
        id.path: result.readerWriter.testing.readString(id),
    },
    severe: [
      for (final l in logs)
        if (l.level >= Level.SEVERE) l.message,
    ],
    warnings: [
      for (final l in logs)
        if (l.level == Level.WARNING) l.message,
    ],
    result: result,
  );
}

/// What the CLI engine produces for the same files.
Map<String, String> engineOutputs(
  Map<String, String> files,
  GqlifyConfig config,
) {
  final result = GqlifyEngine().generate(
    GenerationInput(
      config: config,
      schema: [for (final s in config.schema) GqlifySource(s, files[s]!)],
      documents: [
        for (final MapEntry(:key, :value) in files.entries)
          if ((key.endsWith('.graphql') || key.endsWith('.gql')) &&
              key.startsWith('lib/') &&
              !config.schema.contains(key))
            GqlifySource(key, value),
      ],
      format: FormatSettings.fromProjectFiles(
        pubspecYaml: files['pubspec.yaml'],
        analysisOptionsYaml: files['analysis_options.yaml'],
      ),
    ),
  );
  expect(result.hasErrors, isFalse, reason: result.diagnostics.join('\n'));
  return result.outputs;
}

Map<String, String> shopFiles({String? config, String pubspecExtra = ''}) {
  String read(String name) =>
      File(p.join('test/fixtures/shop', name)).readAsStringSync();
  return {
    'pubspec.yaml': 'name: shop\nenvironment:\n  sdk: ^3.8.0\n$pubspecExtra',
    'gqlify.yaml': ?config,
    'lib/graphql/schema.graphql': read('schema.graphql'),
    'lib/graphql/fragments.graphql': read('fragments.graphql'),
    'lib/graphql/sub/products.graphql': read('products.graphql'),
  };
}

void main() {
  test(
    'generates byte-identical output to the engine/CLI (gqlify.yaml)',
    () async {
      final files = shopFiles(config: 'schema: lib/graphql/schema.graphql\n');
      final built = await runBuilder(files);
      expect(built.succeeded, isTrue, reason: built.severe.join('\n'));
      expect(built.outputs.keys.toSet(), {
        'lib/graphql/schema.graphql.dart',
        'lib/graphql/fragments.graphql.dart',
        'lib/graphql/sub/products.graphql.dart',
      });
      expect(
        built.outputs,
        engineOutputs(
          files,
          GqlifyConfig(schema: ['lib/graphql/schema.graphql']),
        ),
      );
      // Deprecation warnings are reported once, by the owning document.
      expect(
        built.warnings.where((w) => w.contains('deprecated-field')),
        hasLength(1),
      );
    },
  );

  test('configuration in pubspec.yaml', () async {
    final files = shopFiles(
      pubspecExtra:
          'gqlify:\n  schema: lib/graphql/schema.graphql\n  client_name: ShopApi\n',
    );
    final built = await runBuilder(files);
    expect(built.succeeded, isTrue, reason: built.severe.join('\n'));
    expect(
      built.outputs['lib/graphql/schema.graphql.dart'],
      contains('class ShopApi'),
    );
    expect(
      built.outputs,
      engineOutputs(
        files,
        GqlifyConfig(
          schema: ['lib/graphql/schema.graphql'],
          clientName: 'ShopApi',
        ),
      ),
    );
  });

  test('both configuration sources is an error', () async {
    final files = shopFiles(
      config: 'schema: lib/graphql/schema.graphql\n',
      pubspecExtra: 'gqlify:\n  schema: lib/graphql/schema.graphql\n',
    );
    final built = await runBuilder(files);
    expect(built.succeeded, isFalse);
    expect(built.severe.join(), contains('ambiguous-config'));
  });

  test('inactive without configuration', () async {
    final files = shopFiles();
    final built = await runBuilder(files);
    expect(built.succeeded, isTrue);
    expect(built.outputs, isEmpty);
  });

  test('schema_only mode and introspection-free inputs', () async {
    final files = shopFiles(
      config: 'schema: lib/graphql/schema.graphql\nmode: schema_only\n',
    );
    final built = await runBuilder(files);
    expect(built.outputs.keys, ['lib/graphql/schema.graphql.dart']);
    expect(
      built.outputs['lib/graphql/schema.graphql.dart'],
      contains('final class ProductFilter'),
    );
  });

  test('format settings from analysis_options.yaml', () async {
    final files = {
      ...shopFiles(config: 'schema: lib/graphql/schema.graphql\n'),
      'analysis_options.yaml': 'formatter:\n  page_width: 120\n',
    };
    final built = await runBuilder(files);
    expect(
      built.outputs,
      engineOutputs(
        files,
        GqlifyConfig(schema: ['lib/graphql/schema.graphql']),
      ),
    );
  });

  test(
    'errors are reported once, by the step owning them, and nothing is written',
    () async {
      final files = {
        ...shopFiles(config: 'schema: lib/graphql/schema.graphql\n'),
        'lib/graphql/broken.graphql': 'query Broken { nope }',
      };
      final built = await runBuilder(files);
      expect(built.succeeded, isFalse);
      expect(built.outputs, isEmpty);
      final errors = built.severe.where((m) => m.contains('error[')).toList();
      expect(errors, hasLength(1));
      expect(
        errors.single,
        contains(
          'lib/graphql/broken.graphql:1:16: error[unknown-field]: Cannot query field "nope" on type "Query".',
        ),
      );
    },
  );

  test('tracks every input that affects a step', () async {
    final files = shopFiles(config: 'schema: lib/graphql/schema.graphql\n');
    final built = await runBuilder(files);
    final tracked = built.result.readerWriter.testing
        .inputsTrackedFor(
          primaryInput: AssetId(_package, 'lib/graphql/sub/products.graphql'),
        )
        .map((id) => id.path)
        .toSet();
    expect(
      tracked,
      containsAll([
        'gqlify.yaml',
        'pubspec.yaml',
        'lib/graphql/schema.graphql',
        'lib/graphql/fragments.graphql',
        'lib/graphql/sub/products.graphql',
      ]),
    );
  });
}
