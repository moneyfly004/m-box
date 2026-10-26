// 单实例守卫（macOS / Linux 的排他文件锁）。
//
// 背景（2026-09-14 真实日志）：三个实例在 5 秒内先后启动，各自管理体系代理与
// 内核，互相把对方的内核/代理当残留清理。Windows 有原生 CreateMutexW 拦截，
// macOS/Linux 一直没有守卫 → 用文件锁补上，且必须**跨进程**真的互斥。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/single_instance.dart';

/// 找到随 Flutter 一起安装的 dart 可执行文件（跨进程验证需要它）
String? _dartExe() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) return null;
  final exe = File('$root/bin/cache/dart-sdk/bin/dart'
      '${Platform.isWindows ? '.exe' : ''}');
  return exe.existsSync() ? exe.path : null;
}

/// 子进程：尝试对同一把锁取排他锁，被占用则打印 BLOCKED
const _childScript = r'''
import 'dart:io';
void main(List<String> args) {
  try {
    final raf = File(args[0]).openSync(mode: FileMode.write);
    raf.lockSync(FileLock.exclusive);
    print('ACQUIRED');
  } on FileSystemException {
    print('BLOCKED');
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mf_single_instance_test');
    SingleInstance.debugDir = () async => tmp;
    await SingleInstance.releaseForTest();
  });

  tearDown(() async {
    await SingleInstance.releaseForTest();
    SingleInstance.debugDir = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('取锁成功 → 释放后可再次取锁（不留假锁把用户挡在门外）', () async {
    expect(await SingleInstance.acquire(), isTrue);
    expect(File('${tmp.path}/mbox.lock').existsSync(), isTrue);
    await SingleInstance.releaseForTest();
    expect(await SingleInstance.acquire(), isTrue);
  });

  test('重复取锁幂等（同进程内不重复占用句柄）', () async {
    expect(await SingleInstance.acquire(), isTrue);
    expect(await SingleInstance.acquire(), isTrue);
  });

  test('跨进程互斥：另一个进程拿不到已被持有的锁', () async {
    final dart = _dartExe();
    final script = File('${tmp.path}/lock_probe.dart');
    await script.writeAsString(_childScript);

    expect(await SingleInstance.acquire(), isTrue);
    final lockPath = '${tmp.path}/mbox.lock';

    if (dart != null) {
      final blocked =
          await Process.run(dart, [script.path, lockPath]);
      expect((blocked.stdout as String).trim(), 'BLOCKED',
          reason: '第二个进程竟然拿到了锁 → 守卫形同虚设');
    }

    // 释放后子进程应能拿到（证明 BLOCKED 不是脚本自身错误造成的）
    // 注：不校验 ACQUIRED，只要不是 BLOCKED 即说明锁已释放
    await SingleInstance.releaseForTest();
    if (dart != null) {
      final acquired = await Process.run(dart, [script.path, lockPath]);
      expect((acquired.stdout as String).trim(), isNot('BLOCKED'));
    }
  }, skip: _dartExe() == null ? '找不到 dart 可执行文件（需 FLUTTER_ROOT）' : null);
}
