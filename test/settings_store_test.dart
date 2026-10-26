import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('update 原子读改写，并合并默认值', () async {
    final store = SettingsStore.instance;
    await store.update((s) => s['lastSelectedTag'] = 'foo');
    final loaded = await store.load();
    expect(loaded['lastSelectedTag'], 'foo');
    // 未改动的字段仍按默认值合并
    expect(loaded['localPort'], 2080);
    expect(loaded['dnsNameservers'], ['223.5.5.5', '119.29.29.29']);
  });

  test('reset 回到默认值', () async {
    final store = SettingsStore.instance;
    await store.update((s) => s['localPort'] = 9999);
    expect((await store.load())['localPort'], 9999);
    await store.reset();
    expect((await store.load())['localPort'], 2080);
  });

  group('遗留 http 测速地址迁移', () {
    // 2.1.x 的默认值是明文 http，而设置是整份持久化的 → 不迁移就会一直沿用，
    // 表现为内核日志满屏 `failed to get the second response from http://...`
    // （明文可被劫持 + 内核自己都会警告改用 HTTPS），并让在线节点被误判掉线。
    test('旧默认值 http → 迁移到 https', () async {
      final store = SettingsStore.instance;
      await store.update(
          (s) => s['testUrl'] = SettingsStore.legacyHttpTestUrl);
      expect((await store.load())['testUrl'], SettingsStore.defaultTestUrl);
    });

    test('用户自定义地址（含自建 http 端点）不被改动', () async {
      final store = SettingsStore.instance;
      await store.update((s) => s['testUrl'] = 'http://192.168.1.10/204');
      expect((await store.load())['testUrl'], 'http://192.168.1.10/204');
    });

    test('默认值本身是 https', () async {
      await SettingsStore.instance.reset();
      final loaded = await SettingsStore.instance.load();
      expect(loaded['testUrl'], SettingsStore.defaultTestUrl);
      expect(loaded['testUrl'], startsWith('https://'));
    });
  });
}
