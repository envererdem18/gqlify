import 'package:gqlify_runtime/testing.dart';
import 'package:test/test.dart';

import 'fixtures/edge_cases/operations.graphql.dart';
import 'fixtures/edge_cases/schema.graphql.dart';

void main() {
  test('escaped names, nested lists and conditional fields decode', () async {
    final transport = MockTransport.fixed({
      'data': {
        'item': {
          'class': 1,
          'toJson': 't',
          'hashCode': 2,
          'in': 'i',
          'alias': 3,
          'matrix': [
            [1, 2.5],
            null,
          ],
          'sparse': [
            [
              {'in': 'a', 'sparse': null},
              null,
            ],
          ],
          'meta': {
            'any': ['json'],
          },
          'described': null,
          'kept': 'k',
          // 'skipped' omitted: excluded by @skip.
        },
      },
    });
    final api = GqlifyClient(transport: transport);

    final item = (await api.reservedWords($in: 'x', ids: ['1'])).item!;

    expect(item.$class, 1);
    expect(item.$toJson, 't');
    expect(item.$hashCode, 2);
    expect(item.$in, 'i');
    expect(item.alias, 3);
    expect(item.matrix, [
      [1.0, 2.5],
      null,
    ]);
    expect(item.sparse!.single!.first!.$in, 'a');
    expect(item.meta, {
      'any': ['json'],
    });
    expect(item.skipped, isNull);
    expect(item.kept, 'k');
    expect(transport.requests.single.variables, {
      'in': 'x',
      'ids': ['1'],
    });
    expect(item.toJson()['class'], 1);
    expect(item.toString(), contains(r'$class: 1'));
  });
}
