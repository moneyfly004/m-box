import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/api/server_pool.dart';
import 'package:moneyfly/core/services/subscribe_url_failover.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 线路优化的回归测试（①用户选择 vs 实际生效 ②兜底提示 ③失败冷却 ④并行竞速 ⑦诊断）。
///
/// 背景：换线路后订阅必须走新线路（已由 server_line_switch_test 覆盖），但还有四个
/// 真实体验问题：
///   · 自动兜底会**悄悄改掉**用户在设置里选的线路 → 用户以为"选了没用"；
///   · 兜底生效完全静默 → 用户不知道发生了什么；
///   · 每条不可达域名每次刷新都要白等一次连接超时（12s）→ "更新订阅像卡住"；
///   · 排查时看不到"哪个域名、什么原因失败"。
const _token = 'token=abcdef0123456789';
const _yaml = '''
proxies:
  - {name: ok, server: 198.51.100.10, port: 443, type: ss, password: pw, cipher: aes-128-gcm}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pool = ServerPool.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await pool.reset(); // 清指数/自定义/用户选择/冷却
    ServerPool.clearFallbackNotice();
  });

  group('① 用户选的线路 vs 实际生效', () {
    test('用户显式选线路 → 记为「你选的」；自动兜底只改实际生效，不动用户选择', () async {
      final chosen = pool.all[1];
      final auto = pool.all[2];

      await pool.markWorking(chosen, userInitiated: true);
      expect(pool.userPinnedHost, Uri.parse(chosen).host);
      expect(pool.onUserPinnedLine, isTrue);
      expect(pool.fellBackFromPin, isFalse);

      // 自动兜底（例如接口请求轮换成功）→ 实际生效变了，用户选择不变
      await pool.markWorking(auto);
      expect(pool.activeHost, Uri.parse(auto).host);
      expect(pool.userPinnedHost, Uri.parse(chosen).host,
          reason: '自动兜底不得改写用户在设置里选的线路');
      expect(pool.fellBackFromPin, isTrue);
      expect(pool.lineSummary(), contains('已自动兜底'));
    });

    test('一键回到我选的线路：清冷却 + 立即改为生效线路', () async {
      final chosen = pool.all[1];
      await pool.markWorking(chosen, userInitiated: true);
      await pool.markWorking(pool.all[2]);
      expect(pool.fellBackFromPin, isTrue);

      await pool.retryUserPinnedLine();
      expect(pool.activeBase, chosen);
      expect(pool.fellBackFromPin, isFalse);
      expect(pool.isRecentlyFailed(Uri.parse(chosen).host), isFalse,
          reason: '回到所选线路时必须清掉它的失败冷却，否则还是排在后面');
    });

    test('点「自动」→ 用户选择被清空（不再显示"你选的"）', () async {
      await pool.markWorking(pool.all[3], userInitiated: true);
      expect(pool.hasUserPin, isTrue);
      await pool.reset();
      expect(pool.hasUserPin, isFalse);
      expect(pool.lineSummary(), contains('自动'));
    });
  });

  group('② 兜底提示（一次性）', () {
    test('实际用的域名 ≠ 用户选的域名 → 置位提示，且同一组合不重复打扰', () {
      final chosen = pool.all[1];
      final other = pool.all[2];
      pool.markWorking(chosen, userInitiated: true);

      pool.noteEffectiveLine('https://${Uri.parse(other).host}/api/v1/client/subscribe?$_token');
      final notice = ServerPool.fallbackNotice.value;
      expect(notice, isNotNull, reason: '兜底生效必须让用户知道');
      expect(notice!.pinned, Uri.parse(chosen).host);
      expect(notice.active, Uri.parse(other).host);

      ServerPool.clearFallbackNotice();
      pool.noteEffectiveLine('https://${Uri.parse(other).host}/api/v1');
      expect(ServerPool.fallbackNotice.value, isNull,
          reason: '同一组「所选→实际」只提示一次，不反复打扰');
    });

    test('没选过线路（自动模式）不提示', () {
      pool.noteEffectiveLine(pool.all[4]);
      expect(ServerPool.fallbackNotice.value, isNull);
    });

    test('实际就在用户选的线路上 → 不提示', () {
      final chosen = pool.all[1];
      pool.markWorking(chosen, userInitiated: true);
      pool.noteEffectiveLine(chosen);
      expect(ServerPool.fallbackNotice.value, isNull);
    });
  });

  group('③ 失败域名冷却', () {
    test('失败后进入冷却：排序被排到未失败域名之后；成功后立即恢复', () {
      final a = Uri.parse(pool.all[1]).host;
      final b = Uri.parse(pool.all[2]).host;
      final before = pool.priorityOfHost(a);

      pool.noteDomainFailure('https://$a/api/v1');
      expect(pool.isRecentlyFailed(a), isTrue);
      expect(pool.priorityOfHost(a), greaterThan(before));
      expect(pool.priorityOfHost(a), greaterThan(pool.priorityOfHost(b)),
          reason: '刚失败的域名要排到未失败域名之后，避免每次刷新都先白等一次超时');

      pool.noteDomainSuccess('https://$a/api/v1');
      expect(pool.isRecentlyFailed(a), isFalse);
      expect(pool.priorityOfHost(a), before);
    });

    test('冷却到期自动恢复（不长期降级某条线路）', () {
      final a = Uri.parse(pool.all[1]).host;
      pool.debugSetFailureUntil(a, DateTime.now().subtract(const Duration(seconds: 1)));
      expect(pool.isRecentlyFailed(a), isFalse,
          reason: '冷却只应是短时间的兜底排序，不能永久降级');
    });

    test('用户手动换线路/网络变化时清空冷却', () async {
      final a = Uri.parse(pool.all[1]).host;
      pool.noteDomainFailure('https://$a/api/v1');
      expect(pool.isRecentlyFailed(a), isTrue);
      await pool.markWorking(pool.all[1], userInitiated: true);
      expect(pool.isRecentlyFailed(a), isFalse,
          reason: '「我选了这条」必须立刻生效，不被上次失败记录拦住');

      pool.noteDomainFailure('https://${Uri.parse(pool.all[2]).host}/api/v1');
      pool.clearFailureCooldown();
      expect(pool.isRecentlyFailed(Uri.parse(pool.all[2]).host), isFalse);
    });
  });

  group('⑦ 线路诊断', () {
    test('失败会留下「哪个域名、什么原因」的记录，摘要能说明所选/实际', () {
      final a = Uri.parse(pool.all[1]).host;
      pool.noteDomainFailure('https://$a/api/v1', kind: 'timeout');
      final diag = pool.diagnostics;
      expect(diag, isNotEmpty);
      expect(diag.first.host, a);
      expect(diag.first.kind, 'timeout');
      expect(diag.first.line, contains(a));
    });
  });

  group('④ 首尝试短超时 + 并行竞速', () {
    test('首个候选挂住不返回 → 短超时后立刻换下一个（不再白等 12s）', () async {
      const hanging = 'https://a.example/api/v1/client/subscribe?$_token';
      const good = 'https://b.example/api/v1/client/subscribe?$_token';
      final sw = Stopwatch()..start();

      final r = await SubscribeUrlFailover.fetchFirst(
        primary: hanging,
        backups: const [good],
        fetch: (u) async {
          if (u == hanging) {
            // 模拟"被墙"：连接一直不返回（真实场景由 12s 连接超时兜底）
            await Future<void>.delayed(const Duration(seconds: 30));
            throw StateError('永远不会到这里');
          }
          return _yaml;
        },
        looksUsable: (raw) => raw.contains('proxies:'),
        firstAttemptTimeout: const Duration(milliseconds: 150),
        raceWidth: 1,
      );
      sw.stop();

      expect(r.url, good);
      expect(sw.elapsedMilliseconds, lessThan(1500),
          reason: '首尝试超时必须让它快速让位，而不是等满连接超时');
    });

    test('首个失败后，接下来的候选并行竞速（并列发出，先可用者胜）', () async {
      const first = 'https://a.example/api/v1/client/subscribe?$_token';
      const slow = 'https://b.example/api/v1/client/subscribe?$_token';
      const fast = 'https://c.example/api/v1/client/subscribe?$_token';
      final started = <String>[];
      final sw = Stopwatch()..start();

      final r = await SubscribeUrlFailover.fetchFirst(
        primary: first,
        backups: const [slow, fast],
        fetch: (u) async {
          started.add(u);
          if (u == first) throw StateError('第一个不可达');
          // 两个候选都很慢：串行要 ~600ms，并行只需 ~300ms
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (u == fast) return _yaml;
          throw StateError('第二个也不可达');
        },
        looksUsable: (raw) => raw.contains('proxies:'),
        firstAttemptTimeout: const Duration(milliseconds: 100),
        raceWidth: 2,
      );
      sw.stop();

      expect(r.url, fast);
      expect(started, containsAll([slow, fast]),
          reason: '并行竞速应同时发出这两个候选');
      expect(sw.elapsedMilliseconds, lessThan(560),
          reason: '并行竞速应比串行（~600ms）明显更快');
    });

    test('失败原因分类回传（empty / content / 异常）', () async {
      final reasons = <String, String>{};
      const a = 'https://a.example/api/v1/client/subscribe?$_token';
      const b = 'https://b.example/api/v1/client/subscribe?$_token';
      const c = 'https://c.example/api/v1/client/subscribe?$_token';

      final r = await SubscribeUrlFailover.fetchFirst(
        primary: a,
        backups: const [b, c],
        fetch: (u) async {
          if (u == a) return ''; // 空内容
          if (u == b) return '<html>拦截页</html>'; // 不是订阅
          return _yaml;
        },
        looksUsable: (raw) => raw.contains('proxies:'),
        onAttemptFailed: (u, reason) => reasons[u] = reason,
        firstAttemptTimeout: const Duration(milliseconds: 200),
        raceWidth: 2,
      );

      expect(r.url, c);
      expect(reasons[a], 'empty');
      expect(reasons[b], 'content');
    });

    test('竞速下仍尊重尝试上限（不会因为并行而多打）', () async {
      var calls = 0;
      const p0 = 'https://a.example/api/v1/client/subscribe?$_token';
      const p1 = 'https://b.example/api/v1/client/subscribe?$_token';
      const p2 = 'https://c.example/api/v1/client/subscribe?$_token';

      await expectLater(
        SubscribeUrlFailover.fetchFirst(
          primary: p0,
          backups: const [p1, p2],
          fetch: (u) async {
            calls++;
            throw StateError('全不可达 $u');
          },
          maxAttempts: 2,
          raceWidth: 2,
          firstAttemptTimeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, 2, reason: 'maxAttempts=2 时最多只允许发出 2 次请求');
    });

    test('全部失败 → 抛出异常（不返回空内容、不静默）', () async {
      await expectLater(
        SubscribeUrlFailover.fetchFirst(
          primary: 'https://a.example/api/v1/client/subscribe?$_token',
          fetch: (u) async => throw StateError('不可达'),
          firstAttemptTimeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
