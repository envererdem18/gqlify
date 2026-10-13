import 'package:gql/ast.dart' as ast;

/// Prints executable GraphQL in a compact canonical form.
///
/// `package:gql`'s printer does not re-escape string values (a parsed
/// `"a\"b"` would print as `"a"b"`), so gqlify embeds documents printed by
/// this printer instead. Output depends only on the AST, never on source
/// formatting or comments.
String printExecutable(ast.Node node) {
  final out = StringBuffer();
  _Printer(out).node(node);
  return out.toString();
}

final class _Printer {
  _Printer(this.out);

  final StringBuffer out;

  void node(ast.Node n) {
    switch (n) {
      case ast.OperationDefinitionNode():
        out.write(n.type.name);
        if (n.name != null) out.write(' ${n.name!.value}');
        if (n.variableDefinitions.isNotEmpty) {
          out.write('(');
          _join(n.variableDefinitions, ', ', node);
          out.write(')');
        }
        _directives(n.directives);
        out.write(' ');
        node(n.selectionSet);
      case ast.FragmentDefinitionNode():
        out.write(
          'fragment ${n.name.value} on ${n.typeCondition.on.name.value}',
        );
        _directives(n.directives);
        out.write(' ');
        node(n.selectionSet);
      case ast.VariableDefinitionNode():
        out.write('\$${n.variable.name.value}: ');
        node(n.type);
        final defaultValue = n.defaultValue?.value;
        if (defaultValue != null) {
          out.write(' = ');
          node(defaultValue);
        }
        _directives(n.directives);
      case ast.SelectionSetNode():
        out.write('{ ');
        _join(n.selections, ' ', node);
        out.write(' }');
      case ast.FieldNode():
        if (n.alias != null) out.write('${n.alias!.value}: ');
        out.write(n.name.value);
        _arguments(n.arguments);
        _directives(n.directives);
        if (n.selectionSet != null) {
          out.write(' ');
          node(n.selectionSet!);
        }
      case ast.FragmentSpreadNode():
        out.write('...${n.name.value}');
        _directives(n.directives);
      case ast.InlineFragmentNode():
        out.write('...');
        if (n.typeCondition != null) {
          out.write(' on ${n.typeCondition!.on.name.value}');
        }
        _directives(n.directives);
        out.write(' ');
        node(n.selectionSet);
      case ast.ArgumentNode():
        out.write('${n.name.value}: ');
        node(n.value);
      case ast.DirectiveNode():
        out.write('@${n.name.value}');
        _arguments(n.arguments);
      case ast.NamedTypeNode():
        out.write(n.name.value);
        if (n.isNonNull) out.write('!');
      case ast.ListTypeNode():
        out.write('[');
        node(n.type);
        out.write(']');
        if (n.isNonNull) out.write('!');
      case ast.VariableNode():
        out.write('\$${n.name.value}');
      case ast.IntValueNode():
        out.write(n.value);
      case ast.FloatValueNode():
        out.write(n.value);
      case ast.StringValueNode():
        out.write(quoteGraphQLString(n.value));
      case ast.BooleanValueNode():
        out.write(n.value ? 'true' : 'false');
      case ast.NullValueNode():
        out.write('null');
      case ast.EnumValueNode():
        out.write(n.name.value);
      case ast.ListValueNode():
        out.write('[');
        _join(n.values, ', ', node);
        out.write(']');
      case ast.ObjectValueNode():
        out.write('{');
        _join(n.fields, ', ', node);
        out.write('}');
      case ast.ObjectFieldNode():
        out.write('${n.name.value}: ');
        node(n.value);
      default:
        throw ArgumentError(
          'Cannot print ${n.runtimeType} as executable GraphQL',
        );
    }
  }

  void _arguments(List<ast.ArgumentNode> args) {
    if (args.isEmpty) return;
    out.write('(');
    _join(args, ', ', node);
    out.write(')');
  }

  void _directives(List<ast.DirectiveNode> directives) {
    for (final d in directives) {
      out.write(' ');
      node(d);
    }
  }

  void _join<T extends ast.Node>(
    List<T> items,
    String sep,
    void Function(T) f,
  ) {
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.write(sep);
      f(items[i]);
    }
  }
}

/// Quotes [value] as a GraphQL string literal.
String quoteGraphQLString(String value) {
  final out = StringBuffer('"');
  for (final c in value.runes) {
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      default:
        if (c < 0x20) {
          out.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.write('"');
  return out.toString();
}
