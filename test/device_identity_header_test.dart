// 设备身份稳定性回归：客户端必须上报「安装级稳定设备 ID」。
//
// 背景（2026-09-21 生产问题）：后端过去按 UA（**含 App 版本号**）识别设备，于是
// 用户每次升级 App/系统就会被当成一台「新设备」重复登记 —— 旧行永远占着名额
// （设备数虚高、甚至提示设备超限），而「删除设备 = 踢下线」的判定也会随版本
// 漂移（升级一次就能绕过，或者反过来永远命中旧行）。
//
// 修复：客户端每个请求都带上 X-MF-Device-Id（来自安装标记 install_id，重装才换），
// 后端优先用它作为设备身份。这里锁定「头一定会被带上」这条契约。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/api/user_agent.dart';
import 'package:mbox/core/services/local_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    UserAgent.deviceHeaders = {};
    tmp = Directory.systemTemp.createTempSync('mf_ua_test');
    LocalPaths.debugSupportDir = () async => tmp;
  });

  tearDown(() {
    UserAgent.deviceHeaders = {};
    LocalPaths.debugSupportDir = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('resolve() 会带上稳定设备 ID（X-MF-Device-Id）', () async {
    await UserAgent.resolve(version: '2.2.16');

    final id = UserAgent.deviceHeaders['X-MF-Device-Id'];
    expect(id, isNotNull, reason: '设备身份必须稳定：没有这个头，升级 App 就会变成"新设备"');
    expect(id, isNotEmpty);
  });

  test('标记缺失时会补写，且同一安装内保持不变（升级 App 不换号）', () async {
    await UserAgent.resolve(version: '2.2.16');
    final first = UserAgent.deviceHeaders['X-MF-Device-Id'];

    // 模拟「升级 App 后重新启动」：标记文件还在 → 设备 ID 必须一模一样
    UserAgent.deviceHeaders = {};
    await UserAgent.resolve(version: '2.2.17');
    final second = UserAgent.deviceHeaders['X-MF-Device-Id'];

    expect(second, first, reason: '升级 App 不能改变设备身份');
  });

  test('标记存在时沿用原值（不重新生成）', () async {
    final marker = File('${tmp.path}/${LocalPaths.markerFileName}');
    marker.writeAsStringSync('fixed-install-id-1234');

    await UserAgent.resolve(version: '2.2.16');

    expect(UserAgent.deviceHeaders['X-MF-Device-Id'], 'fixed-install-id-1234');
  });
}
