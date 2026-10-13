import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'package:gqlify_runtime/internal.dart';
import 'package:gqlify_runtime/testing.dart';
import 'package:test/test.dart';

/// Hand-written equivalent of a generated operation.
final class _NameQuery extends GqlifyOperation<String> {
  const _NameQuery();

  @override
  String get operationName => 'Name';

  @override
  GqlifyOperationType get operationType => GqlifyOperationType.query;

  @override
  String get document => 'query Name { name }';

  @override
  Map<String, Object?> get variables => const {};

  @override
  String parseData(Map<String, Object?> data) =>
      gqlifyRead<String>(data, 'name', 'NameData');
}

final class _Client extends GqlifyClientBase {
  _Client(GqlifyTransport transport) : super(transport: transport);
}

void main() {
  Future<GqlifyResponse<String>> run(Map<String, Object?> body) =>
      _Client(MockTransport.fixed(body)).execute(const _NameQuery());

  test('decodes data', () async {
    final response = await run({
      'data': {'name': 'x'},
      'extensions': {'cost': 1}
    });
    expect(response.data, 'x');
    expect(response.hasErrors, isFalse);
    expect(response.extensions, {'cost': 1});
    expect(response.dataOrThrow, 'x');
  });

  test('keeps partial data and errors; dataOrThrow throws', () async {
    final response = await run({
      'data': {'name': 'x'},
      'errors': [
        {
          'message': 'partial',
          'path': ['other', 0],
          'locations': [
            {'line': 1, 'column': 2}
          ],
          'extensions': {'code': 'E'},
        },
      ],
    });
    expect(response.data, 'x');
    final error = response.errors.single;
    expect(error.message, 'partial');
    expect(error.path, ['other', 0]);
    expect(error.locations, [const GraphQLErrorLocation(1, 2)]);
    expect(error.extensions, {'code': 'E'});
    expect(
      () => response.dataOrThrow,
      throwsA(
          isA<GraphQLResponseException>().having((e) => e.data, 'data', 'x')),
    );
  });

  test('errors without data', () async {
    final response = await run({
      'data': null,
      'errors': [
        {'message': 'boom'}
      ]
    });
    expect(response.data, isNull);
    expect(
        () => response.dataOrThrow, throwsA(isA<GraphQLResponseException>()));
  });

  test('rejects responses without data and errors', () async {
    await expectLater(run({}), throwsA(isA<GqlifyDecodingException>()));
  });

  test('decoding failures throw without errors', () async {
    await expectLater(
      run({
        'data': {'name': 1}
      }),
      throwsA(isA<GqlifyDecodingException>().having((e) => e.message, 'message',
          contains('Expected String at NameData.name, got int'))),
    );
    await expectLater(
      run({'data': <String, Object?>{}}),
      throwsA(isA<GqlifyDecodingException>().having((e) => e.message, 'message',
          contains('Missing required field NameData.name'))),
    );
  });

  test('decoding failures alongside errors are reported, not thrown', () async {
    final response = await run({
      'data': {'name': null},
      'errors': [
        {'message': 'name failed'}
      ],
    });
    expect(response.data, isNull);
    expect(response.dataDecodingError, isA<GqlifyDecodingException>());
    expect(
        () => response.dataOrThrow, throwsA(isA<GraphQLResponseException>()));
  });

  test('malformed errors stay visible', () {
    expect(GraphQLError.fromJson('oops').message, contains('Malformed'));
    expect(GraphQLError.fromJson(<String, Object?>{}).message,
        contains('without message'));
  });

  test('request options reach the transport', () async {
    final transport = MockTransport.fixed({
      'data': {'name': 'x'}
    });
    await _Client(transport).execute(
      const _NameQuery(),
      options: const GqlifyRequestOptions(
        headers: {'a': 'b'},
        timeout: Duration(seconds: 1),
      ),
    );
    final request = transport.requests.single;
    expect(request.headers, {'a': 'b'});
    expect(request.timeout, const Duration(seconds: 1));
    expect(request.toJson(),
        {'query': 'query Name { name }', 'operationName': 'Name'});
  });

  test('codec helpers', () {
    expect(gqlifyReadDouble({'f': 1}, 'f', 'T'), 1.0);
    expect(gqlifyReadDoubleOrNull({'f': null}, 'f', 'T'), isNull);
    expect(gqlifyCastDouble(2, 'T.l[]'), 2.0);
    expect(() => gqlifyCast<String>(1, 'T.l[]'),
        throwsA(isA<GqlifyDecodingException>()));
    expect(
        gqlifyDeepEquals([
          [1],
          [2]
        ], [
          [1],
          [2]
        ]),
        isTrue);
    expect(
        gqlifyDeepEquals([
          [1]
        ], [
          [2]
        ]),
        isFalse);
    expect(
        gqlifyDeepHash([
          [1],
          [2]
        ]),
        gqlifyDeepHash([
          [1],
          [2]
        ]));
  });
}
