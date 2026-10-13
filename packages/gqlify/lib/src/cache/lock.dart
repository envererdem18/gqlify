import 'dart:io';

/// An inter-process lock on `.dart_tool/gqlify/lock`.
///
/// Uses OS file locks (`fcntl`/`LockFileEx`), which the OS releases when the
/// process exits or crashes, so a stale lock can never block later runs.
/// Note: these locks exclude other *processes*, not isolates of the same
/// process.
final class ProjectLock {
  ProjectLock._(this._file);

  final RandomAccessFile _file;

  /// Acquires the lock, waiting up to [timeout]. [onWait] is called once if
  /// another process holds it. Throws [TimeoutException]-like
  /// [FileSystemException] on timeout.
  static Future<ProjectLock> acquire(
    String path, {
    required bool exclusive,
    Duration timeout = const Duration(minutes: 2),
    void Function()? onWait,
  }) async {
    File(path).parent.createSync(recursive: true);
    final file = File(path).openSync(mode: FileMode.append);
    final deadline = DateTime.now().add(timeout);
    var waited = false;
    while (true) {
      try {
        file.lockSync(exclusive ? FileLock.exclusive : FileLock.shared);
        break;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) {
          file.closeSync();
          throw FileSystemException(
            'Timed out after ${timeout.inSeconds}s waiting for another gqlify '
            'process to finish',
            path,
          );
        }
        if (!waited) {
          waited = true;
          onWait?.call();
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (exclusive) {
      // Informational only; correctness relies on the OS lock.
      file
        ..truncateSync(0)
        ..writeStringSync(
          'pid $pid since ${DateTime.now().toUtc().toIso8601String()}\n',
        );
    }
    return ProjectLock._(file);
  }

  void release() {
    try {
      _file.unlockSync();
    } finally {
      _file.closeSync();
    }
  }
}
