import 'package:gqlify/gqlify.dart';
import 'package:gqlify/src/schema/legacy_sdl.dart';
import 'package:gqlify/src/schema/sdl_builder.dart';
import 'package:gqlify/src/schema/schema.dart';
import 'package:test/test.dart';

void main() {
  test('rewrites comma- and space-separated interface lists in place', () {
    expect(
      normalizeLegacyImplements('type A implements B, C, D { x: Int }'),
      'type A implements B& C& D { x: Int }',
    );
    expect(
      normalizeLegacyImplements('type A implements B C @d { x: Int }'),
      'type A implements B&C @d { x: Int }',
    );
    expect(
      normalizeLegacyImplements('type A implements B,C\n{ x: Int }'),
      'type A implements B&C\n{ x: Int }',
    );
    expect(
      normalizeLegacyImplements('type A implements & B & C { x: Int }'),
      'type A implements & B & C { x: Int }',
    );
    expect(
      normalizeLegacyImplements(
        'type A implements B { x: Int }\ntype C { y: Int }',
      ),
      'type A implements B { x: Int }\ntype C { y: Int }',
    );
  });

  test('never touches strings, block strings or comments', () {
    const sdl = '''
"implements A, B"
type A implements B, C {
  """
  implements X, Y
  """
  x: Int # implements P, Q
}''';
    final out = normalizeLegacyImplements(sdl);
    expect(out.length, sdl.length);
    expect(out, contains('"implements A, B"'));
    expect(out, contains('implements X, Y'));
    expect(out, contains('# implements P, Q'));
    expect(out, contains('type A implements B& C {'));
  });

  test('legacy schemas load with correct interfaces and positions', () {
    final sink = DiagnosticSink();
    final schema = parseSchema('''
interface B { id: ID! }
interface C { id: ID! }
type Query implements B, C { id: ID! a: Nope }
''', sink);
    expect(schema, isNull);
    // Position of the unknown type is unchanged by the rewrite.
    expect(sink.sorted().single.toString(), contains('schema.graphql:3:38'));

    final ok = parseSchema(
      'interface B { id: ID! } interface C { id: ID! } type Query implements B, C { id: ID! }',
      DiagnosticSink(),
    )!;
    expect((ok['Query']! as ObjectType).interfaces, ['B', 'C']);
  });
}
