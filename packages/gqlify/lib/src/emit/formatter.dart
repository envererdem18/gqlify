import 'package:dart_style/dart_style.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// How generated code is formatted.
///
/// Generated libraries should be left untouched by `dart format` in the
/// consuming package, so these settings mirror what `dart format` would use
/// there: the package's language version (from the `pubspec.yaml` SDK
/// constraint) and the `formatter:` section of its `analysis_options.yaml`.
final class FormatSettings {
  FormatSettings({
    Version? languageVersion,
    this.pageWidth = 80,
    this.preserveTrailingCommas = false,
  }) : languageVersion = _clamp(
         languageVersion ?? DartFormatter.latestLanguageVersion,
       );

  /// Derives settings from the consuming package's files. Invalid or missing
  /// entries fall back to `dart format` defaults.
  factory FormatSettings.fromProjectFiles({
    String? pubspecYaml,
    String? analysisOptionsYaml,
  }) {
    Version? languageVersion;
    final sdk = _yamlPath(pubspecYaml, ['environment', 'sdk']);
    if (sdk is String) {
      try {
        final constraint = VersionConstraint.parse(sdk);
        if (constraint is VersionRange && constraint.min != null) {
          final min = constraint.min!;
          languageVersion = Version(min.major, min.minor, 0);
        }
      } on FormatException {
        // Leave the default; pub reports invalid constraints itself.
      }
    }
    final pageWidth = _yamlPath(analysisOptionsYaml, [
      'formatter',
      'page_width',
    ]);
    final trailingCommas = _yamlPath(analysisOptionsYaml, [
      'formatter',
      'trailing_commas',
    ]);
    return FormatSettings(
      languageVersion: languageVersion,
      pageWidth: pageWidth is int && pageWidth > 0 ? pageWidth : 80,
      preserveTrailingCommas: trailingCommas == 'preserve',
    );
  }

  /// Oldest language version generated code is valid for (patterns, class
  /// modifiers and switch expressions).
  static final minimumLanguageVersion = Version(3, 0, 0);

  final Version languageVersion;
  final int pageWidth;
  final bool preserveTrailingCommas;

  /// Canonical description of the settings, for cache keys.
  String get fingerprint =>
      '$languageVersion;$pageWidth;${preserveTrailingCommas ? 'preserve' : 'automate'}';

  static Version _clamp(Version v) {
    final latest = DartFormatter.latestLanguageVersion;
    if (v > latest) return latest;
    if (v < minimumLanguageVersion) return minimumLanguageVersion;
    return v;
  }

  static Object? _yamlPath(String? yaml, List<String> path) {
    if (yaml == null) return null;
    Object? node;
    try {
      node = loadYaml(yaml);
    } on YamlException {
      return null;
    }
    for (final key in path) {
      if (node is! Map) return null;
      node = node[key];
    }
    return node;
  }
}

/// Formats generated code according to [FormatSettings]. Line endings are
/// always `\n` so outputs are identical across platforms.
final class GeneratedCodeFormatter {
  GeneratedCodeFormatter(FormatSettings settings)
    : _formatter = DartFormatter(
        languageVersion: settings.languageVersion,
        lineEnding: '\n',
        pageWidth: settings.pageWidth,
        trailingCommas: settings.preserveTrailingCommas
            ? TrailingCommas.preserve
            : TrailingCommas.automate,
      );

  final DartFormatter _formatter;

  /// Throws [FormatterException] if [source] is not valid Dart (an internal
  /// generator bug).
  String format(String source, {required String path}) =>
      _formatter.format(source, uri: path);
}
