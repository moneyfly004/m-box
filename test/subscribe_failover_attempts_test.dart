import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/services/subscribe_url_failover.dart';

/// 客户 henry11 真实情形：面板下发的 5~6 个订阅域名里，只有**最后一个**
/// （Cloudflare 前置的那个）在其网络可达。此前候选按实测测速重排 + 上限 6 个，
/// 可用域名可能被排到上限之外、永远轮不到 → 客户端静默放弃（表现为"无法拉取订阅"）。
/// 这条用例钉住：前面的域名全部失败时，仍会继续试到能用的那个。
const _yaml = '''
proxies:
  - {name: ok, server: 198.51.100.10, port: 443, type: ss, password: pw, cipher: aes-128-gcm}
''';

void main() {
  test('前面的域名全部失败时仍继续尝试，直到能用的那个（不被排序+上限截断）',
      () async {
    const token = 'token=abcdef0123456789';
    final tried = <String>[];
    final result = await SubscribeUrlFailover.fetchFirst(
      primary: 'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?$token&type=clash',
      backups: [
        'https://moneyfly.dpdns.org/api/v1/client/subscribe?$token&type=clash',
        'https://new.moneyfly.dpdns.org/api/v1/client/subscribe?$token&type=clash',
        'https://sub.fastora.top/api/v1/client/subscribe?$token&type=clash',
        'https://fastora.top/api/v1/client/subscribe?$token&type=clash',
        // 唯一可达的那个（Cloudflare 前置）
        'https://dy.moneyfly.top/api/v1/client/subscribe?$token&type=clash',
      ],
      // 故意让排序把"能用的那个"排到后面：前面都返回 0，最后那个返回更高分
      hostPriority: (u) => u.contains('dy.moneyfly.top') ? 999 : 0,
      fetch: (u) async {
        final host = Uri.parse(u).host;
        tried.add(host);
        if (host == 'dy.moneyfly.top') return _yaml;
        throw StateError('该域名在客户网络不可达: $host');
      },
      looksUsable: (raw) => raw.contains('proxies:'),
    );

    expect(result.url, contains('dy.moneyfly.top'));
    expect(tried, hasLength(6), reason: '6 个候选都要轮到（上限不能被截断）');
    expect(tried.last, 'dy.moneyfly.top');
  });

  test('全部失败时抛出最后一次错误（不返回值，由调用方如实提示）', () async {
    await expectLater(
      SubscribeUrlFailover.fetchFirst(
        primary: 'https://a.example/api/v1/client/subscribe?token=t',
        backups: ['https://b.example/api/v1/client/subscribe?token=t'],
        fetch: (u) async => throw StateError('不可达 $u'),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
