// 更新下载弹窗「可取消」回归测试。
//
// 背景：进度弹窗是 `barrierDismissible: false` + `PopScope(canPop: false)` 且
// **没有取消按钮** —— 一个可能持续几分钟的下载完全无法中止（连「我不想装了」
// 都表达不了，返回键/点遮罩都关不掉）。
//
// 契约：
//   · 进度弹窗里有「取消」按钮，并有明确说明取消的真实语义；
//   · 点取消后弹窗关闭、flow 立刻返回（不再卡在等待下载上）、绝不安装、
//     也不会把「用户主动取消」当成「下载失败」去弹「打开下载页」；
//   · 下载正常完成时流程不受影响（仍然安装）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/update_service.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/widgets/update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateInfo _info(String version) => UpdateInfo(
      latestVersion: version,
      downloadUrl: 'https://example.com/$version.pkg',
      sizeText: '1 MB',
      assetName: 'MBox-macos-arm64-$version.dmg',
      sha256: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppStrings.setLang('zh', persist: false);
    UpdateService.resetForTest();
    UpdatePrompt.debugReset();
    UpdateInfo.currentVersion = '1.0.0';
    // 应用内安装 + 安装器 + 退出全部走测试缝（不真装、不退出进程）
    UpdateService.debugCanInstallInApp = true;
    // 等下载的上限从 3 分钟缩到 5 秒：安装流程会用 Future.timeout 起一个定时器，
    // 取消路径下这个定时器仍在（源码层行为），用例结尾推进假时钟把它放掉，
    // 否则 flutter_test 报 Pending timers。
    UpdatePrompt.debugWaitInstallerLimit = const Duration(seconds: 5);
    tmp = await Directory.systemTemp.createTemp('mf_update_cancel_test');
    UpdateService.debugCacheDir = () async => tmp;
  });

  tearDown(() async {
    UpdateService.resetForTest();
    UpdatePrompt.debugReset();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHost(
      WidgetTester tester, void Function(BuildContext) onCtx) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        onCtx(c);
        return const SizedBox();
      }),
    ));
  }

  testWidgets('下载中：进度弹窗有「取消」按钮和取消说明，不再是无出口的转圈', (tester) async {
    // 每个用例用**不同版本号**（= 不同安装包文件名）：UpdateService 的并发去重
    // 表 _inFlight 是静态的，跨用例同名的「永不完成」下载会串味
    // 下载永不完成（模拟一个几分钟的大包）
    final gate = Completer<void>();
    UpdateService.debugDownloadOverride = (url, path) async {
      await gate.future;
      await File(path).writeAsString('installer');
    };

    late BuildContext ctx;
    await pumpHost(tester, (c) => ctx = c);

    final flow = UpdatePrompt.installNow(ctx, info: _info('1.0.1')); // 不 await
    await tester.pump();
    await tester.pump();

    expect(find.text(AppStrings.t('update_downloading_pkg')), findsOneWidget);
    expect(find.text(AppStrings.t('cancel')), findsOneWidget,
        reason: '旧实现没有取消按钮：barrierDismissible=false + canPop=false = 关不掉');
    expect(find.text(AppStrings.t('update_cancel_hint')), findsOneWidget,
        reason: '取消的真实语义（停止等待、下载仍在后台继续、不会安装）必须写明');

    // 收尾：点「取消」让流程结束、再放行底层下载（不留下未完成的异步任务）
    await tester.tap(find.text(AppStrings.t('cancel')));
    await tester.pumpAndSettle();
    await flow;
    gate.complete();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6)); // 放掉 Future.timeout 的定时器
    expect(tester.takeException(), isNull);
  });

  testWidgets('点「取消」：弹窗关闭、流程立刻结束、绝不安装、不弹「下载失败」', (tester) async {
    final gate = Completer<void>();
    UpdateService.debugDownloadOverride = (url, path) async {
      await gate.future;
      await File(path).writeAsString('installer');
    };
    var launched = false;
    UpdateService.debugLaunchInstallerOverride = (path) async {
      launched = true;
      return true;
    };
    var openedUrl = '';
    UpdatePrompt.debugOpenUrlOverride = (u) async => openedUrl = u;

    late BuildContext ctx;
    await pumpHost(tester, (c) => ctx = c);

    final flow = UpdatePrompt.installNow(ctx, info: _info('1.0.2'));
    await tester.pump();
    await tester.pump();
    expect(find.text(AppStrings.t('cancel')), findsOneWidget);

    await tester.tap(find.text(AppStrings.t('cancel')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.t('update_downloading_pkg')), findsNothing,
        reason: '取消后进度弹窗必须关掉');

    // 关键：flow 必须真的返回（旧实现只能等到下载超时/完成）
    await flow.timeout(const Duration(seconds: 5),
        onTimeout: () => fail('取消后 installNow 仍然卡在等待下载上'));

    expect(launched, isFalse, reason: '取消 = 不安装');
    expect(openedUrl, isEmpty, reason: '取消不能被当成「下载失败」去打开下载页');
    expect(find.textContaining(AppStrings.t('update_download_failed')),
        findsNothing);

    // 底层下载随后完成也不会引发异常（进度 notifier 已 dispose，靠 alive 闸门挡住）
    gate.complete();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6)); // 放掉 Future.timeout 的定时器
  });

  testWidgets('下载正常完成：流程不受影响，仍然调起安装器（取消没有破坏主路径）', (tester) async {
    UpdateService.debugDownloadOverride = (url, path) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await File(path).writeAsString('installer');
    };
    var launched = '';
    UpdateService.debugLaunchInstallerOverride = (path) async {
      launched = path;
      return true;
    };
    // macOS 现在走「就地安装」（挂 DMG → 替换 App），不再只是 open <dmg>；
    // 两条分支都注入，用例在 macOS 与 Linux CI 上都能跑
    UpdateService.debugInstallMacOverride = (dmg) async {
      launched = dmg;
      return MacInstallResult.openedExternally;
    };
    var exited = -1;
    UpdatePrompt.debugExitOverride = (code) => exited = code;

    late BuildContext ctx;
    await pumpHost(tester, (c) => ctx = c);

    final flow = UpdatePrompt.installNow(ctx, info: _info('1.0.3'));
    // 下载链路里混了两种时间：Dio/override 的 delay 是**假时钟**定时器
    // （只有 pump(Duration) 推进），缓存目录解析与磁盘写入是**真实**异步
    // （需要 runAsync 给事件循环时间）—— 两者交替推进才能走完。
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
    }
    await tester.pump();
    await tester.pumpAndSettle();

    expect(launched, isNotEmpty, reason: '下载完成后必须调起安装器（或 macOS 的就地安装）');
    // macOS 走就地安装时是「安装包已打开」提示（只有非 .app 运行 / 权限不足才会退到
    // open <dmg>），其它平台仍是「安装程序已启动」
    expect(
        find.textContaining(Platform.isMacOS
            ? AppStrings.t('update_manual_open_hint')
            : AppStrings.t('update_installing_exit')),
        findsOneWidget);
    await tester.tap(find.text(AppStrings.t('confirm')));
    await tester.pumpAndSettle();
    await flow;
    expect(exited, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
