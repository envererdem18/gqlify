// In-process engine profile (no process startup): phase timings of repeated
// runs on a fixture, after JIT warm-up.
//
//   dart run benchmark/profile_engine.dart [large|medium|magento] [runs] [workers]
import 'dart:io';
import 'dart:math';

import 'package:gqlify/gqlify.dart';
import 'package:gqlify/src/schema/loader.dart';
import 'package:path/path.dart' as p;

import 'src/magento_schema.dart';
import 'src/operations.dart';

Future<void> main(List<String> args) async {
  final which = args.isEmpty ? 'large' : args[0];
  final runs = args.length > 1 ? int.parse(args[1]) : 3;
  final workers = args.length > 2 ? int.parse(args[2]) : 1;
  final String schema;
  final int documents;
  if (which == 'magento') {
    final dir = Directory(
      p.join(
        p.dirname(Platform.script.toFilePath()),
        '..',
        '.dart_tool',
        'gqlify_benchmark',
        'magento',
      ),
    );
    schema = mergeMagentoSchema(dir);
    documents = 60;
  } else {
    schema = syntheticSchema(types: which == 'large' ? 400 : 60);
    documents = which == 'large' ? 200 : 40;
  }
  final model = loadSchema([
    GqlifySource('lib/schema.graphql', schema),
  ], DiagnosticSink())!;
  final docs = OperationGenerator(model, Random(which == 'magento' ? 7 : 1))
      .generate(
        documents: documents,
        operationsPerDocument: 5,
        fragments: which == 'large' ? 120 : 60,
      );
  final input = GenerationInput(
    config: GqlifyConfig(schema: ['lib/schema.graphql']),
    schema: [GqlifySource('lib/schema.graphql', schema)],
    documents: [
      for (final MapEntry(:key, :value) in docs.entries)
        GqlifySource(key, value),
    ],
  );
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    final result = workers == 1
        ? GqlifyEngine().generate(input)
        : await GqlifyEngine().generateAsync(input, concurrency: workers);
    final total = sw.elapsedMilliseconds;
    final bytes = result.outputs.values.fold(0, (n, o) => n + o.length);
    stdout.writeln(
      'run $i: $total ms, ${result.outputs.length} outputs, '
      '${(bytes / 1024).toStringAsFixed(0)} KiB, errors ${result.hasErrors}; '
      '${result.timings.entries.map((e) => '${e.key} ${e.value.inMilliseconds}').join(', ')}',
    );
  }
  stdout.writeln(
    'peak RSS ${(ProcessInfo.maxRss / 1024 / 1024).toStringAsFixed(0)} MiB',
  );
}
