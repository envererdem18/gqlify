import 'dart:async';
import 'dart:io';

import 'package:gqlify/src/cli/runner.dart';

Future<void> main(List<String> arguments) async {
  // Output may be closed early (e.g. piped into `head`); that is not an
  // error of the run, so don't crash with an unhandled EPIPE.
  unawaited(stdout.done.catchError((Object _) {}));
  unawaited(stderr.done.catchError((Object _) {}));
  exitCode = await GqlifyCommandRunner().run(arguments);
}
