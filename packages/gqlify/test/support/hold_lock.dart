import 'dart:io';

import 'package:gqlify/src/cache/lock.dart';

/// Test helper: holds the gqlify project lock of `args[0]` for `args[1]`
/// milliseconds (or until killed), printing "locked" once acquired.
Future<void> main(List<String> args) async {
  final lock = await ProjectLock.acquire(args[0], exclusive: true);
  stdout.writeln('locked');
  await stdout.flush();
  await Future<void>.delayed(Duration(milliseconds: int.parse(args[1])));
  lock.release();
}
