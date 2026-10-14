@Tags(['differential'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

import 'support/sandbox.dart';
import 'support/synthetic.dart';

/// Property: for any sequence of edits, incremental generation equals clean
/// generation after every step (`edit -> generate -> compare -> repeat`),
/// including when the cache or outputs are disturbed between steps.
///
/// More seeds: `GQLIFY_FUZZ_SEEDS=1-200 dart test test/cache_fuzz_test.dart`.
void main() {
  for (final seed in _seeds()) {
    test('random edit sequence (seed $seed)', () async {
      final random = Random(seed);
      final project = SyntheticProject(random: random);
      final sandbox = Sandbox();
      final documents = <String>{};
      final log = <String>[];
      var successes = 0;
      var hits = 0;
      try {
        project.writeTo(sandbox, documents);
        var failedLast = false;
        for (var step = 0; step < 14; step++) {
          final description = step == 0
              ? 'initial'
              : failedLast && random.nextInt(3) > 0
              ? project.repair()
              : project.mutate();
          project.writeTo(sandbox, documents);
          log.add(description);
          final args = <String>[];
          switch (random.nextInt(10)) {
            case 0: // Disturb the cache.
              final manifest = File(
                sandbox.path('.dart_tool/gqlify/manifest.json'),
              );
              if (manifest.existsSync()) {
                manifest.writeAsStringSync('{"format": 1, "gener');
              }
              log.add('  + corrupt manifest');
            case 1: // Delete or edit a generated file.
              final outputs = sandbox.generatedFiles().keys.toList();
              if (outputs.isNotEmpty) {
                final victim = outputs[random.nextInt(outputs.length)];
                if (random.nextBool()) {
                  sandbox.delete(victim);
                } else {
                  sandbox.write(victim, '${sandbox.read(victim)}// edit\n');
                }
                log.add('  + disturb $victim');
              }
            case 2:
              args.add('--clean');
              log.add('  + --clean');
          }
          final result = await expectMatchesClean(
            sandbox,
            args: args,
            reason: 'seed $seed, steps:\n${log.join('\n')}',
          );
          failedLast = result.exitCode != 0;
          if (result.exitCode == 0) successes++;
          if ((result.report['cache'] as String? ?? '').startsWith('hit')) {
            hits++;
          }
          // Re-running without changes is always a verified no-op.
          if (result.exitCode == 0) {
            final again = await sandbox.run(['generate']);
            expect(
              again.report['cache'],
              startsWith('hit'),
              reason: log.join('\n'),
            );
            expect(again.outputs, result.outputs);
          }
        }
        printOnFailure(
          'seed $seed: $successes successful steps, $hits cache hits',
        );
        // The sequence must exercise successful (incremental) generation, not
        // only error paths.
        expect(successes, greaterThanOrEqualTo(4), reason: log.join('\n'));
        if (Platform.environment['GQLIFY_FUZZ_STATS'] == '1') {
          print('seed $seed: $successes/14 successful steps, $hits warm hits');
        }
      } finally {
        sandbox.dispose();
      }
    });
  }

  test('large fixture: hundreds of operations, many fragments', () async {
    final project = SyntheticProject(
      random: Random(42),
      types: 40,
      fragments: 40,
      documents: 40,
      operationsPerDocument: 6,
    );
    final sandbox = Sandbox();
    final documents = <String>{};
    try {
      project.writeTo(sandbox, documents);
      final cold = await expectMatchesClean(sandbox, reason: 'cold');
      expect(cold.exitCode, 0, reason: cold.diagnostics.toString());
      expect(cold.outputs.length, greaterThan(40));

      final warm = await sandbox.run(['generate']);
      expect(warm.report['cache'], startsWith('hit'));

      project.fragments['F3'] = (project.fragments['F3']!.$1, 'id name');
      project.writeTo(sandbox, documents);
      await expectMatchesClean(sandbox, reason: 'shared fragment changed');

      project.typeFields['T0']!['name'] = 'String!';
      project.writeTo(sandbox, documents);
      await expectMatchesClean(sandbox, reason: 'schema changed');
    } finally {
      sandbox.dispose();
    }
  });
}

List<int> _seeds() {
  final spec = Platform.environment['GQLIFY_FUZZ_SEEDS'];
  if (spec == null) return [1, 2, 3, 4];
  final [from, to] = spec.contains('-')
      ? spec.split('-').map(int.parse).toList()
      : [int.parse(spec), int.parse(spec)];
  return [for (var s = from; s <= to; s++) s];
}
