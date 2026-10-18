import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/services/subscribe_url_failover.dart';
import 'package:moneyfly/core/services/subscription_service.dart';

/// 客户实测（2026-10-18）：「登录后提示 网络服务端异常 拉不到新订阅」。
///
/// 两个真实缺陷：
///  1. **401 被误判成网络异常**：令牌过期时客户端提示「网络服务端异常」，用户
///     反复重试/重装/换网络都没用（唯一出路是重新登录）→ 必须单独分类；
///  2. **慢但可用的订阅地址被短超时判死**：大订阅（300~500KB）在慢速移动网络上
///     5s 下不来很正常，旧实现在「只有一个候选」时直接放弃 → 永远拉不到。
const _token = 'token=abcdef0123456789';
const _yaml = 'proxies:\n  - {name: ok, server: 198.51.100.10, port: 443, type: ss, password: pw, cipher: aes-128-gcm}\n';

void main() {
  group('登录态失效必须与网络异常区分', () {
    test('401 / 令牌过期 → authRequired（而不是 network）', () {
      for (final msg in [
        '登录已过期，请重新登录',
        '登录已失效',
        '未授权',
        '请重新登录',
        'Unauthorized',
        'invalid token',
        'token expired',
        'token is expired',
      ]) {
        expect(SubscriptionService.classifyFromError(msg), SubscribeIssue.authRequired,
            reason: '「$msg」应判定为登录态失效');
      }
    });

    test('真网络错误仍是 network（不会被误判成登录失效）', () {
      for (final msg in [
        '网络连接失败，请检查网络后重试',
        '服务器响应超时，请稍后重试',
        '请求失败（502）',
      ]) {
        expect(SubscriptionService.classifyFromError(msg), SubscribeIssue.network,
            reason: '「$msg」应保持网络异常');
      }
    });

    test('踢下线 / 禁用 / 设备超限的判定不能被登录态失效抢走', () {
      expect(SubscriptionService.classifyFromError('此设备已被移除并踢下线，如需继续使用请重新登录'),
          SubscribeIssue.deviceKicked);
      expect(SubscriptionService.classifyFromError('账户已被禁用，请联系客服'),
          SubscribeIssue.accountDisabled);
      expect(SubscriptionService.classifyFromError('设备数量超过限制(当前5/限制5)'),
          SubscribeIssue.deviceFull);
    });
  });

  group('慢网络下不能把「其实能通」的订阅地址判死', () {
    test('只有一个候选且响应慢于首尝试超时 → 用完整超时重试后成功', () async {
      const url = 'https://only.example/api/v1/client/subscribe?$_token';
      var calls = 0;
      final sw = Stopwatch()..start();

      final r = await SubscribeUrlFailover.fetchFirst(
        primary: url,
        fetch: (u) async {
          calls++;
          // 首次调用慢吞吞（超过 150ms 的短超时），之后正常返回
          if (calls == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          return _yaml;
        },
        looksUsable: (raw) => raw.contains('proxies:'),
        firstAttemptTimeout: const Duration(milliseconds: 150),
        raceWidth: 1,
      );
      sw.stop();

      expect(r.url, url);
      expect(calls, greaterThanOrEqualTo(2),
          reason: '短超时失败后必须用完整超时再给同一地址一次机会');
      expect(r.raw, contains('proxies:'));
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });

    test('多候选时首地址慢也不会被跳过（最终仍能成功）', () async {
      const slow = 'https://slow.example/api/v1/client/subscribe?$_token';
      const other = 'https://other.example/api/v1/client/subscribe?$_token';
      final tried = <String>[];

      final r = await SubscribeUrlFailover.fetchFirst(
        primary: slow,
        backups: const [other],
        fetch: (u) async {
          tried.add(u);
          if (u == slow) {
            // 慢但可用（800ms）
            await Future<void>.delayed(const Duration(milliseconds: 800));
            return _yaml;
          }
          throw StateError('另一个不可达');
        },
        looksUsable: (raw) => raw.contains('proxies:'),
        firstAttemptTimeout: const Duration(milliseconds: 200),
        raceWidth: 2,
      );

      expect(r.url, slow, reason: '慢但可用的地址最终应成功，而不是报"拉不到订阅"');
      expect(tried, contains(slow));
    });
  });
}
