/// The `gqlify` command line interface as a library, e.g. to build an
/// ahead-of-time compiled executable from your own package:
///
/// ```dart
/// // tool/gqlify.dart
/// import 'package:gqlify/cli.dart';
///
/// Future<void> main(List<String> args) => runGqlify(args);
/// ```
///
/// `dart compile exe tool/gqlify.dart -o build/gqlify`, then
/// `./build/gqlify generate`.
library;

import 'dart:async';
import 'dart:io';

import 'src/cli/runner.dart';

/// Runs the CLI with [arguments] and sets [exitCode].
Future<void> runGqlify(List<String> arguments) async {
  // Output may be closed early (e.g. piped into `head`); that is not an
  // error of the run, so don't crash with an unhandled EPIPE.
  unawaited(stdout.done.catchError((Object _) {}));
  unawaited(stderr.done.catchError((Object _) {}));
  exitCode = await GqlifyCommandRunner().run(arguments);
}
