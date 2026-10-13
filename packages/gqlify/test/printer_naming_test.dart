import 'package:gql/language.dart' as lang;
import 'package:gqlify/src/documents/printer.dart';
import 'package:gqlify/src/emit/naming.dart';
import 'package:test/test.dart';

void main() {
  group('printExecutable', () {
    test('round-trips through the parser, including string escapes', () {
      const source = r'''
        query Q($a: [Int!]! = [1, 2], $b: In = {x: "q\"uo\\te\n", y: null, z: ENUM}) @dir(a: 1.5) {
          alias: field(arg: $a, s: """block "string" """) @include(if: true) {
            ...F
            ... on T { x }
            ... @skip(if: false) { y }
          }
        }
        fragment F on T { id }
      ''';
      final doc = lang.parseString(source);
      final printed = doc.definitions.map(printExecutable).join('\n');
      final reparsed = lang.parseString(printed);
      expect(reparsed.definitions.map(printExecutable).join('\n'), printed);
      expect(printed, contains(r'"q\"uo\\te\n"'));
      expect(printed, contains(r'"block \"string\" "'));
      expect(
        printed,
        startsWith(
          r'query Q($a: [Int!]! = [1, 2], $b: In = {x: "q\"uo\\te\n", y: null, z: ENUM}) @dir(a: 1.5) { alias: field',
        ),
      );
    });

    test('escapes control characters', () {
      expect(quoteGraphQLString('a\u0001b\tc'), r'"a\u0001b\tc"');
    });
  });

  group('naming', () {
    test('camelCase', () {
      expect(camelCase('stock_quantity'), 'stockQuantity');
      expect(camelCase('priceRange'), 'priceRange');
      expect(camelCase('URL'), 'url');
      expect(camelCase('SKU_code'), 'skuCode');
      expect(camelCase('__typename'), 'typename');
      expect(camelCase('address_2'), 'address2');
    });

    test('pascalCase', () {
      expect(pascalCase('getProduct'), 'GetProduct');
      expect(pascalCase('get_product'), 'GetProduct');
      expect(pascalCase('GetProduct'), 'GetProduct');
    });

    test('escaping', () {
      expect(escapeMember('class'), r'$class');
      expect(escapeMember('await'), r'$await');
      expect(escapeMember('type'), 'type');
      expect(escapeMember('toJson', {'toJson'}), r'$toJson');
      expect(escapeType('Object'), r'Object$');
      expect(escapeType('Function'), r'Function$');
      expect(escapeType('Product'), 'Product');
    });

    test('dartString escapes interpolation and quotes', () {
      expect(
        dartString(
          r"it's $x \ y"
          '\n',
        ),
        r"'it\'s \$x \\ y\n'",
      );
    });
  });
}
