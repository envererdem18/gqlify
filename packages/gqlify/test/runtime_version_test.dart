import 'package:gqlify/src/runtime_version.dart';
import 'package:test/test.dart';

String lock(String version) =>
    '''
packages:
  gqlify_runtime:
    dependency: "direct main"
    source: hosted
    version: "$version"
''';

void main() {
  test('accepts the same minor version and warns otherwise', () {
    expect(checkRuntimeVersion(lock('0.1.0')), isNull);
    expect(checkRuntimeVersion(lock('0.1.7')), isNull);
    expect(checkRuntimeVersion(lock('0.1.0-dev.2'))?.code, 'runtime-version');
    expect(checkRuntimeVersion(lock('0.2.0'))?.code, 'runtime-version');
    expect(checkRuntimeVersion('packages: {}'), isNull);
    expect(checkRuntimeVersion(null), isNull);
    expect(checkRuntimeVersion(': not yaml :'), isNull);
  });
}
