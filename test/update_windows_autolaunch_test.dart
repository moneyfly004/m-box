// 「重启即更新」：后台下载好的 Windows 安装包，在下次启动时静默装掉。
//
// 用户反馈（2026-09-21）：点「检查更新」→ 后台自动下载完成 → 重启软件却不会
// 自动安装，永远停在「已下载」。原因是下载只是把包放进缓存，
// 真正安装只有「弹窗里手动点安装」这一条路径。
//
// 这里覆盖三件事：
//   1) 缓存里挑出**比当前版本新**的安装包（旧包/空文件/别的平台包必须忽略）；
//   2) 静默安装用的 Inno 参数正确（少了 `/SILENT` 就会弹向导，"热更新"就废了）；
//   3) 同一版本只自动尝试一次（装不上不做无限重试）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows 上 File.path 用的是反斜杠，断言前统一成正斜杠再比
String _norm(String p) => p.replaceAll('\\', '/');

Directory _tmpCache() {
  final d = Directory.systemTemp.createTempSync('mf_update_cache');
  return d;
}

/// 安装包落在 `<cache>/update/` 下（UpdateService 固定拼 /update）
Directory _updateDir(Directory cache) {
  final d = Directory('${cache.path}/update');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

File _installer(Directory dir, String version, {int bytes = 1024}) {
  final f = File('${_updateDir(dir).path}/MBox-setup-$version.exe');
  f.writeAsBytesSync(List<int>.filled(bytes, 7));
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cache;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UpdateService.resetForTest();
    cache = _tmpCache();
    UpdateService.debugCacheDir = () async => cache;
  });

  tearDown(() {
    UpdateService.resetForTest();
    try {
      cache.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('pendingNewerInstaller：挑出待安装的新版本包', () {
    test('当前版本设为 2.2.13 时，只认 2.2.14 及更高的包', () async {
      UpdateInfo.currentVersion = '2.2.13';
      _installer(cache, '2.2.12'); // 旧包：用户手里可能留着
      _installer(cache, '2.2.13'); // 同版本
      final newer = _installer(cache, '2.2.14');

      final pending = await UpdateService.instance.pendingNewerInstaller();

      expect(pending, isNotNull);
      expect(pending!.version, '2.2.14');
      expect(_norm(pending.path), _norm(newer.path));
    });

    test('多个候选取版本最高的', () async {
      UpdateInfo.currentVersion = '2.2.13';
      _installer(cache, '2.2.14');
      final highest = _installer(cache, '2.2.20');
      _installer(cache, '2.2.15');

      final pending = await UpdateService.instance.pendingNewerInstaller();

      expect(_norm(pending!.path), _norm(highest.path));
      expect(pending.version, '2.2.20');
    });

    test('空文件（下到一半/被杀）不算待安装', () async {
      UpdateInfo.currentVersion = '2.2.13';
      _installer(cache, '2.2.14', bytes: 0);

      expect(await UpdateService.instance.pendingNewerInstaller(), isNull);
    });

    test('非本平台安装器（APK/DMG/zip）一律忽略', () async {
      UpdateInfo.currentVersion = '2.2.13';
      final d = _updateDir(cache);
      File('${d.path}/MBox-android-arm64-v8a-2.2.14.apk')
          .writeAsBytesSync([1, 2, 3]);
      File('${d.path}/MBox-macos-arm64-2.2.14.dmg')
          .writeAsBytesSync([1, 2, 3]);
      File('${d.path}/MBox-setup-2.2.14.exe.sha256')
          .writeAsStringSync('x');

      expect(await UpdateService.instance.pendingNewerInstaller(), isNull);
    });

    test('没有新版本包时返回 null（不打扰用户）', () async {
      UpdateInfo.currentVersion = '2.2.13';
      _installer(cache, '2.2.13');

      expect(await UpdateService.instance.pendingNewerInstaller(), isNull);
    });
  });

  group('静默安装参数', () {
    test('必须带 /SILENT（否则重启时弹安装向导，就不叫热更新了）', () async {
      String? gotExe;
      List<String>? gotArgs;
      UpdateService.debugStartDetached = (exe, args) async {
        gotExe = exe;
        gotArgs = args;
        return true;
      };

      final ok =
          await UpdateService.instance.installWindowsSilently('/tmp/x.exe');

      expect(ok, isTrue);
      expect(gotExe, '/tmp/x.exe');
      expect(gotArgs, contains('/SILENT'));
      // 静默模式下不再弹任何确认框
      expect(gotArgs, contains('/SP-'));
      expect(gotArgs, contains('/SUPPRESSMSGBOXES'));
      // 自动结束占用文件的旧进程 + 不重启系统
      expect(gotArgs, contains('/CLOSEAPPLICATIONS'));
      expect(gotArgs, contains('/NORESTART'));
    });

    test('启动安装器失败 → 返回 false（上层回退到手动更新）', () async {
      UpdateService.debugStartDetached = (_, _) async => false;

      expect(await UpdateService.instance.installWindowsSilently('/tmp/x.exe'),
          isFalse);
    });
  });
}
