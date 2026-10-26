// macOS 自动更新的回归测试（用户实测反馈：点安装 → 提示「磁盘损坏」，装不上）。
//
// 两个真实缺陷：
//  1) **半截下载的包被当成「已就绪」**：`downloadedInstaller()` 只判
//     「文件存在且长度 > 0」。下载中途退出/断网留下的残包，之后每次点更新都直接
//     拿它去装 —— macOS 上就是挂载失败，用户看到「磁盘映像已损坏/无法识别」。
//  2) **macOS 根本没有「自动安装」**：旧实现 `open <dmg>` 只是把安装包丢给 Finder，
//     用户还得自己拖进「应用程序」；而拖出来的 App 一旦带上隔离属性，
//     ad-hoc 签名的 App 会被 Gatekeeper 直接判「已损坏，无法打开」。
//     现在自己做完整流程：挂载 → `ditto --noqtn` 复制出 .app → 清隔离属性 →
//     替换当前 App → 启动新版本。
//
// 另外补上此前缺失的**应急预案**：自动更新任何一步失败，都要能一键跳转到
// GitHub Releases 页面手动下载，并给出「已损坏」的成因与修复命令。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/services/update_service.dart';
import 'package:moneyfly/l10n/app_strings.dart';
import 'package:moneyfly/theme/app_theme.dart';
import 'package:moneyfly/widgets/update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateInfo _info(String version,
        {String sha256 = '', int sizeBytes = 0, String? url, String? name}) =>
    UpdateInfo(
      latestVersion: version,
      downloadUrl: url ?? 'https://example.com/$version.pkg',
      sizeText: '1 MB',
      assetName: name ?? 'MoneyFly-macos-arm64-$version.dmg',
      sha256: sha256,
      sizeBytes: sizeBytes,
    );

Future<void> _pumpHost(WidgetTester tester, void Function(BuildContext) onCtx) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildMoneyFlyTheme(),
    home: Builder(builder: (ctx) {
      onCtx(ctx);
      return const Scaffold(body: SizedBox());
    }),
  ));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('mf_upd_mac_');
    UpdateService.resetForTest();
    // 注意：debugCacheDir 返回的是**基目录**，服务内部会再拼一层 `update/`
    UpdateService.debugCacheDir =
        () async => Directory(tmp.path)..createSync(recursive: true);
    UpdateService.debugCanInstallInApp = true;
    // 测试环境里 launchUrl 的通道调用**永不返回**（不抛异常，try/catch 救不了）
    UpdateService.debugOpenFileOverride = (path) async => true;
    UpdatePrompt.debugOpenUrlOverride = (url) async {};
    UpdatePrompt.debugReset();
    UpdateService.debugOpenFileOverride = (path) async => true;
    UpdatePrompt.debugOpenUrlOverride = (url) async {};
    AppStrings.setLang('zh', persist: false);
  });

  tearDown(() {
    UpdateService.resetForTest();
    UpdatePrompt.debugReset();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('下载包完整性（半截包不能再被当成「已就绪」）', () {
    test('大小与发布方不一致 → 直接丢弃，不返回路径', () async {
      final info = _info('1.0.1', sizeBytes: 4096);
      final dir = Directory('${tmp.path}/update')..createSync(recursive: true);
      // 残包：只有 5 字节（真实包 4096）
      File('${dir.path}/${info.assetName}').writeAsStringSync('half!');

      expect(await UpdateService.instance.downloadedInstaller(info), isNull,
          reason: '半截文件被判成「已下好」＝每次点更新都拿它去装 → macOS 报「磁盘损坏」');
      expect(File('${dir.path}/${info.assetName}').existsSync(), isFalse,
          reason: '残包应被删除，避免继续被复用');
    });

    test('大小正确但 sha256 不符 → 校验失败并删包', () async {
      final body = 'installer-bytes';
      final info = _info('1.0.2',
          sizeBytes: body.length, sha256: 'f' * 64); // 故意给错哈希
      final dir = Directory('${tmp.path}/update')..createSync(recursive: true);
      final f = File('${dir.path}/${info.assetName}')..writeAsStringSync(body);

      expect(await UpdateService.instance.verifyInstaller(f.path, info), isFalse);
      expect(f.existsSync(), isFalse, reason: '校验不过的包必须删掉，不能留在缓存里');
    });

    test('大小与 sha256 都对 → 放行（缓存命中路径也会校验）', () async {
      final dir = Directory('${tmp.path}/update')..createSync(recursive: true);
      final f = File('${dir.path}/pkg.bin')..writeAsStringSync('abc');
      final sha = await _sha256Hex(f);
      final info = _info('1.0.3', sizeBytes: 3, sha256: sha);
      expect(await UpdateService.instance.downloadedInstaller(info), isNull,
          reason: 'assetName 不匹配时不该返回（这里文件名叫 pkg.bin）');

      final info2 = _info('1.0.3', sizeBytes: 3, sha256: sha, name: 'pkg.bin');
      expect(await UpdateService.instance.downloadedInstaller(info2), f.path);
      expect(await UpdateService.instance.verifyInstaller(f.path, info2), isTrue);
    });
  });

  group('macOS 就地安装（挂载 → 复制 → 替换 → 起新版）', () {
    test('挂载失败 = 安装包损坏（半截下载最常见的形态）', () async {
      // 只在 macOS 有意义：installMacDmg 在别的平台直接返回 failed（不是 damaged）
      if (!Platform.isMacOS) return;
      final dmg = File('${tmp.path}/broken.dmg')..writeAsStringSync('not a dmg');
      UpdateService.debugAppBundlePath = '${tmp.path}/Apps/MoneyFly.app';
      UpdateService.debugRunProcess = (exe, args) async {
        if (exe == 'hdiutil' && args.first == 'attach') {
          return ProcessResult(1, 1, '', 'hdiutil: attach failed - 无法识别映像');
        }
        return ProcessResult(0, 0, '', '');
      };
      final r = await UpdateService.instance.installMacDmg(dmg.path);
      expect(r, MacInstallResult.damaged,
          reason: '损坏的包必须被识别成 damaged，让 UI 提示「重新下载/打开下载页」');
    });

    test('正常流程：新的 .app 就位、旧的让位、并启动新版本', () async {
      if (!Platform.isMacOS) return; // 同上：这条验证的是 macOS 就地安装
      final calls = <String>[];
      final appDir = Directory('${tmp.path}/Apps/MoneyFly.app')
        ..createSync(recursive: true);
      File('${appDir.path}/old.txt').writeAsStringSync('old');
      final dmg = File('${tmp.path}/good.dmg')..writeAsStringSync('dmg-bytes');
      UpdateService.debugAppBundlePath = appDir.path;

      UpdateService.debugRunProcess = (exe, args) async {
        calls.add('$exe ${args.join(' ')}');
        if (exe == 'hdiutil' && args.first == 'attach') {
          // 模拟挂载：在 mountpoint 下造出 DMG 里的 .app
          final mnt = args[args.indexOf('-mountpoint') + 1];
          final src = Directory('$mnt/MoneyFly.app')..createSync(recursive: true);
          File('${src.path}/new.txt').writeAsStringSync('new');
        } else if (exe == 'ditto') {
          // 模拟 ditto --noqtn -rsrc <src> <dst>
          final dst = args.last;
          Directory(dst).createSync(recursive: true);
          File('$dst/new.txt').writeAsStringSync('new');
          expect(args.contains('--noqtn'), isTrue,
              reason: '必须带 --noqtn：不带就会把隔离属性复制过去 → Gatekeeper 报「已损坏」');
        }
        return ProcessResult(0, 0, '', '');
      };

      final r = await UpdateService.instance.installMacDmg(dmg.path);
      expect(r, MacInstallResult.installed);
      // 新版本就位
      expect(File('${appDir.path}/new.txt').existsSync(), isTrue);
      expect(File('${appDir.path}/old.txt').existsSync(), isFalse);
      // 清隔离属性 + 启动新版本 + 卸载
      expect(calls.any((c) => c.startsWith('xattr -dr com.apple.quarantine ')), isTrue,
          reason: 'ad-hoc 签名的 App 一旦带隔离属性就报「已损坏」，必须清掉');
      expect(calls.any((c) => c.startsWith('open -n ')), isTrue, reason: '要拉起新版本');
      expect(calls.any((c) => c.startsWith('hdiutil detach ')), isTrue);
      // 旧 App 让位（改名而不是直接删：出问题还能回滚）
      final leftovers = Directory('${tmp.path}/Apps')
          .listSync()
          .map((e) => e.path.split('/').last)
          .where((n) => n.startsWith('MoneyFly.app.old-'))
          .toList();
      expect(leftovers, isNotEmpty, reason: '旧版本应先改名让位，而不是就地覆盖');
    });
  });

  group('应急预案：任何失败都能跳到下载页', () {
    testWidgets('主弹窗就带「打开下载页」（不依赖自动更新成功）', (tester) async {
      final info = _info('1.0.9');
      late BuildContext ctx;
      await _pumpHost(tester, (c) => ctx = c);

      final flow = UpdatePrompt.showUpdateDialog(ctx, info: info);
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.t('update_open_download_page')), findsOneWidget,
          reason: '用户明确反馈：缺少「跳转到软件下载地址」的按钮');

      String? opened;
      UpdatePrompt.debugOpenUrlOverride = (url) async => opened = url;
      await tester.tap(find.text(AppStrings.t('update_open_download_page')));
      await tester.pumpAndSettle();
      expect(opened, contains('github.com/moneyfly004/m-box/releases'),
          reason: '应打开 Releases 页面（网页），不是直链 —— 直链会被浏览器打上隔离属性');
      await flow;
    });

    testWidgets('安装包损坏：提示 + 可跳转下载页（不再只有一句「确定」）', (tester) async {
      UpdateInfo.currentVersion = '1.0.0';
      final info = _info('1.1.0', sizeBytes: 999); // 与真实残包大小不符
      final dir = Directory('${tmp.path}/update')..createSync(recursive: true);
      File('${dir.path}/${info.assetName}').writeAsStringSync('short'); // 残包
      // 下载也失败（无网络）：整条链路走完 → 必须出现兜底弹窗
      UpdateService.debugDownloadOverride =
          (url, path) async => throw Exception('network down');

      String? opened;
      UpdatePrompt.debugOpenUrlOverride = (url) async => opened = url;
      late BuildContext ctx;
      await _pumpHost(tester, (c) => ctx = c);

      final flow = UpdatePrompt.installNow(ctx, info: info);
      await tester.pump();
      await tester.pumpAndSettle();

      // 残包在 downloadedInstaller 阶段就被丢掉 → 走下载（无网络 → 失败）→ 兜底弹窗
      expect(find.text(AppStrings.t('update_fallback_title')), findsOneWidget,
          reason: '自动更新失败必须给出可见的兜底入口，而不是静默');
      expect(find.text(AppStrings.t('update_open_download_page')), findsOneWidget);

      await tester.tap(find.text(AppStrings.t('update_open_download_page')));
      await tester.pumpAndSettle();
      expect(opened, isNotNull);
      await flow;
    });

    testWidgets('macOS 手动安装说明：含「已损坏」的成因与可复制的修复命令', (tester) async {
      if (!Platform.isMacOS) return; // 说明入口只在 macOS 出现
      final info = _info('1.2.0');
      // 下载失败 → 兜底弹窗（纯 UI 路径：widget 测试里不能碰真实异步 I/O）
      UpdateService.debugDownloadOverride =
          (url, path) async => throw Exception('network down');

      late BuildContext ctx;
      await _pumpHost(tester, (c) => ctx = c);
      final flow = UpdatePrompt.installNow(ctx, info: info);
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.text(AppStrings.t('update_manual_help')));
      await tester.pumpAndSettle();
      expect(find.textContaining('xattr -dr com.apple.quarantine'), findsOneWidget,
          reason: '「已损坏」是 ad-hoc 签名 + 隔离属性导致的，必须给出可复制的修复命令');
      expect(find.text(AppStrings.t('update_manual_copy_cmd')), findsOneWidget);

      await tester.tap(find.text(AppStrings.t('confirm')));
      await tester.pumpAndSettle();
      await flow;
    });
  });
}

Future<String> _sha256Hex(File f) async {
  // 复用服务内部同一套实现（crypto 包）
  final bytes = await f.readAsBytes();
  return UpdateService.sha256HexForTest(bytes);
}
