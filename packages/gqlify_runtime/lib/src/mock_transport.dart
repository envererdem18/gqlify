import 'dart:async';

import 'request.dart';
import 'transport.dart';

/// Produces a raw GraphQL response body for a request.
typedef MockHandler = FutureOr<Map<String, Object?>> Function(
    GqlifyRequest request);

/// An in-memory [GqlifyTransport] for tests and examples.
///
/// Records every request in [requests]. The handler may throw (for example a
/// `GqlifyTransportException`) to simulate transport failures.
final class MockTransport implements GqlifyTransport {
  MockTransport(this.handler);

  /// Always answers with [body].
  MockTransport.fixed(Map<String, Object?> body) : handler = ((_) => body);

  final MockHandler handler;
  final List<GqlifyRequest> requests = [];
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  Future<Map<String, Object?>> send(GqlifyRequest request) async {
    if (_closed) throw StateError('MockTransport is closed');
    requests.add(request);
    return handler(request);
  }

  @override
  Future<void> close() async => _closed = true;
}
