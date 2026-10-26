// 「点击即更新」整链路的回归测试（对齐 mclash 的更新体验）。
//
// 覆盖三件事：
//   1) 后台下载：幂等、sha256 校验、并发去重（后台预下载 + 用户点击会同时触发）；
//   2) 弹窗：发现新版本提示一次、点「稍后」记住版本不再烦、点「立即更新」进安装；
//   3) 安装：装之前先断开连接，再调起安装器；桌面端随后退出自己。
//
// 所有网络/安装器/退出动作都走测试缝，测试内不联网、不写系统、不退出进程。
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:mbox/core/services/update_service.dart';
import 'package:mbox/widgets/update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateInfo _info(String version,
        {String sha256 = '', String? url, String? name, int sizeBytes = 0}) =>
    UpdateInfo(
      latestVersion: version,
      downloadUrl: url ?? 'https://example.com/$version.pkg',
      sizeText: '1 MB',
      assetName: name ?? 'MBox-macos-arm64-$version.dmg',
      sha256: sha256,
      sizeBytes: sizeBytes,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.resetForTest();
    UpdatePrompt.debugReset();
    tmp = await Directory.systemTemp.createTemp('mf_update_test');
    UpdateService.debugCacheDir = () async => tmp;
  });

  tearDown(() async {
    UpdateService.resetForTest();
    UpdatePrompt.debugReset();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('版本比较', () {
    test('按数值逐段比，段数不同也正确（0.0.10 > 0.0.9）', () {
      UpdateInfo.currentVersion = '0.0.9';
      expect(_info('0.0.10').isNewer, isTrue);
      expect(_info('0.0.9').isNewer, isFalse);
      expect(_info('0.1.0').isNewer, isTrue);
    });
  });

  group('CheckService：check 与红点', () {
    test('check 命中新版本 → hasUpdate 为 true 且缓存 lastInfo', () async {
      UpdateInfo.currentVersion = '1.0.0';
      UpdateService.debugCheckOverride = () async => _info('1.0.1');
      final info = await UpdateService.instance.check();
      expect(info?.latestVersion, '1.0.1');
      expect(UpdateService.hasUpdate.value, isTrue);
      expect(UpdateService.lastInfo?.latestVersion, '1.0.1');
    });

    test('已是最新 → hasUpdate 为 false', () async {
      UpdateInfo.currentVersion = '1.0.1';
      UpdateService.debugCheckOverride = () async => _info('1.0.1');
      await UpdateService.instance.check();
      expect(UpdateService.hasUpdate.value, isFalse);
    });
  });

  group('后台下载：幂等 / 校验 / 并发去重', () {
    test('下载成功 → 返回路径；再次调用不再重复下载（幂等）', () async {
      var calls = 0;
      UpdateService.debugDownloadOverride = (url, path) async {
        calls++;
        await File(path).writeAsString('fake-installer');
      };
      final info = _info('1.0.1');

      final p1 = await UpdateService.instance.downloadInstaller(info: info);
      final p2 = await UpdateService.instance.downloadInstaller(info: info);
      expect(p1, isNotNull);
      expect(File(p1!).existsSync(), isTrue);
      expect(p2, p1);
      expect(calls, 1, reason: '已下好还重复下载会白白耗流量');
      expect(UpdateService.downloadProgress.value, 1);
    });

    test('sha256 不匹配 → 删掉文件并返回 null（宁可重下也不装坏包）', () async {
      UpdateService.debugDownloadOverride = (url, path) async {
        await File(path).writeAsString('corrupted');
      };
      final info = _info('1.0.1', sha256: 'a' * 64); // 故意给错误的哈希

      final p = await UpdateService.instance.downloadInstaller(info: info);
      expect(p, isNull);
      // 目录里不应留下坏包
      final left = tmp
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dmg'))
          .toList();
      expect(left, isEmpty);
    });

    test('sha256 匹配 → 正常返回', () async {
      // 真实 sha256 由 crypto 计算，这里用一个已知内容的哈希
      const content = 'ok';
      final expectHash = _sha256Hex(content);
      UpdateService.debugDownloadOverride = (url, path) async {
        await File(path).writeAsString(content);
      };
      final p = await UpdateService.instance
          .downloadInstaller(info: _info('1.0.1', sha256: expectHash));
      expect(p, isNotNull);
    });

    test('并发去重：后台预下载与用户点击同时触发也只下一次', () async {
      var calls = 0;
      UpdateService.debugDownloadOverride = (url, path) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await File(path).writeAsString('x');
      };
      final info = _info('1.0.1');
      final results = await Future.wait([
        UpdateService.instance.downloadInstaller(info: info),
        UpdateService.instance.downloadInstaller(info: info),
      ]);
      expect(calls, 1, reason: '两个写入方写同一个文件会把安装包写坏');
      expect(results[0], results[1]);
    });

    test('downloadedInstaller：没下过返回 null，下过返回路径', () async {
      final info = _info('1.0.1');
      expect(await UpdateService.instance.downloadedInstaller(info), isNull);
      UpdateService.debugDownloadOverride =
          (url, path) async => File(path).writeAsString('x');
      final p = await UpdateService.instance.downloadInstaller(info: info);
      expect(await UpdateService.instance.downloadedInstaller(info), p);
    });

    test('launchInstaller 走测试缝并回传结果', () async {
      UpdateService.debugLaunchInstallerOverride = (path) async =>
          path.endsWith('.dmg');
      expect(await UpdateService.instance.launchInstaller('/tmp/a.dmg'), isTrue);
      expect(await UpdateService.instance.launchInstaller('/tmp/a.exe'), isFalse);
    });
  });

  group('弹窗与一键更新（widget）', () {
    // 说明：这两条用例刻意**不**在 runAsync 里 await 弹窗流程 ——
    // 弹窗会一直等到用户点按钮，包在 runAsync 里就是死锁（实测把整轮测试挂死）。
    // 文件也都用同步 API 造好，避免真实 I/O 与 fake-async 泵冲突。
    Future<void> pumpHost(WidgetTester tester, void Function(BuildContext) onCtx) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          onCtx(c);
          return const SizedBox();
        }),
      ));
    }

    testWidgets('发现新版本 → 弹窗；点「稍后」记住版本，同版本不再弹', (tester) async {
      UpdateInfo.currentVersion = '1.0.0';
      UpdateService.debugCheckOverride = () async => _info('1.0.1');
      await UpdateService.instance.check();

      late BuildContext ctx;
      await pumpHost(tester, (c) => ctx = c);

      final flow = UpdatePrompt.maybePromptOnLaunch(ctx); // 不 await
      await tester.pump(); // 跑完内部 await（读设置）
      await tester.pumpAndSettle();

      expect(find.textContaining('1.0.1'), findsWidgets);
      expect(find.text('稍后'), findsOneWidget);
      expect(find.text('立即更新'), findsOneWidget);

      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      await flow;

      expect((await SettingsStore.instance.load())['dismissedUpdateVersion'],
          '1.0.1');

      // 同版本再次进入 → 不再打扰
      UpdatePrompt.debugReset();
      final again = UpdatePrompt.maybePromptOnLaunch(ctx);
      await tester.pumpAndSettle();
      await again;
      expect(find.text('立即更新'), findsNothing);
    });

    testWidgets('点「立即更新」：已下好 → 调起安装器 → 提示后退出进程', (tester) async {
      UpdateInfo.currentVersion = '1.0.0';
      // 宿主平台与「是否支持应用内安装」解耦：CI 在 ubuntu 上跑，真实值恒为 false，
      // 不固定它这条用例在 Linux 上必红（v2.2.9 实测踩过）
      UpdateService.debugCanInstallInApp = true;
      final info = _info('1.0.1');
      // 同步把安装包放到缓存目录（等价于「后台预下载已完成」）
      final dir = Directory('${tmp.path}/update')..createSync(recursive: true);
      File('${dir.path}/${info.assetName}').writeAsStringSync('installer');

      String? launched;
      UpdateService.debugLaunchInstallerOverride = (path) async {
        launched = path;
        return true;
      };
      // macOS 走的是「就地安装」（挂 DMG → 替换 /Applications 里的 App），
      // 不再是 open <dmg>；两条分支都注入，用例在 macOS 与 Linux CI 上都能跑
      String? macInstalled;
      UpdateService.debugInstallMacOverride = (dmg) async {
        macInstalled = dmg;
        return Platform.isMacOS
            ? MacInstallResult.installed
            : MacInstallResult.openedExternally;
      };
      var exited = -1;
      UpdatePrompt.debugExitOverride = (code) => exited = code;

      late BuildContext ctx;
      await pumpHost(tester, (c) => ctx = c);

      final flow = UpdatePrompt.installNow(ctx, info: info); // 不 await
      await tester.pump();
      await tester.pumpAndSettle();

      if (Platform.isMacOS) {
        expect(macInstalled, isNotNull, reason: 'macOS 应走就地安装');
        expect(find.textContaining('已更新到'), findsOneWidget);
      } else {
        expect(launched, isNotNull, reason: '应调起系统安装器');
        expect(find.textContaining('安装程序已启动'), findsOneWidget);
      }

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await flow;

      expect(exited, 0, reason: '装完必须退出自己，否则安装器无法替换被占用的文件');
    });

    testWidgets('移动端（Android / iOS）→ 打开下载页，绝不做应用内安装', (tester) async {
      UpdateInfo.currentVersion = '1.0.0';
      UpdateService.debugCanInstallInApp = false;
      final info = _info('1.0.1');
      final dir = Directory('${tmp.path}/update')..createSync(recursive: true);
      File('${dir.path}/${info.assetName}').writeAsStringSync('installer');

      var launchedInstaller = false;
      UpdateService.debugLaunchInstallerOverride = (path) async {
        launchedInstaller = true;
        return true;
      };
      // 必须拦掉真实 url_launcher：测试环境里它的通道调用永不返回（会挂死整轮）
      String? openedUrl;
      UpdatePrompt.debugOpenUrlOverride = (url) async => openedUrl = url;

      late BuildContext ctx;
      await pumpHost(tester, (c) => ctx = c);
      final flow = UpdatePrompt.installNow(ctx, info: info);
      await tester.pump();
      await tester.pumpAndSettle();
      await flow;

      expect(launchedInstaller, isFalse,
          reason: '移动端不走应用内安装（安卓需 FileProvider+安装意图，真机行为无法在'
              '开发机验证；iOS 系统不允许自更新）→ 只能给下载页');
      expect(openedUrl, isNotNull, reason: '应打开与本机架构匹配的下载地址');
    });

    testWidgets('没有下载地址时给出明确提示，不静默', (tester) async {
      UpdateInfo.currentVersion = '1.0.0';
      final info = UpdateInfo(latestVersion: '1.0.1'); // 无 url / 无 assetName
      late BuildContext ctx;
      await pumpHost(tester, (c) => ctx = c);

      final flow = UpdatePrompt.installNow(ctx, info: info);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining('下载链接暂未配置'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await flow;
    });
  });
}

/// 与实现一致的 sha256（crypto 包）
String _sha256Hex(String s) => sha256.convert(s.codeUnits).toString();
