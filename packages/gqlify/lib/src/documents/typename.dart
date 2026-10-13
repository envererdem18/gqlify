import 'package:gql/ast.dart' as ast;

import '../schema/schema.dart';
import 'document_set.dart';

/// Returns [documents] with `__typename` selected in every selection set on an
/// interface or union type (fields and fragment definitions).
///
/// Generated code decodes polymorphic results by `__typename`, so it must be
/// present in the request. Run on validated documents; the originals stay
/// untouched for diagnostics.
DocumentSet addTypenames(Schema schema, DocumentSet documents) {
  final transformer = _TypenameTransformer(schema);
  return DocumentSet([
    for (final doc in documents.documents)
      ParsedDocument(
        doc.path,
        ast.DocumentNode(
          definitions: [
            for (final def in doc.node.definitions) transformer.definition(def),
          ],
          span: doc.node.span,
        ),
      ),
  ]);
}

const _typename = ast.FieldNode(name: ast.NameNode(value: '__typename'));

final class _TypenameTransformer {
  _TypenameTransformer(this.schema);

  final Schema schema;

  ast.DefinitionNode definition(ast.DefinitionNode def) {
    switch (def) {
      case ast.OperationDefinitionNode():
        final root = schema[schema.rootTypeName(def.type) ?? ''];
        if (root == null) return def;
        return ast.OperationDefinitionNode(
          type: def.type,
          name: def.name,
          variableDefinitions: def.variableDefinitions,
          directives: def.directives,
          selectionSet: _set(def.selectionSet, root),
          span: def.span,
        );
      case ast.FragmentDefinitionNode():
        final type = schema[def.typeCondition.on.name.value];
        if (type == null) return def;
        return ast.FragmentDefinitionNode(
          name: def.name,
          typeCondition: def.typeCondition,
          directives: def.directives,
          selectionSet: _set(
            def.selectionSet,
            type,
            addTypename: type.isAbstract,
          ),
          span: def.span,
        );
      default:
        return def;
    }
  }

  ast.SelectionSetNode _set(
    ast.SelectionSetNode set,
    SchemaType parent, {
    bool addTypename = false,
  }) {
    final selections = <ast.SelectionNode>[
      if (addTypename && !_hasTypename(set)) _typename,
    ];
    for (final selection in set.selections) {
      switch (selection) {
        case ast.FieldNode(selectionSet: final childSet?):
          final type =
              schema[schema
                      .field(parent, selection.name.value)
                      ?.type
                      .namedType ??
                  ''];
          selections.add(
            type == null
                ? selection
                : ast.FieldNode(
                    alias: selection.alias,
                    name: selection.name,
                    arguments: selection.arguments,
                    directives: selection.directives,
                    selectionSet: _set(
                      childSet,
                      type,
                      addTypename: type.isAbstract,
                    ),
                    span: selection.span,
                  ),
          );
        case ast.InlineFragmentNode():
          final type = selection.typeCondition == null
              ? parent
              : schema[selection.typeCondition!.on.name.value] ?? parent;
          selections.add(
            ast.InlineFragmentNode(
              typeCondition: selection.typeCondition,
              directives: selection.directives,
              selectionSet: _set(selection.selectionSet, type),
              span: selection.span,
            ),
          );
        default:
          selections.add(selection);
      }
    }
    return ast.SelectionSetNode(selections: selections, span: set.span);
  }

  static bool _hasTypename(ast.SelectionSetNode set) => set.selections.any(
    (s) =>
        s is ast.FieldNode && s.alias == null && s.name.value == '__typename',
  );
}
