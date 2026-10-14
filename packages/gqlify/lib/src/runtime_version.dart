import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'diagnostics.dart';

/// Oldest `gqlify_runtime` providing everything this generator's output uses.
final minimumRuntimeVersion = Version.parse('0.1.0-dev.3');

/// Warns when the consuming package resolves an older `gqlify_runtime` than
/// generated code needs (generated code would then not compile). Shared by
/// the CLI and the builder; reads only `pubspec.lock`.
Diagnostic? checkRuntimeVersion(String? pubspecLock) {
  if (pubspecLock == null) return null;
  Object? version;
  try {
    final lock = loadYaml(pubspecLock);
    if (lock is YamlMap) {
      final package = (lock['packages'] as YamlMap?)?['gqlify_runtime'];
      if (package is YamlMap) version = package['version'];
    }
  } on YamlException {
    return null;
  }
  if (version is! String) return null;
  final Version resolved;
  try {
    resolved = Version.parse(version);
  } on FormatException {
    return null;
  }
  if (resolved >= minimumRuntimeVersion) return null;
  return Diagnostic(
    severity: Severity.warning,
    code: 'runtime-version',
    message:
        'gqlify_runtime $resolved is older than $minimumRuntimeVersion, '
        'which the generated code requires. Upgrade gqlify_runtime.',
    path: 'pubspec.lock',
  );
}
