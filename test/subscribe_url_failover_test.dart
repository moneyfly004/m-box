import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/subscribe_url_failover.dart';

void main() {
  group('SubscribeUrlFailover', () {
    const primary =
        'https://dy.moneyfly.top/api/v1/client/subscribe?token=abc123&type=clash';
    const backup1 =
        'https://moneyfly.dpdns.org/api/v1/client/subscribe?token=abc123&type=clash';
    const backup2 =
        'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?token=abc123&type=clash';
    const otherToken =
        'https://new.moneyfly.dpdns.org/api/v1/client/subscribe?token=zzz999&type=clash';

    test('tokenOf：取出订阅 token，取不到返回空串', () {
      expect(SubscribeUrlFailover.tokenOf(primary), 'abc123');
      expect(SubscribeUrlFailover.tokenOf('https://x/y?type=clash&token=t1'), 't1');
      expect(SubscribeUrlFailover.tokenOf('https://x/y'), '');
      expect(SubscribeUrlFailover.tokenOf(''), '');
    });

    test('候选顺序：上次成功的优先 → 主地址 → 备用地址（去重）', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        backups: const [backup1, backup2, backup1],
        preferred: backup2,
      );
      expect(list, [backup2, primary, backup1]);
    });

    test('上次成功的地址若属于另一份订阅（token 不同）则忽略', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        backups: const [backup1],
        preferred: otherToken,
      );
      expect(list, [primary, backup1]);
    });

    test('备用地址 token 与主地址不一致时跳过（防止串号）', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        backups: const [backup1, otherToken],
      );
      expect(list, [primary, backup1]);
    });

    test('主地址连接失败 → 自动换备用地址并回调成功地址', () async {
      final tried = <String>[];
      final ok = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: const [backup1, backup2],
        fetch: (url) async {
          tried.add(url);
          if (url == primary) throw Exception('connection refused');
          if (url == backup1) throw Exception('connection timeout');
          return 'proxies: []';
        },
      );
      expect(tried, [primary, backup1, backup2], reason: '应依次尝试，直到成功');
      expect(ok.url, backup2);
      expect(ok.raw, 'proxies: []');
    });

    test('上次成功的地址会被优先尝试（不再先撞打不开的主域名）', () async {
      final tried = <String>[];
      final ok = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: const [backup1, backup2],
        preferred: backup2,
        fetch: (url) async {
          tried.add(url);
          return 'proxies: []';
        },
      );
      expect(tried, [backup2]);
      expect(ok.url, backup2);
    });

    test('连上了但返回的不是订阅内容（拦截页）→ 继续换下一个地址', () async {
      final tried = <String>[];
      final ok = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: const [backup1],
        fetch: (url) async {
          tried.add(url);
          return url == primary ? '<html>该网站不可访问</html>' : 'proxies:\n  - name: a';
        },
        looksUsable: (raw) => !raw.contains('<html'),
      );
      expect(tried, [primary, backup1]);
      expect(ok.url, backup1);
    });

    test('返回空内容也视为失败 → 换下一个地址', () async {
      final ok = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: const [backup1],
        fetch: (url) async => url == primary ? '   \n' : 'proxies: []',
      );
      expect(ok.url, backup1);
    });

    test('全部地址失败 → 抛出最后一个异常（如实报错，不返回空订阅）', () async {
      await expectLater(
        SubscribeUrlFailover.fetchFirst(
          primary: primary,
          backups: const [backup1, backup2],
          fetch: (url) async => throw Exception('fail:$url'),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('实测快慢判据：快的排前面（上次成功的仍最前）', () {
      const t = 'abc';
      const fast = 'https://fast.example.com/api/v1/client/subscribe?token=$t';
      const mid = 'https://mid.example.com/api/v1/client/subscribe?token=$t';
      const slow = 'https://slow.example.com/api/v1/client/subscribe?token=$t';
      // 面板顺序：slow(主) → fast → mid；实测：fast 最快、mid 次之、slow 最慢
      final list = SubscribeUrlFailover.candidates(
        primary: slow,
        backups: const [fast, mid],
        hostPriority: (u) => u.contains('fast')
            ? 0
            : u.contains('mid')
                ? 1
                : 9,
      );
      expect(list.first, fast);
      expect(list[1], mid);
      expect(list.last, slow);
    });

    test('实测判据缺失时保持原顺序（主地址优先）', () {
      const t = 'abc';
      const p1 = 'https://a.example.com/api/v1/client/subscribe?token=$t';
      const p2 = 'https://b.example.com/api/v1/client/subscribe?token=$t';
      final list = SubscribeUrlFailover.candidates(primary: p1, backups: const [p2]);
      expect(list, [p1, p2]);
    });

    test('默认会尝试完全部候选（面板下发 5~6 个域名时不能漏掉最后一个）', () async {
      // 线上实测：面板下发 5 个订阅域名（含 sub.fastora.top），加上「上次成功」
      // 最多 6 个候选。旧默认上限 4 → 只有最后那个能用时会静默放弃，
      // 与需求「任意一个域名拉到就行」冲突。
      final hosts = [
        'https://sub.moneyfly.dpdns.org',
        'https://moneyfly.dpdns.org',
        'https://new.moneyfly.dpdns.org',
        'https://sub.fastora.top',
        'https://fastora.top',
      ];
      const token = 'abc123';
      final tried = <String>[];
      final primary = 'https://dy.moneyfly.top/api/v1/client/subscribe?token=$token';
      final backups = [for (final h in hosts) '$h/api/v1/client/subscribe?token=$token'];

      final r = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: backups,
        fetch: (u) async {
          tried.add(u);
          // 只有最后一个候选（fastora.top）能用
          // 只有**最后一个**候选（https://fastora.top，注意不是 sub.fastora.top）能用
          if (u.contains('//fastora.top')) return 'proxies:\n  - {name: a}';
          throw Exception('blocked: $u');
        },
      );
      expect(r.url.contains('fastora.top'), isTrue);
      expect(tried.length, 6, reason: '主地址 + 5 个备用地址都应被尝试');
    });

    test('maxAttempts 限制尝试次数（避免用户长时间等待）', () async {
      final tried = <String>[];
      await expectLater(
        SubscribeUrlFailover.fetchFirst(
          primary: primary,
          backups: const [backup1, backup2],
          maxAttempts: 2,
          fetch: (url) async {
            tried.add(url);
            throw Exception('fail');
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(tried.length, 2);
    });
  });
}
