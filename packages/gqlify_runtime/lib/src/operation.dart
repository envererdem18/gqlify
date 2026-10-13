/// The kind of a GraphQL operation.
enum GqlifyOperationType { query, mutation, subscription }

/// A fully described, ready-to-send GraphQL operation.
///
/// gqlify generates one subclass per operation (for example `GetProductQuery`)
/// holding the operation's variables. Instances are immutable and can be
/// executed with [GqlifyClientBase.execute] when the full response or
/// per-request options are needed.
abstract class GqlifyOperation<TData> {
  const GqlifyOperation();

  /// The operation name as written in the GraphQL document.
  String get operationName;

  GqlifyOperationType get operationType;

  /// The complete GraphQL document: the operation and every fragment it
  /// transitively uses. Embedded at build time; never read at runtime.
  String get document;

  /// JSON-encodable variables. Optional variables that were not provided are
  /// omitted (so server-side defaults apply); generated operations offer
  /// `withNull(...)` to send an explicit `null` instead.
  Map<String, Object?> get variables;

  /// Decodes the `data` member of a GraphQL response.
  TData parseData(Map<String, Object?> data);
}
