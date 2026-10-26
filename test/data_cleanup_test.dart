import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/services/app_data_cleaner.dart';
import 'package:mbox/core/services/local_paths.dart';
import 'package:mbox/core/services/subscription_cache.dart';
import 'package:mbox/core/services/update_service.dart';

/// 本地数据清理 / 订阅缓存 单测：
/// - 订阅缓存：写入 → 同版本读取 → 版本升级失效删除 → 清除；
/// - 首启清理（install_id 缺失 = 全新安装/数据被清）：旧缓存与偏好被清除、
///   标记被写入；
/// - 老安装启动：仅让版本过期的缓存失效（同版本缓存保留，下次启动可兜底）。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mf_cleanup_test');
    // 注入 support 目录：flutter test 无 path_provider 平台实现
    LocalPaths.debugSupportDir = () async => tmp;
    SharedPreferences.setMockInitialValues({});
    UpdateInfo.currentVersion = '9.9.9';
  });

  tearDown(() {
    LocalPaths.debugSupportDir = null;
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<File> cacheFile() async {
    final dir = await LocalPaths.supportDir();
    return File('${dir!.path}/${SubscriptionCache.fileName}');
  }

  group('SubscriptionCache', () {
    test('写入后可读（版本一致），clear 后消失', () async {
      await SubscriptionCache.instance
          .write(subscribeUrl: 'https://sub.example.com/x?token=a', raw: 'proxies: []');
      final hit = await SubscriptionCache.instance.readLatest();
      expect(hit, isNotNull);
      expect(hit!.subscribeUrl, 'https://sub.example.com/x?token=a');
      expect(hit.raw, 'proxies: []');
      expect(await cacheFile().then((f) => f.exists()), isTrue);

      await SubscriptionCache.instance.clear();
      expect(await cacheFile().then((f) => f.exists()), isFalse);
      expect(await SubscriptionCache.instance.readLatest(), isNull);
    });

    test('应用版本升级后旧缓存失效并自动删除（下次启动强制重拉）', () async {
      await SubscriptionCache.instance
          .write(subscribeUrl: 'https://sub.example.com', raw: 'proxies: []');
      UpdateInfo.currentVersion = '9.9.10'; // 模拟升级
      expect(await SubscriptionCache.instance.readLatest(), isNull);
      expect(await cacheFile().then((f) => f.exists()), isFalse);
    });

    test('损坏缓存被清除而非抛错', () async {
      final f = await cacheFile();
      await f.writeAsString('{not-json');
      expect(await SubscriptionCache.instance.readLatest(), isNull);
      expect(await f.exists(), isFalse);
    });
  });

  group('AppDataCleaner.cleanupOnLaunch', () {
    test('install_id 缺失（全新安装/数据被清）→ 清旧缓存与偏好并写标记', () async {
      // 模拟「卸载残留复活」：有旧缓存文件 + 旧偏好，但没有安装标记
      await SubscriptionCache.instance
          .write(subscribeUrl: 'https://old.example.com', raw: 'proxies: []');
      SharedPreferences.setMockInitialValues({
        'mbox_settings_v1': jsonEncode({'autoConnect': true, 'dns': '1.1.1.1'}),
        'mbox_auto_login': true,
        'mbox_lang': 'en',
      });

      await AppDataCleaner.cleanupOnLaunch();

      // 旧缓存被清、标记已写入
      expect(await cacheFile().then((f) => f.exists()), isFalse);
      expect(await LocalPaths.markerExists(), isTrue);
      expect((await LocalPaths.readMarker()).length, 32);
      // 偏好被清（出厂状态）
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mbox_settings_v1'), isNull);
      expect(prefs.getBool('mbox_auto_login'), isNull);
    });

    test('老安装（标记存在）+ 版本一致 → 缓存保留（可作启动兜底）', () async {
      await LocalPaths.writeMarker();
      await SubscriptionCache.instance
          .write(subscribeUrl: 'https://sub.example.com', raw: 'proxies: []');

      await AppDataCleaner.cleanupOnLaunch();

      expect(await cacheFile().then((f) => f.exists()), isTrue);
      expect(await SubscriptionCache.instance.readLatest(), isNotNull);
    });

    test('老安装（标记存在）+ 版本过期 → 旧版本缓存被清', () async {
      await LocalPaths.writeMarker();
      await SubscriptionCache.instance
          .write(subscribeUrl: 'https://sub.example.com', raw: 'proxies: []');
      UpdateInfo.currentVersion = '9.9.10'; // 模拟升级到新版本

      await AppDataCleaner.cleanupOnLaunch();

      expect(await cacheFile().then((f) => f.exists()), isFalse);
    });
  });
}
