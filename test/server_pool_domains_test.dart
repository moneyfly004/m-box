// 域名池覆盖 —— 单测（独立文件，避免污染既有的 server_pool_test.dart）。
//
// 需求（2026-09-26 客户/老板明确）：软件有多个域名，**任何一个都能登录、都能拉订阅**，
// 某一个不可用时自动轮换到下一个，直到有一个成功为止（成功即停）。
// 线上实测（6 个域名全部可用）：
//   登录：dy.moneyfly.top / moneyfly.dpdns.org / sub.moneyfly.dpdns.org /
//         new.moneyfly.dpdns.org / sub.fastora.top / fastora.top  全部 200
//   订阅信息 /user/subscribe：6 个全部 200（同一份数据、设备数一致）
//   订阅正文 /client/subscribe：6 个全部 200（457KB clash-yaml）
// 而代码里的池只有 4 个（缺 fastora 两个）→ 这两个域名挂掉时无法轮换到它们，
// 且「只有最后那个域名能用」的场景会直接失败。

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/api/server_pool.dart';

void main() {
  group('域名池必须覆盖线上全部域名', () {
    const expected = [
      'https://dy.moneyfly.top/api/v1',
      'https://moneyfly.dpdns.org/api/v1',
      'https://sub.moneyfly.dpdns.org/api/v1',
      'https://new.moneyfly.dpdns.org/api/v1',
      'https://sub.fastora.top/api/v1',
      'https://fastora.top/api/v1',
    ];

    test('6 个域名一个都不能少', () {
      for (final d in expected) {
        expect(ServerPool.domains, contains(d),
            reason: '缺少 $d → 该域名不可用时无法轮换到它（客户登不上/拉不到订阅）');
      }
      expect(ServerPool.domains.length, greaterThanOrEqualTo(expected.length));
    });

    test('形态正确：https + /api/v1 结尾 + 无重复', () {
      final seen = <String>{};
      for (final d in ServerPool.domains) {
        expect(d.startsWith('https://'), isTrue, reason: d);
        expect(d.endsWith('/api/v1'), isTrue, reason: d);
        expect(seen.add(d), isTrue, reason: '重复域名: $d');
      }
    });

    test('主域名排在最前（没切换过时优先用它，避免每次先撞墙）', () {
      expect(ServerPool.domains.first, 'https://dy.moneyfly.top/api/v1');
    });

    test('任取一个域名都能构造出可用基底（轮换不会拿到空地址）', () {
      for (final d in ServerPool.domains) {
        expect(Uri.parse(d).host.isNotEmpty, isTrue, reason: d);
      }
    });
  });
}
