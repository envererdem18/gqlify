import 'dart:io';

import 'package:gql/ast.dart' as ast;
import 'package:gql/language.dart' as lang;
import 'package:gqlify/src/documents/printer.dart';
import 'package:gqlify/src/schema/legacy_sdl.dart';
import 'package:path/path.dart' as p;

/// Merges Magento's per-module `schema.graphqls` files into one standard SDL
/// document, emulating Magento's own loader: definitions with the same name
/// are merged (fields/values/members/interfaces), later fields override
/// earlier ones, and Magento-specific directives (`@doc`, `@resolver`, ...)
/// are dropped. Benchmark input preparation only; not a gqlify feature.
String mergeMagentoSchema(Directory dir) {
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.graphqls'))
          .toList()
        ..sort((a, b) {
          // The base GraphQl module first, like Magento.
          int rank(File f) => p.basename(f.path) == 'GraphQl.graphqls' ? 0 : 1;
          final r = rank(a) - rank(b);
          return r != 0 ? r : a.path.compareTo(b.path);
        });
  final types = <String, _Type>{};
  for (final file in files) {
    final doc = lang.parseString(
      normalizeLegacyImplements(file.readAsStringSync()),
    );
    for (final def in doc.definitions) {
      final name = switch (def) {
        ast.TypeDefinitionNode(:final name) => name.value,
        ast.TypeExtensionNode(:final name) => name.value,
        _ => null,
      };
      if (name == null) continue;
      final kind = switch (def) {
        ast.ObjectTypeDefinitionNode() ||
        ast.ObjectTypeExtensionNode() => 'type',
        ast.InterfaceTypeDefinitionNode() ||
        ast.InterfaceTypeExtensionNode() => 'interface',
        ast.InputObjectTypeDefinitionNode() ||
        ast.InputObjectTypeExtensionNode() => 'input',
        ast.EnumTypeDefinitionNode() || ast.EnumTypeExtensionNode() => 'enum',
        ast.UnionTypeDefinitionNode() ||
        ast.UnionTypeExtensionNode() => 'union',
        ast.ScalarTypeDefinitionNode() ||
        ast.ScalarTypeExtensionNode() => 'scalar',
        _ => null,
      };
      if (kind == null) continue;
      final type = types.putIfAbsent(name, () => _Type(kind, name));
      switch (def) {
        case ast.ObjectTypeDefinitionNode(:final fields, :final interfaces) ||
            ast.ObjectTypeExtensionNode(:final fields, :final interfaces):
          type.add(fields, interfaces);
        case ast.InterfaceTypeDefinitionNode(
              :final fields,
              :final interfaces,
            ) ||
            ast.InterfaceTypeExtensionNode(:final fields, :final interfaces):
          type.add(fields, interfaces);
        case ast.InputObjectTypeDefinitionNode(:final fields) ||
            ast.InputObjectTypeExtensionNode(:final fields):
          for (final f in fields) {
            type.inputs[f.name.value] = f;
          }
        case ast.EnumTypeDefinitionNode(:final values) ||
            ast.EnumTypeExtensionNode(:final values):
          for (final v in values) {
            type.values[v.name.value] = v;
          }
        case ast.UnionTypeDefinitionNode(:final types) ||
            ast.UnionTypeExtensionNode(:final types):
          type.members.addAll(types.map((t) => t.name.value));
        default:
          break;
      }
    }
  }
  // Magento copies interface fields into implementing types.
  void inherit(_Type type, Set<String> seen) {
    for (final name in type.interfaces.toList()) {
      final iface = types[name];
      if (iface == null || !seen.add(name)) continue;
      inherit(iface, seen);
      type.interfaces.addAll(iface.interfaces);
      for (final MapEntry(:key, :value) in iface.fields.entries) {
        type.fields.putIfAbsent(key, () => value);
      }
    }
  }

  for (final type in types.values) {
    inherit(type, {});
  }
  final out = StringBuffer();
  for (final type in types.values) {
    type.write(out);
  }
  return out.toString();
}

final class _Type {
  _Type(this.kind, this.name);

  final String kind;
  final String name;
  final Map<String, ast.FieldDefinitionNode> fields = {};
  final Map<String, ast.InputValueDefinitionNode> inputs = {};
  final Map<String, ast.EnumValueDefinitionNode> values = {};
  final Set<String> interfaces = {};
  final Set<String> members = {};

  void add(
    List<ast.FieldDefinitionNode> fields,
    List<ast.NamedTypeNode> interfaces,
  ) {
    for (final f in fields) {
      this.fields[f.name.value] = f;
    }
    this.interfaces.addAll(interfaces.map((i) => i.name.value));
  }

  void write(StringBuffer out) {
    String deprecated(List<ast.DirectiveNode> directives) {
      for (final d in directives) {
        if (d.name.value != 'deprecated') continue;
        final reason = d.arguments
            .where((a) => a.name.value == 'reason')
            .firstOrNull
            ?.value;
        return reason == null
            ? ' @deprecated'
            : ' @deprecated(reason: ${printExecutable(reason)})';
      }
      return '';
    }

    String input(ast.InputValueDefinitionNode v) =>
        '${v.name.value}: ${printExecutable(v.type)}'
        '${v.defaultValue == null ? '' : ' = ${printExecutable(v.defaultValue!)}'}'
        '${deprecated(v.directives)}';

    switch (kind) {
      case 'scalar':
        out.writeln('scalar $name');
      case 'union':
        out.writeln('union $name = ${members.join(' | ')}');
      case 'enum':
        out.writeln(
          'enum $name { ${[for (final v in values.values) '${v.name.value}${deprecated(v.directives)}'].join(' ')} }',
        );
      case 'input':
        out.writeln('input $name { ${inputs.values.map(input).join(' ')} }');
      default:
        final impl = interfaces.isEmpty
            ? ''
            : ' implements ${interfaces.join(' & ')}';
        out.writeln('$kind $name$impl {');
        for (final f in fields.values) {
          final args = f.args.isEmpty
              ? ''
              : '(${f.args.map(input).join(', ')})';
          out.writeln(
            '  ${f.name.value}$args: ${printExecutable(f.type)}${deprecated(f.directives)}',
          );
        }
        out.writeln('}');
    }
  }
}
