import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/api/server_pool.dart';
import 'package:moneyfly/core/services/subscribe_url_failover.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「软件设置里换了服务器线路 → 重启后必须**以新线路的域名拉订阅**」。
///
/// 生产背景（用户反馈）：在设置里切到另一条线路后，更新订阅仍然失败 ——
/// 旧实现把「上次成功的订阅地址」永远排第一（订阅地址带域名），
/// 而用户换线路通常正是因为那个旧域名在其网络打不开，
/// 于是换线路后依然先撞旧域名：要么白等一次连接超时，要么直接提示拉取失败。
///
/// 修复：按**当前线路**改写订阅地址的域名（token 不变，同一份订阅），并让它排最前。
const _yaml = '''
proxies:
  - {name: ok, server: 198.51.100.10, port: 443, type: ss, password: pw, cipher: aes-128-gcm}
''';

const _token = 'token=abcdef0123456789';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('rewriteToActiveLine（按当前线路改写订阅域名）', () {
    test('换到备用线路后：订阅地址改为该线路域名，path/query（含 token）保持不变', () async {
      final pool = ServerPool.instance;
      await pool.reset();
      final backup = pool.all[1];
      await pool.markWorking(backup);

      final rewritten = pool.rewriteToActiveLine(
          'https://dy.moneyfly.top/api/v1/client/subscribe?$_token&type=clash');
      final host = Uri.parse(backup).host;
      expect(rewritten, contains(host), reason: '必须改写到当前线路的域名');
      expect(rewritten, contains('/api/v1/client/subscribe'), reason: 'path 不能变');
      expect(rewritten, contains(_token), reason: 'token 不能变（同一份订阅）');
      expect(rewritten, contains('type=clash'), reason: 'query 不能丢');
    });

    test('自定义域名（含端口）也照改', () async {
      final pool = ServerPool.instance;
      await pool.setCustom('http://192.168.1.5:8000');
      final rewritten = pool.rewriteToActiveLine(
          'https://dy.moneyfly.top/api/v1/client/subscribe?$_token');
      expect(rewritten, startsWith('http://192.168.1.5:8000/api/v1/client/subscribe'));
      await pool.reset();
    });

    test('已经是当前线路 → 返回空串（不做无意义改写）', () async {
      final pool = ServerPool.instance;
      await pool.reset();
      final base = Uri.parse(pool.activeBase);
      final url = '${base.scheme}://${base.authority}/api/v1/client/subscribe?$_token';
      expect(pool.rewriteToActiveLine(url), '');
    });

    test('非法地址（相对路径 / 非 http）→ 返回空串，不改写', () async {
      final pool = ServerPool.instance;
      await pool.reset();
      await pool.markWorking(pool.all[1]);
      expect(pool.rewriteToActiveLine(''), '');
      expect(pool.rewriteToActiveLine('/api/v1/client/subscribe?$_token'), '');
      expect(pool.rewriteToActiveLine('ftp://a.example/x?$_token'), '');
      await pool.reset();
    });
  });

  group('候选顺序：当前线路最优先', () {
    const old = 'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?$_token&type=clash';
    const primary = 'https://dy.moneyfly.top/api/v1/client/subscribe?$_token&type=clash';
    const pinned = 'https://fastora.top/api/v1/client/subscribe?$_token&type=clash';

    test('pinned（新线路）排在「上次成功的旧域名」之前', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        backups: const [],
        preferred: old, // 上次成功的是旧域名（正是打不开的那个）
        pinned: pinned, // 用户刚切到的新线路
      );
      expect(list.first, pinned, reason: '换线路后必须先用新线路的域名拉订阅');
      expect(list, contains(old), reason: '旧域名仍作为兜底保留');
    });

    test('没有 pinned 时保持原行为（上次成功的优先）', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        preferred: old,
      );
      expect(list.first, old);
    });

    test('pinned 的 token 与主地址不同 → 不采用（可能是别人的订阅）', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        pinned: 'https://fastora.top/api/v1/client/subscribe?token=othertoken',
      );
      expect(list, isNot(contains('https://fastora.top/api/v1/client/subscribe?token=othertoken')));
      expect(list.first, primary);
    });

    test('pinned 与其它候选重复时只出现一次', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        backups: const [pinned],
        pinned: pinned,
      );
      expect(list.where((u) => u == pinned).length, 1);
      expect(list.first, pinned);
    });
  });

  group('端到端：换线路后按新域名拉取', () {
    test('旧域名打不开时，第一次就试新线路（不再先撞旧域名）', () async {
      final tried = <String>[];
      final result = await SubscribeUrlFailover.fetchFirst(
        primary: 'https://dy.moneyfly.top/api/v1/client/subscribe?$_token&type=clash',
        backups: const [
          'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?$_token&type=clash',
        ],
        // 上次成功的是旧域名（用户正是因为它在自己网络打不开才换的线路）
        preferred: 'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?$_token&type=clash',
        // 用户刚把线路切到 fastora.top
        pinned: 'https://fastora.top/api/v1/client/subscribe?$_token&type=clash',
        fetch: (u) async {
          tried.add(Uri.parse(u).host);
          if (Uri.parse(u).host == 'fastora.top') return _yaml;
          throw StateError('该域名不可达: $u');
        },
        looksUsable: (raw) => raw.contains('proxies:'),
      );

      expect(result.url, contains('fastora.top'));
      expect(tried.first, 'fastora.top',
          reason: '换线路后必须**首先**用新线路拉订阅（否则又是「换线路仍拉取失败」）');
      expect(tried, hasLength(1), reason: '新线路可用就不该再去撞旧域名');
    });

    test('新线路也不可用时，仍按候选顺序继续兜底（不因新线路失败而彻底放弃）', () async {
      final tried = <String>[];
      final result = await SubscribeUrlFailover.fetchFirst(
        primary: 'https://dy.moneyfly.top/api/v1/client/subscribe?$_token&type=clash',
        preferred: 'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?$_token&type=clash',
        pinned: 'https://fastora.top/api/v1/client/subscribe?$_token&type=clash',
        fetch: (u) async {
          final host = Uri.parse(u).host;
          tried.add(host);
          if (host == 'dy.moneyfly.top') return _yaml;
          throw StateError('不可达: $u');
        },
        looksUsable: (raw) => raw.contains('proxies:'),
      );

      expect(tried.first, 'fastora.top', reason: '先试新线路');
      expect(result.url, contains('dy.moneyfly.top'), reason: '新线路失败要能兜底到主地址');
    });
  });
}
