import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/proxy_core_embedded.dart';

/// iOS 稳定性回归（客户实测 2026-10-18：「经常自动断开连接」「热切换失败」）。
///
/// 实测日志证据链：
///   1. 扩展侧自检 `API 自检(扩展内) HTTP 401` —— App 调 startVpn 时**没传 secret**，
///      扩展拿空 secret 去 PATCH /configs 就被内核拒；
///   2. `[KERNEL] watchdog declared dead, failures=3` 每 15~20s 一次，
///      紧接着 `kernel crash recovery #N` —— 内核其实活着（API 回了 401），
///      旧实现要求严格 200，判成"死了"就杀隧道重连，形成无限循环；
///   3. `[NET] network changed` 每 8 秒抖动一次（wifi ↔ [wifi, other]）——
///      `other` 是隧道接口本身，不该当成"网络变了"。
void main() {
  group('看门狗判定：内核能回 HTTP 就不能判死', () {
    test('轮询失败但没到阈值 → 保活（不急着断）', () {
      expect(
          decideWatchdog(
              pollOk: false,
              consecutiveFailures: 2,
              deadThreshold: 3,
              nativeAlive: false),
          WatchdogAction.keepAlive);
    });

    test('内核 API 回了 401/403（鉴权失败）→ 调用方已按 pollOk=true 处理，判健康', () {
      // 401/403 在上层被归一化成 pollOk=true（内核活着，只是鉴权不对）
      expect(
          decideWatchdog(
              pollOk: true,
              consecutiveFailures: 5,
              deadThreshold: 3,
              nativeAlive: false),
          WatchdogAction.healthy);
    });

    test('真连不上 API + 原生也说不存活 → 才判死', () {
      expect(
          decideWatchdog(
              pollOk: false,
              consecutiveFailures: 3,
              deadThreshold: 3,
              nativeAlive: false),
          WatchdogAction.declareDead);
    });

    test('原生说存活（隧道还在）→ 即使 API 连不上也保活（宁不断连）', () {
      expect(
          decideWatchdog(
              pollOk: false,
              consecutiveFailures: 9,
              deadThreshold: 3,
              nativeAlive: true),
          WatchdogAction.keepAlive);
    });
  });
}
