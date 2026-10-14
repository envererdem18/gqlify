import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'diagnostics.dart';

/// `gqlify_runtime` versions this generator's output works with.
///
/// Policy: generator and runtime share the minor version before 1.0
/// (gqlify 0.1.x generates code for gqlify_runtime 0.1.x), and the major
/// version after 1.0.
final compatibleRuntimeVersions = VersionConstraint.parse('>=0.1.0 <0.2.0');

/// Warns when the consuming package resolves a `gqlify_runtime` outside
/// [compatibleRuntimeVersions] (generated code might then not compile).
/// Shared by the CLI and the builder; reads only `pubspec.lock`.
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
  if (compatibleRuntimeVersions.allows(resolved)) return null;
  return Diagnostic(
    severity: Severity.warning,
    code: 'runtime-version',
    message:
        'gqlify_runtime $resolved is not supported by this version of gqlify '
        '(expected $compatibleRuntimeVersions). Use matching versions of '
        'gqlify and gqlify_runtime.',
    path: 'pubspec.lock',
  );
}
