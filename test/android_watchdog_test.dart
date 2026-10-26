// 回归：Android 看门狗判死逻辑。核心保证——App 切后台/弹系统框/限流导致的
// 瞬时轮询失败，绝不能误判内核死亡而断开（用户报告「连接后自动缩小随即断开」）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/proxy_core_embedded.dart';

void main() {
  const threshold = 3;

  test('巡检正常 → healthy', () {
    expect(
      decideWatchdog(
          pollOk: true,
          consecutiveFailures: 0,
          deadThreshold: threshold,
          nativeAlive: true),
      WatchdogAction.healthy,
    );
  });

  test('单次失败 → keepAlive（绝不立即断连）', () {
    expect(
      decideWatchdog(
          pollOk: false,
          consecutiveFailures: 1,
          deadThreshold: threshold,
          nativeAlive: false),
      WatchdogAction.keepAlive,
    );
  });

  test('连续 2 次失败（未达阈值 3）→ keepAlive', () {
    expect(
      decideWatchdog(
          pollOk: false,
          consecutiveFailures: 2,
          deadThreshold: threshold,
          nativeAlive: false),
      WatchdogAction.keepAlive,
    );
  });

  test('达阈值但原生 VpnService 仍在跑 → keepAlive（后台假失败，关键防线）', () {
    expect(
      decideWatchdog(
          pollOk: false,
          consecutiveFailures: 3,
          deadThreshold: threshold,
          nativeAlive: true),
      WatchdogAction.keepAlive,
    );
  });

  test('达阈值且原生确认已停 → declareDead（真死亡才断）', () {
    expect(
      decideWatchdog(
          pollOk: false,
          consecutiveFailures: 3,
          deadThreshold: threshold,
          nativeAlive: false),
      WatchdogAction.declareDead,
    );
  });

  test('超过阈值仍未死（原生存活）→ 持续 keepAlive', () {
    for (final n in [4, 5, 10, 100]) {
      expect(
        decideWatchdog(
            pollOk: false,
            consecutiveFailures: n,
            deadThreshold: threshold,
            nativeAlive: true),
        WatchdogAction.keepAlive,
        reason: '连续失败 $n 次但原生存活时不应断连',
      );
    }
  });
}
