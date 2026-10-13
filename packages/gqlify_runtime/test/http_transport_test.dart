import 'dart:async';
import 'dart:convert';

import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _request = GqlifyRequest(
  operationName: 'Op',
  operationType: GqlifyOperationType.query,
  document: 'query Op { a }',
  variables: {'x': 1},
  headers: {'x-request': 'r', 'x-override': 'request'},
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  test('posts a GraphQL-over-HTTP body and returns the decoded response',
      () async {
    late http.Request sent;
    final transport = HttpTransport(
      Uri.parse('https://example.com/graphql'),
      client: MockClient((r) async {
        sent = r;
        return _json({
          'data': {'a': 1}
        });
      }),
      headers: {'x-default': 'd', 'x-override': 'default'},
      headersBuilder: (_) => {'authorization': 'Bearer t'},
    );

    final body = await transport.send(_request);

    expect(body, {
      'data': {'a': 1}
    });
    expect(sent.method, 'POST');
    expect(jsonDecode(sent.body), {
      'query': 'query Op { a }',
      'operationName': 'Op',
      'variables': {'x': 1},
    });
    expect(sent.headers['content-type'], startsWith('application/json'));
    expect(sent.headers['x-default'], 'd');
    expect(sent.headers['authorization'], 'Bearer t');
    expect(sent.headers['x-request'], 'r');
    expect(sent.headers['x-override'], 'request');
  });

  test('returns GraphQL bodies of non-2xx responses', () async {
    final transport = HttpTransport(
      Uri.parse('https://example.com/graphql'),
      client: MockClient((_) async => _json({
            'errors': [
              {'message': 'bad'}
            ],
          }, 400)),
    );
    expect(await transport.send(_request), {
      'errors': [
        {'message': 'bad'}
      ],
    });
  });

  test('throws GqlifyTransportException for HTTP errors without GraphQL body',
      () async {
    final transport = HttpTransport(
      Uri.parse('https://example.com/graphql'),
      client: MockClient((_) async => http.Response('Bad gateway', 502)),
    );
    await expectLater(
      transport.send(_request),
      throwsA(isA<GqlifyTransportException>()
          .having((e) => e.statusCode, 'statusCode', 502)
          .having((e) => e.body, 'body', 'Bad gateway')),
    );
  });

  test('throws GqlifyDecodingException for invalid JSON with 200', () async {
    final transport = HttpTransport(
      Uri.parse('https://example.com/graphql'),
      client: MockClient((_) async => http.Response('<html>', 200)),
    );
    await expectLater(
        transport.send(_request), throwsA(isA<GqlifyDecodingException>()));
  });

  test('wraps network failures', () async {
    final transport = HttpTransport(
      Uri.parse('https://example.com/graphql'),
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    await expectLater(
      transport.send(_request),
      throwsA(isA<GqlifyTransportException>()
          .having((e) => e.cause, 'cause', isA<http.ClientException>())),
    );
  });

  test('enforces the timeout', () async {
    final never = Completer<http.Response>();
    final transport = HttpTransport(
      Uri.parse('https://example.com/graphql'),
      client: MockClient((_) => never.future),
      timeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      transport.send(_request),
      throwsA(isA<GqlifyTransportException>()
          .having((e) => e.message, 'message', contains('timed out'))),
    );
  });
}
