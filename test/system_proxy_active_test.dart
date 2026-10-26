// macOS 系统代理「换网后新接口没有代理」的判据（纯函数）—— 单测。
//
// 审计发现（2026-09-25）：系统代理是**按网络服务**生效的，而旧实现只在首次
// apply 时捕获一次活跃服务，之后永远只写那批服务；探针 `_macProxyPointsTo`
// 在「还没捕获过任何服务」时还直接返回 true（未知当正常）。
// 结果：连上后切 Wi-Fi / 插网线 / 开热点 → 新服务没有代理项，
// 客户看到「首页显示已连接、速率为 0」，甚至以本机 IP 直连出网（以为走了代理）。

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/system_proxy.dart';

void main() {
  group('macProxyNeedsApply：保活是否需要重新写代理', () {
    test('还没捕获过任何服务（状态未知）→ 需要 apply', () {
      expect(
        SystemProxyManager.macProxyNeedsApply(
            captured: const {}, activeServices: const ['Wi-Fi']),
        isTrue,
      );
      expect(
        SystemProxyManager.macProxyNeedsApply(
            captured: const {}, activeServices: const []),
        isTrue,
        reason: '未知 ≠ 正常：旧实现这里返回「不需要」，导致探针恒说正常',
      );
    });

    test('出现了未覆盖的活跃服务（换 Wi-Fi / 插网线 / 开热点）→ 需要 apply', () {
      expect(
        SystemProxyManager.macProxyNeedsApply(
          captured: const {'Wi-Fi'},
          activeServices: const ['Wi-Fi', 'USB 10/100/1000 LAN'],
        ),
        isTrue,
      );
      expect(
        SystemProxyManager.macProxyNeedsApply(
          captured: const {'Wi-Fi'},
          activeServices: const ['Ethernet'],
        ),
        isTrue,
      );
    });

    test('活跃服务都在已捕获集合内 → 不需要 apply（保活不折腾系统配置）', () {
      expect(
        SystemProxyManager.macProxyNeedsApply(
          captured: const {'Wi-Fi', 'Thunderbolt Bridge'},
          activeServices: const ['Wi-Fi'],
        ),
        isFalse,
        reason: '不活跃的服务留着原状态即可，不必重写',
      );
      expect(
        SystemProxyManager.macProxyNeedsApply(
          captured: const {'Wi-Fi'},
          activeServices: const ['Wi-Fi'],
        ),
        isFalse,
      );
    });
  });
}
