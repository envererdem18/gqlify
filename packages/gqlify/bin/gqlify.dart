import 'dart:io';

import 'package:gqlify/src/cli/runner.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await GqlifyCommandRunner().run(arguments);
}
