import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/log_rotation.dart';
import '../utils/serial_executor.dart';
import 'app_log.dart';
import 'local_paths.dart';

/// 内核（sing-box）原始输出落盘：连续日志 `kernel_log.txt` + 崩溃快照
/// `kernel_crash.log`。
///
/// 为什么需要落盘：内核一死，内存里那点尾部输出（proxy_core_cli 的
/// `_logTail` 只留 40 行、`_lastCoreLogs` 只留 200 行）就随进程消失 ——
/// App 重开后**再也查不出它为什么死**。2026-09-10 的 `code=1` 静默退出至今
/// 无法定因，就是「没有证据」而不是「没有问题」。
///
/// 抓的是 App 侧对内核 stdout/stderr 的捕获（`Process.start` 的两条流），
/// 因此 Go panic（只写 stderr、**不写**内核自己的 log-file）同样能留下。
///
/// 写路径与 [AppLog] 同构：全局串行队列 + 超限按整行保留后半，
/// 杜绝并发 append 与旋转交错导致的「读半份改写」。
class KernelLog {
  KernelLog._();

  static File? _file;
  static File? _crashFile;
  static const _maxSize = 512 * 1024; // 512KB，与 app_log.txt 同量级

  static final SerialExecutor _queue = SerialExecutor();

  static Future<File?> _resolveLog() async {
    if (_file != null) return _file;
    try {
      final dir = await LocalPaths.supportDir();
      if (dir == null) return null;
      _file = File('${dir.path}/kernel_log.txt');
      return _file;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> _resolveCrash() async {
    if (_crashFile != null) return _crashFile;
    try {
      final dir = await LocalPaths.supportDir();
      if (dir == null) return null;
      _crashFile = File('${dir.path}/kernel_crash.log');
      return _crashFile;
    } catch (_) {
      return null;
    }
  }

  /// 连续内核日志文件路径（供设置页/排查展示；可能为 null = 平台无私有目录）
  static Future<String?> get filePath async => (await _resolveLog())?.path;

  /// 最近一次崩溃快照文件路径
  static Future<String?> get crashFilePath async =>
      (await _resolveCrash())?.path;

  /// 追加一行内核输出（fire-and-forget，绝不阻塞内核日志流消费）
  static void append(String line) {
    if (kIsWeb) return;
    _queue.run(() async {
      try {
        final f = await _resolveLog();
        if (f == null) return;
        await f.writeAsString('$line\n', mode: FileMode.append, flush: false);
        if (await f.length() > _maxSize) {
          final content = await f.readAsString();
          await f.writeAsString(keepSecondHalf(content), flush: true);
        }
      } catch (_) {}
    });
  }

  /// 内核异常退出：把退出码 + 尾部输出写成一份快照（排查「被谁杀的」的唯一现场）。
  /// 与 app_log.txt 里那行被截断的摘要互补 —— 这里是完整尾部，且独立成文件，
  /// 不会被 app_log 的旋转滚掉。
  static Future<String?> recordCrash({
    required int code,
    required List<String> tail,
    String? note,
  }) async {
    if (kIsWeb) return null;
    String? path;
    await _queue.run(() async {
      try {
        final f = await _resolveCrash();
        if (f == null) return;
        path = f.path;
        final b = StringBuffer()
          ..writeln('===== kernel exit ${DateTime.now().toIso8601String()} '
              'code=$code${note == null ? '' : ' ($note)'} =====');
        for (final l in tail) {
          b.writeln(l);
        }
        b.writeln();
        await f.writeAsString(b.toString(), mode: FileMode.append, flush: true);
        if (await f.length() > _maxSize) {
          final content = await f.readAsString();
          await f.writeAsString(keepSecondHalf(content), flush: true);
        }
      } catch (_) {}
    });
    return path;
  }

  /// 清空（设置页「清空日志」用；与在写 append 同队列，避免交错）
  static Future<void> clear() {
    return _queue.run(() async {
      for (final f in [await _resolveLog(), await _resolveCrash()]) {
        try {
          if (f != null && f.existsSync()) await f.writeAsString('');
        } catch (_) {}
      }
    });
  }

  /// 读连续日志（排查/导出用）
  static Future<String> read() async {
    final f = await _resolveLog();
    if (f == null || !f.existsSync()) return '';
    try {
      return await f.readAsString();
    } catch (_) {
      return '';
    }
  }

  /// 把内核日志路径写进 app_log，用户导出 app_log 时能顺着找到完整内核输出
  static void announcePaths() {
    _queue.run(() async {
      final log = await filePath;
      final crash = await crashFilePath;
      AppLog.kernel('kernel log file: ${log ?? '(unavailable)'}'
          '${crash == null ? '' : ' | crash dump: $crash'}');
    });
  }

  /// 等待已入队的写入全部落盘（测试用；生产路径全 fire-and-forget 不阻塞）
  @visibleForTesting
  static Future<void> flush() => _queue.run(() async {});

  /// 清掉文件句柄缓存（测试换临时目录时用）
  @visibleForTesting
  static void resetForTest() {
    _file = null;
    _crashFile = null;
  }
}
