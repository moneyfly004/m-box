// 「固定节点 / 锁定国家」语义回归。
//
// 用户定义的规则（2026-09-21 明确）：
//   1) 首页点**国家**格 → 只锁国家：该国范围内自动挑最优，**允许换节点**；
//   2) 点**节点**（首页节点弹层 / 节点页 / 切换入口）→ **固定这个节点**，
//      后台测速、自动选优、慢线回落一律不换；
//   3) 点**自动选择最优** → 解锁节点固定与国家锁，回到所有国家里选最优。
//
// 这里覆盖纯状态语义（不启内核：status=disconnected 时切换只改内存态），
// 以及持久化（重启后固定节点/锁定国家要恢复）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProxyNode _node(String tag, String cc, int ms) => ProxyNode(
      tag: tag,
      type: 'ss',
      server: '1.2.3.4',
      port: 8388,
      countryCode: cc,
      latencyMs: ms,
      raw: const {},
    );

final _hk1 = _node('HK-1', 'HK', 120);
final _hk2 = _node('HK-2', 'HK', 60);
final _us1 = _node('US-1', 'US', 200);
final _jp1 = _node('JP-1', 'JP', 80);

void _seed(ConnectionController c) {
  c.nodes = [_hk1, _hk2, _us1, _jp1];
  c.status = ConnStatus.disconnected;
  c.pinnedTag = null;
  c.lockedCountry = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('点节点 = 固定节点', () {
    test('switchNode（用户点击）会固定该节点，并解除国家锁', () async {
      final c = ConnectionController.instance;
      _seed(c);
      c.lockedCountry = 'HK'; // 之前锁的是国家

      await c.switchNode(_us1); // 用户点了 US-1 这个具体节点

      expect(c.pinnedTag, 'US-1');
      expect(c.lockedCountry, isNull, reason: '固定节点是国家锁的更强形式，二者互斥');
      expect(c.current?.tag, 'US-1');
    });

    test('固定后，自动策略（后台测速/回落）不再换节点', () async {
      final c = ConnectionController.instance;
      _seed(c);
      await c.switchNode(_hk1);
      expect(c.pinnedTag, 'HK-1');

      // 自动选优：即使别的节点更快/当前节点被判定离线，也不许换
      await c.switchNode(_hk2, userInitiated: false);

      expect(c.pinnedTag, 'HK-1', reason: '自动切换不得改动用户的固定');
    });

    test('固定节点会持久化，重启后能恢复该节点', () async {
      final c = ConnectionController.instance;
      _seed(c);
      await c.switchNode(_jp1);
      // 等持久化写入队列落盘（SettingsStore 单写队列）
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final store = await SettingsStore.instance.load();
      expect(store['pinTag'], 'JP-1');
      expect(store['lastSelectedTag'], 'JP-1');
      expect(store['lockCountry'], isNull);
    });
  });

  group('点国家 = 锁国家（国内自动选最优）', () {
    test('switchCountry 锁定国家、解除节点固定，并切到该国最优节点', () async {
      final c = ConnectionController.instance;
      _seed(c);
      await c.switchNode(_us1); // 先固定一个美国节点
      expect(c.pinnedTag, 'US-1');

      final ok = await c.switchCountry('HK');

      expect(ok, isTrue);
      expect(c.lockedCountry, 'HK');
      expect(c.pinnedTag, isNull, reason: '锁国家与固定节点互斥');
      expect(c.current?.tag, 'HK-2', reason: 'HK 国内延迟最低的是 HK-2（60ms）');
    });

    test('锁定国内没有节点 → 不改变现状', () async {
      final c = ConnectionController.instance;
      _seed(c);
      await c.switchNode(_hk1);

      final ok = await c.switchCountry('DE');

      expect(ok, isFalse);
      expect(c.pinnedTag, 'HK-1', reason: '无效点击不应破坏用户当前的选择');
      expect(c.lockedCountry, isNull);
    });

    test('解除固定、改成锁国家后，持久化里不会残留 pinTag', () async {
      final c = ConnectionController.instance;
      _seed(c);
      await c.switchNode(_us1);
      await c.switchCountry('HK');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final store = await SettingsStore.instance.load();
      expect(store['lockCountry'], 'HK');
      expect(store['pinTag'], isNull, reason: '残留 pinTag 会让重启后又变回固定节点');
    });
  });

  group('自动选择最优 = 全部解锁', () {
    test('unlockSelection 同时清掉固定节点与国家锁', () async {
      final c = ConnectionController.instance;
      _seed(c);
      await c.switchNode(_jp1);

      await c.unlockSelection();

      expect(c.pinnedTag, isNull);
      expect(c.lockedCountry, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final store = await SettingsStore.instance.load();
      expect(store['pinTag'], isNull);
      expect(store['lockCountry'], isNull);
      // lastSelectedTag 在设置默认值里是空串（被 remove 后 load 会回落到默认 ''）
      expect('${store['lastSelectedTag'] ?? ''}', isEmpty);
    });
  });

  group('订阅变化时的兜底', () {
    test('固定节点在新订阅里消失 → 自动解除固定（不留死线路）', () async {
      final c = ConnectionController.instance;
      _seed(c);
      await c.switchNode(_us1);
      expect(c.pinnedTag, 'US-1');

      // 新订阅里没有 US-1 了
      await c.applySubscriptionNodes([_hk1, _hk2, _jp1]);

      expect(c.pinnedTag, isNull);
    });

    test('固定节点仍在订阅里 → 固定保持不动', () async {
      final c = ConnectionController.instance;
      _seed(c);
      await c.switchNode(_us1);

      await c.applySubscriptionNodes([_hk1, _us1, _jp1]);

      expect(c.pinnedTag, 'US-1');
      expect(c.current?.tag, 'US-1', reason: '订阅刷新不得丢掉当前固定线路');
    });
  });
}
