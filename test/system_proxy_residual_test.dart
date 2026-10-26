// 系统代理「残留清扫」的判据：指向本机端口 **且** 端口没人监听才算残留。
//
// 背景（2026-09-14 真实日志）：多实例场景下新实例把**另一个实例正在使用的**
// 系统代理当成残留清掉了（`startup: cleared residual system proxy` 紧跟在
// 内核被杀之后），用户表现为「显示已连接但浏览器打不开网页」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/system_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldClearResidual（纯判据）', () {
    test('代理没指向本机 → 与残留无关，不动', () {
      expect(
          SystemProxyManager.shouldClearResidual(
              proxyPointsToLocal: false, portAlive: false),
          isFalse);
      expect(
          SystemProxyManager.shouldClearResidual(
              proxyPointsToLocal: false, portAlive: true),
          isFalse);
    });

    test('指向本机且端口已死 → 残留，清掉（整机断网的修复路径）', () {
      expect(
          SystemProxyManager.shouldClearResidual(
              proxyPointsToLocal: true, portAlive: false),
          isTrue);
    });

    test('指向本机但端口还有进程监听 → 活代理，不能清（多实例误清回归）', () {
      expect(
          SystemProxyManager.shouldClearResidual(
              proxyPointsToLocal: true, portAlive: true),
          isFalse);
    });

    test('force 跳过探活（调用方明确要清）', () {
      expect(
          SystemProxyManager.shouldClearResidual(
              proxyPointsToLocal: true, portAlive: true, force: true),
          isTrue);
    });
  });

  group('isLocalPortAlive（探活本身）', () {
    test('有监听 → true；端口关闭 → false', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      try {
        expect(await SystemProxyManager.isLocalPortAlive(port), isTrue);
      } finally {
        await server.close();
      }
      // 关闭后再探 → 没有监听
      expect(await SystemProxyManager.isLocalPortAlive(port), isFalse);
    });
  });
}
