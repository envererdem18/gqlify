/// `build_runner` integration for gqlify.
///
/// Applied automatically to packages depending on `gqlify` (see the
/// package's `build.yaml`); configuration comes from `gqlify.yaml` or the
/// `gqlify:` section of `pubspec.yaml`, exactly as for the CLI.
library;

import 'package:build/build.dart';

import 'src/builder/gqlify_builder.dart';

/// Builder factory referenced from `build.yaml`.
Builder gqlifyBuilder(BuilderOptions options) => GqlifyBuilder();
