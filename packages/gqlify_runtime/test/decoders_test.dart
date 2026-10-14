import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'package:gqlify_runtime/internal.dart';
import 'package:test/test.dart';

enum Color { red, $unknown }

final class Item {
  Item(this.tags, this.color, this.price);

  factory Item.fromJson(Map<String, Object?> json) => Item(
        gqlifyField(json, 'tags',
            const GqlifyNullable(GqlifyList(GqlifyNullable(gqlifyString)))),
        gqlifyField(json, 'color', const GqlifyEnum(_color)),
        gqlifyField(json, 'price', gqlifyDouble),
      );

  final List<String?>? tags;
  final Color color;
  final double price;
}

Color _color(String json) => json == 'RED' ? Color.red : Color.$unknown;

String failure(Object? json) {
  try {
    gqlifyDecodeRoot(() => gqlifyField({'items': json}, 'items',
        const GqlifyList(GqlifyObject(Item.fromJson))));
  } on GqlifyDecodingException catch (e) {
    return e.message;
  }
  return 'no failure';
}

void main() {
  test('decodes nested values', () {
    final items = gqlifyField(
      {
        'items': [
          {
            'tags': ['a', null],
            'color': 'RED',
            'price': 2
          },
        ],
      },
      'items',
      const GqlifyList(GqlifyObject(Item.fromJson)),
    );
    expect(items.single.tags, ['a', null]);
    expect(items.single.color, Color.red);
    expect(items.single.price, 2.0);
  });

  test('reports the response path of failures', () {
    expect(
        failure([
          {'color': 'RED', 'price': 1},
          {'color': 'RED'}
        ]),
        'Missing required field items[1].price (expected double)');
    expect(
        failure([
          {
            'tags': [1],
            'color': 'RED',
            'price': 1
          }
        ]),
        'Expected String at items[0].tags[0], got int');
    expect(
        failure([
          {'color': 3, 'price': 1}
        ]),
        'Expected enum value at items[0].color, got int');
    expect(failure('nope'), 'Expected List at items, got String');
  });

  test('conversion failures carry their cause', () {
    const decoder = GqlifyConvert<String, DateTime>(DateTime.parse, 'DateTime');
    try {
      gqlifyDecodeRoot(() => gqlifyField({'at': 'yesterday'}, 'at', decoder));
      fail('expected an exception');
    } on GqlifyDecodingException catch (e) {
      expect(e.message,
          startsWith('Cannot decode DateTime at at: FormatException'));
    }
  });
}
