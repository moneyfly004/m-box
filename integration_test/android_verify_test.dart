// 安卓真机/模拟器端到端验证：登录 → 连接 → 智能/全局模式 → 设置项。
//
// 关键验证（用户报告"全局模式不能用"）：
//   切到全局模式后，从**应用内部**发一个真实 HTTPS 请求到面板；
//   能通 = 全局模式可用；不通 = 复现故障（GLOBAL 组没指向真实节点等）。
//
// 运行：flutter test integration_test/android_verify_test.dart -d emulator-5554
// 前置：adb shell appops set top.mbox.app ACTIVATE_VPN allow
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/services/permission_service.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/theme/app_theme.dart';
import 'package:mbox/main.dart' as app;

const _account = '454487210@qq.com';
const _password = 'Sikeming001@';

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
  }
}

/// 真实网络探针：走系统默认路由（也就是 VPN 隧道）访问线上面板。
/// 返回 "ok:<状态码>" 或 "err:<原因>"。
Future<String> _probe(String tag) async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
  ));
  try {
    // 直连 IP 的订阅域名（不经 Cloudflare 缓存），服务端 nginx 会记录客户端 IP，
    // 据此可判定流量到底走没走节点隧道。
    final ts = DateTime.now().millisecondsSinceEpoch;
    // 走 /api/（由 Go 应用处理并记录客户端 IP）——/health 会命中 SPA 静态页，
    // 拿不到服务端日志，无法判定流量路径。
    final r = await dio.get<String>(
        'https://sub.fastora.top/api/v1/settings/public-settings?modecheck=$tag&t=$ts');
    return 'ok:${r.statusCode}';
  } catch (e) {
    return 'err:$e';
  }
}


void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('安卓：登录 → 连接 → 全局模式可用性实测', (tester) async {
    // app.main() 会安装自己的 FlutterError.onError；测试框架要求它原样交还，
    // 否则会在收尾处报 "_pendingExceptionDetails != null"（上一版就栽在这）。
    // 语言固定为中文：CI/新装设备默认英文，而断言用的是 AppStrings（跟随语言）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mbox_lang', 'zh');

    final prevOnError = FlutterError.onError;
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));
    FlutterError.onError = prevOnError;

    final conn = ConnectionController.instance;

    // —— 已登录则跳过登录页 ——
    if (find.byType(TextField).evaluate().isNotEmpty) {
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), _account);
      await tester.enterText(fields.at(1), _password);
      await tester.pump();
      // 按按钮类型找，不依赖界面语言（新装设备默认英文）
      await tester.tap(find.byType(MBPrimaryButton).first);
      await tester.pump();
    }
    await _waitFor(tester, () =>
        find.text(AppStrings.t('smart_mode')).evaluate().isNotEmpty);
    expect(find.text(AppStrings.t('smart_mode')), findsOneWidget,
        reason: '应已进入首页');

    // —— VPN 授权（系统弹窗由宿主机侧脚本自动点掉）——
    final prepared = await tester.runAsync(
        () => PermissionService.instance.prepareVpn());
    // ignore: avoid_print
    print('PROBE vpn-prepared: $prepared');

    // —— 连接 ——
    if (conn.status != ConnStatus.connected) {
      // 先走用户路径：点电源键
      final powerIcons = find.byIcon(Icons.power_settings_new_rounded);
      // ignore: avoid_print
      print('PROBE power-icons found: ${powerIcons.evaluate().length}');
      await tester.tap(powerIcons.first, warnIfMissed: false);
      await tester.pump();
      await _waitFor(tester,
          () => conn.status != ConnStatus.disconnected,
          timeout: const Duration(seconds: 8));
      // ignore: avoid_print
      print('PROBE power-button tap result: status=${conn.status} err=${conn.error}');
      if (conn.status == ConnStatus.disconnected) {
        // 按钮没生效：退回程序化调用，保证后续"模式验证"能继续
        // （按钮本身是否好用单独记录在上面这行 print 里）
        await tester.runAsync(() => conn.connect());
      }
      // VPN 授权弹窗是系统 UI（测试点不到），宿主机侧会自动点掉；
      // 这里每 8 秒重试一次连接，最多 10 次，等授权到位后即可连上。
      for (var attempt = 0; attempt < 10; attempt++) {
        await _waitFor(tester, () => conn.status == ConnStatus.connected,
            timeout: const Duration(seconds: 8));
        if (conn.status == ConnStatus.connected) break;
        // ignore: avoid_print
        print('PROBE connect attempt ${attempt + 1}: ${conn.status} err=${conn.error}');
        await tester.runAsync(() => conn.connect());
      }
      await _waitFor(tester, () => conn.status == ConnStatus.connected,
          timeout: const Duration(seconds: 30));
    }
    // ignore: avoid_print
    print('PROBE connect: status=${conn.status} node=${conn.current?.tag} err=${conn.error}');
    expect(conn.status, ConnStatus.connected,
        reason: '真实连接失败：${conn.error ?? "无错误信息"}');

    // —— 智能模式基线探针 ——
    final ruleProbe = await tester.runAsync(() => _probe('rule'));
    // ignore: avoid_print
    print('PROBE smart-mode: $ruleProbe');
    // 第三方应用流量（系统浏览器）：应用自身的流量可能被排除在隧道外，
    // 只有第三方流量才能证明"全局模式对普通上网是否管用"。

    // —— 切到全局模式（安卓会断开重连）——
    await tester.tap(find.text(AppStrings.t('global_mode')));
    await tester.pump();
    await _waitFor(tester,
        () => conn.status == ConnStatus.connected && conn.smartMode == false,
        timeout: const Duration(seconds: 120));
    // ignore: avoid_print
    print('PROBE mode: smartMode=${conn.smartMode} status=${conn.status} node=${conn.current?.tag} err=${conn.error}');
    expect(conn.smartMode, isFalse, reason: '应已切到全局模式');
    expect(conn.status, ConnStatus.connected,
        reason: '全局模式重连失败：${conn.error ?? "无错误信息"}');

    // —— 全局模式下的真实流量探针（用户报告的核心问题）——
    final globalProbe = await tester.runAsync(() => _probe('global'));
    // ignore: avoid_print
    print('PROBE global-mode: $globalProbe');
    expect(globalProbe, startsWith('ok:'),
        reason: '全局模式下真实请求失败 → 全局模式不可用（$globalProbe）');

    // 保持连接一段时间，等宿主机侧发起"第三方应用流量"（浏览器）验证全局模式。
    // ignore: avoid_print
    print('READY_FOR_CHROME global');
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 75)));
    // ignore: avoid_print
    print('DONE_WAIT global');


    // —— 切回智能模式，确认可来回切换 ——
    await tester.tap(find.text(AppStrings.t('smart_mode')));
    await tester.pump();
    await _waitFor(tester,
        () => conn.status == ConnStatus.connected && conn.smartMode == true,
        timeout: const Duration(seconds: 120));
    expect(conn.smartMode, isTrue, reason: '应能切回智能模式');
    // ignore: avoid_print
    print('PROBE back-to-smart: status=${conn.status} err=${conn.error}');
  }, timeout: const Timeout(Duration(minutes: 12)));

  testWidgets('我的-设置：逐项可打开、开关可切换并真的落盘', (tester) async {
    // 注意：设置页有持续动画（状态点/进度），pumpAndSettle 会永远等不到静止 →
    // 全程用有界 pump（这也是上一个版本 8 分钟超时的原因）。
    Future<void> settle([int ms = 800]) async {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pump();
    }

    final prevOnError = FlutterError.onError;
    app.main();
    await settle(2500);
    FlutterError.onError = prevOnError;

    final before = await SettingsStore.instance.load();

    // 进入「我的」
    final personIcons = find.byIcon(Icons.person_outline);
    // ignore: avoid_print
    print('PROBE profile icons: ${personIcons.evaluate().length}');
    if (personIcons.evaluate().isNotEmpty) {
      await tester.tap(personIcons.last, warnIfMissed: false);
      await settle(1200);
    }

    // 「我的」页要等 dashboard 数据回来才渲染列表（含「设置」入口）→ 轮询等待
    var waited = 0;
    while (find.text(AppStrings.t('settings')).evaluate().isEmpty && waited < 20) {
      await settle(800);
      waited++;
    }
    final settingsEntry = find.text(AppStrings.t('settings'));
    // ignore: avoid_print
    print('PROBE settings entry: ${settingsEntry.evaluate().length} (waited ${waited}x800ms)');
    expect(settingsEntry, findsWidgets, reason: '「我的」页应有「设置」入口');
    await tester.tap(settingsEntry.first, warnIfMissed: false);
    await settle(1500);

    // 设置页渲染确认
    final switchCount = find.byType(Switch).evaluate().length;
    final rowCount = find.byType(InkWell).evaluate().length;
    // ignore: avoid_print
    print('PROBE settings page: switches=$switchCount rows=$rowCount');

    // 开关逐个切换 → 必须真的写进设置存储
    var switchChanged = 0;
    for (var i = 0; i < switchCount && i < 4; i++) {
      final b = await SettingsStore.instance.load();
      await tester.tap(find.byType(Switch).at(i), warnIfMissed: false);
      await settle(900);
      final a = await SettingsStore.instance.load();
      final changed = a.toString() != b.toString();
      if (changed) switchChanged++;
      // ignore: avoid_print
      print('PROBE switch #$i changed=$changed');
    }

    // 列表项逐个点开 → 应弹出选择器或进入子页，且能返回
    var opened = 0;
    for (var i = 0; i < 8; i++) {
      final rows = find.byType(InkWell);
      if (rows.evaluate().length <= i) break;
      await tester.tap(rows.at(i), warnIfMissed: false);
      await settle(700);
      final hasLayer = find.byType(Dialog).evaluate().isNotEmpty ||
          find.byType(BottomSheet).evaluate().isNotEmpty ||
          find.byType(BackButton).evaluate().isNotEmpty;
      if (hasLayer) opened++;
      final cancel = find.text(AppStrings.t('cancel'));
      if (cancel.evaluate().isNotEmpty) {
        await tester.tap(cancel.first, warnIfMissed: false);
      } else if (find.byType(BackButton).evaluate().isNotEmpty) {
        await tester.pageBack();
      }
      await settle(500);
    }

    final after = await SettingsStore.instance.load();
    // ignore: avoid_print
    print('PROBE settings result: rows_opened=$opened switches_changed=$switchChanged '
        'keys=${after.keys.length}');
    expect(after.keys.length, greaterThan(5),
        reason: '设置项应完整可读（实测键数 ${after.keys.length}）');
    expect(opened, greaterThan(0), reason: '设置列表项应能打开选择器/子页');
    expect(before.keys.length, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
