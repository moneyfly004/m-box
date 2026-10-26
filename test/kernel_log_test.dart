// 内核输出落盘：连续日志 + 崩溃快照。
//
// 背景（2026-09-10 真实日志）：内核 code=1 静默退出后，内存里那 40 行尾部随
// 进程消失，App 重开后无从查证「谁杀的、为什么死」——只能靠配置文件里的
// 猜测。落盘之后至少能拿到完整尾部 + 退出码，且活过 App 重启。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/kernel_log.dart';
import 'package:mbox/core/services/local_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mf_kernel_log_test');
    LocalPaths.debugSupportDir = () async => tmp;
    KernelLog.resetForTest();
  });

  tearDown(() async {
    LocalPaths.debugSupportDir = null;
    KernelLog.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('append 逐行落盘且顺序保持', () async {
    KernelLog.append('time=... level=info msg="Start initial configuration"');
    KernelLog.append('time=... level=error msg="failed to get the second response"');
    await KernelLog.flush();

    final content = await KernelLog.read();
    final lines = content.trim().split('\n');
    expect(lines.length, 2);
    expect(lines.first, contains('Start initial configuration'));
    expect(lines.last, contains('failed to get the second response'));
    // 文件真的存在于支持目录（可被用户导出）
    expect(File('${tmp.path}/kernel_log.txt').existsSync(), isTrue);
  });

  test('recordCrash 写出退出码 + 完整尾部，供事后定因', () async {
    final path = await KernelLog.recordCrash(
      code: 1,
      tail: ['line-a', 'line-b', 'line-c'],
      note: 'unexpected exit',
    );

    expect(path, isNotNull);
    final content = File(path!).readAsStringSync();
    expect(content, contains('code=1'));
    expect(content, contains('unexpected exit'));
    // 尾部必须完整保留（app_log 里那行会被截断到 120 字）
    for (final l in ['line-a', 'line-b', 'line-c']) {
      expect(content, contains(l), reason: '崩溃快照丢了 $l');
    }
  });

  test('追加崩溃快照不会被前一次覆盖（保留多次崩溃历史）', () async {
    await KernelLog.recordCrash(code: 1, tail: ['first']);
    await KernelLog.recordCrash(code: -1, tail: ['second']);
    final path = await KernelLog.crashFilePath;
    final content = File(path!).readAsStringSync();
    expect(content, contains('first'));
    expect(content, contains('second'));
  });

  test('clear 同时清空连续日志与崩溃快照', () async {
    KernelLog.append('noise');
    await KernelLog.recordCrash(code: 1, tail: ['boom']);
    await KernelLog.clear();
    expect(await KernelLog.read(), isEmpty);
    final crash = await KernelLog.crashFilePath;
    expect(File(crash!).readAsStringSync(), isEmpty);
  });
}
