// 全功能走查 + 卡顿量化（macOS / Android 共用）。
//
// 目标（对应「每一个功能是否流畅、测速是否卡顿」）：
//  1) 逐项走查真实 UI 路径：启动 → 首页 → 节点列表（搜索/排序/单点测速）→
//     测速（TCP / 内核真连接）→ 连接/断开 → 智能/全局模式 → 设置页每一项 →
//     主题/语言；
//  2) 每个阶段用 Flutter 的 FrameTiming 采集**真实帧耗时**，输出
//     frames / avg / p95 / worst / jank(>16.7ms) / severe(>33ms)，
//     把「流畅」变成可比较的数字；
//  3) 测速阶段单独量化：订阅有 500+ 节点，逐个回填会整页重建 —— 这里就是
//     卡顿最容易出现的地方，因此对「测速中」单独统计帧耗时。
//
// 运行（真机/桌面，profile 才有真实性能数字）：
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/full_smoke_test.dart
//   flutter drive --profile -d emulator-5554 --driver=... --target=...
//
// Android 前置：
//   adb shell appops set top.moneyfly.app ACTIVATE_VPN allow
//   adb shell pm grant top.moneyfly.app android.permission.POST_NOTIFICATIONS
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/services/permission_service.dart';
import 'package:moneyfly/core/services/settings_store.dart';
import 'package:moneyfly/core/services/speed_test_mode.dart';
import 'package:moneyfly/l10n/app_strings.dart';
import 'package:moneyfly/main.dart' as app;
import 'package:moneyfly/theme/theme_controller.dart';
import 'package:moneyfly/main.dart' show mainTabIndex;

/// 测试账号（与 integration_test/android_verify_test.dart 同源，仅内网测试用）
const _account = '454487210@qq.com';
const _password = 'Sikeming001@';

// ---------------------------------------------------------------- 帧耗时采集
class Perf {
  final List<FrameTiming> _frames = [];
  bool _on = false;
  TimingsCallback? _cb;
  static final List<String> report = [];

  void start(String phase) {
    _frames.clear();
    _on = true;
    _cb = _collect;
    SchedulerBinding.instance.addTimingsCallback(_collect);
  }

  void _collect(List<FrameTiming> ts) {
    if (!_on) return;
    _frames.addAll(ts);
  }

  /// 结束采集并返回一行可读指标（同时写进 [report]）
  String stop(String phase) {
    _on = false;
    final cb = _cb;
    if (cb != null) SchedulerBinding.instance.removeTimingsCallback(_collect);
    _cb = null;
    final builds = [
      for (final f in _frames) f.buildDuration.inMicroseconds / 1000.0
    ]..sort();
    final spans = [
      for (final f in _frames) f.totalSpan.inMicroseconds / 1000.0
    ]..sort();
    final n = builds.length;
    if (n == 0) {
      final line = '$phase | 无帧样本';
      report.add(line);
      // ignore: avoid_print
      print('PERF $line');
      return line;
    }
    double pct(List<double> v, double p) =>
        v[((v.length - 1) * p).round().clamp(0, v.length - 1)];
    final jank = builds.where((b) => b > 16.7).length;
    final severe = builds.where((b) => b > 33.3).length;
    final line = '$phase | frames=$n '
        'build_avg=${(builds.reduce((a, b) => a + b) / n).toStringAsFixed(2)}ms '
        'build_p95=${pct(builds, 0.95).toStringAsFixed(2)}ms '
        'build_worst=${builds.last.toStringAsFixed(2)}ms '
        'span_p95=${pct(spans, 0.95).toStringAsFixed(2)}ms '
        'jank(>16.7ms)=$jank/$n(${(jank * 100 / n).toStringAsFixed(1)}%) '
        'severe(>33ms)=$severe';
    report.add(line);
    // ignore: avoid_print
    print('PERF $line');
    return line;
  }
}

// ---------------------------------------------------------------- 通用工具
/// 有界 pump：设置页/首页有常驻动画，`pumpAndSettle` 会永远等不到静止。
Future<void> settle(WidgetTester tester, [int ms = 700]) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
}

/// 回到主壳（设置页/子页是 Navigator 压栈的，切 tab 不会把它们收掉）。
Future<void> popToRoot(WidgetTester tester) async {
  // 设置页的子页不一定是 BackButton（可能是自定义返回按钮），所以直接操作
  // Navigator：popUntil(isFirst) 才是可靠的"回到主壳"。
  try {
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.popUntil((r) => r.isFirst);
  } catch (_) {/* 没有可 pop 的路由：忽略 */}
  await settle(tester, 700);
}

Future<bool> waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 60),
  int stepMs = 250,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (done()) return true;
    await settle(tester, stepMs);
  }
  return done();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全功能走查 + 测速卡顿量化', (tester) async {
    final conn = ConnectionController.instance;
    final failures = <String>[];
    void fail(String phase, Object e) {
      failures.add('$phase: $e');
      // ignore: avoid_print
      print('FAIL $phase: $e');
    }

    /// 每个阶段独立兜底：某一项失败也要把后面的功能走完（否则拿不到全景）
    Future<void> phase(String name, Future<void> Function() body) async {
      try {
        await body();
      } catch (e) {
        fail(name, e);
      }
    }

    // ============================================================ A 启动/登录
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('moneyfly_lang', 'zh');
    await AppStrings.setLang('zh', persist: false);

    final perfBoot = Perf()..start('启动');
    final prevOnError = FlutterError.onError;
    app.main();
    await tester.pump();
    await settle(tester, 2500);
    FlutterError.onError = prevOnError;

    // 已登录则直接进首页；新设备登录（按控件类型找，不依赖界面语言）
    if (find.byType(TextField).evaluate().isNotEmpty) {
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), _account);
      await tester.enterText(fields.at(1), _password);
      await settle(tester, 300);
      final btns = find.byType(ElevatedButton);
      if (btns.evaluate().isNotEmpty) {
        await tester.tap(btns.first, warnIfMissed: false);
      } else {
        await tester.testTextInput.receiveAction(TextInputAction.done);
      }
      await tester.pump();
    }
    final homeOk = await waitFor(
        tester, () => find.text(AppStrings.t('smart_mode')).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 90));
    perfBoot.stop('启动');
    expect(homeOk, isTrue, reason: '应进入首页');
    // ignore: avoid_print
    print('PROBE 登录/首页 OK, 平台=${Platform.operatingSystem}');

    // 等订阅节点就绪（macOS 有缓存，Android 首启要拉取）
    await waitFor(tester, () => conn.nodes.isNotEmpty,
        timeout: const Duration(seconds: 120));
    // ignore: avoid_print
    print('PROBE 节点数=${conn.nodes.length} 当前节点=${conn.current?.tag}');
    expect(conn.nodes, isNotEmpty, reason: '订阅节点应加载成功');

    // ============================================================ B 首页基线
    final perfIdle = Perf()..start('首页静置');
    await settle(tester, 3000);
    perfIdle.stop('首页静置');

    // ============================================================ B2 我的页立即出现
    // 用户反馈：「每次点击我的都要等一会儿才出来」。这里直接量化：
    // 从切到「我的」到固定入口（设置）可见的耗时，首次与再次进入各测一次。
    await phase('我的页立即出现', () async {
      final settingsEntry = find.text(AppStrings.t('settings'));
      // 首次进入（本次进程内没构建过该页）
      var sw = Stopwatch()..start();
      mainTabIndex.value = 3;
      var ok = await waitFor(tester, () => settingsEntry.evaluate().isNotEmpty,
          timeout: const Duration(seconds: 20), stepMs: 16);
      final firstMs = sw.elapsedMilliseconds;
      // 切走再切回（TTL 内：应命中缓存，几乎瞬时）
      mainTabIndex.value = 0;
      await settle(tester, 300);
      sw = Stopwatch()..start();
      mainTabIndex.value = 3;
      ok = await waitFor(tester, () => settingsEntry.evaluate().isNotEmpty,
              timeout: const Duration(seconds: 20), stepMs: 16) &&
          ok;
      final againMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('PROBE 我的页可见: 首次=${firstMs}ms 再次=${againMs}ms ok=$ok');
      expect(ok, isTrue, reason: '固定入口必须立即出现（不能等数据）');
      expect(firstMs, lessThan(3000), reason: '首次进入不应"等一会儿才出来"');
      expect(againMs, lessThan(600), reason: '再次进入必须几乎瞬时（缓存上屏）');
      mainTabIndex.value = 0;
      await settle(tester, 400);
    });

    // ============================================================ C 节点列表渲染
    await phase('进入节点页', () async {
      mainTabIndex.value = 1; // 节点 tab
      await settle(tester, 1500);
      expect(find.text(AppStrings.t('nodes_title')), findsWidgets);
    });
    final perfNodesRender = Perf()..start('节点页首次渲染');
    await settle(tester, 1200);
    perfNodesRender.stop('节点页首次渲染');

    // ============================================================ D 列表滚动
    final perfScroll = Perf()..start('节点列表滚动');
    await phase('滚动列表', () async {
      final list = find.byType(Scrollable).first;
      for (var i = 0; i < 6; i++) {
        await tester.drag(list, const Offset(0, -600), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      }
      for (var i = 0; i < 3; i++) {
        await tester.drag(list, const Offset(0, 700), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      }
    });
    perfScroll.stop('节点列表滚动');

    // ============================================================ E 搜索筛选
    final perfSearch = Perf()..start('搜索筛选');
    await phase('搜索筛选', () async {
      final box = find.byType(TextField);
      if (box.evaluate().isNotEmpty) {
        await tester.tap(box.first, warnIfMissed: false);
        await tester.enterText(box.first, '香港');
        await settle(tester, 800);
        // 再输一批制造连续重建
        for (final t in ['香港-', '香港-i', '香港-ip']) {
          await tester.enterText(box.first, t);
          await tester.pump(const Duration(milliseconds: 80));
        }
        // 清空
        await tester.enterText(box.first, '');
        await settle(tester, 600);
      }
    });
    perfSearch.stop('搜索筛选');

    // ============================================================ F 延迟排序
    final perfSort = Perf()..start('按延迟排序');
    await phase('按延迟排序', () async {
      // 排序入口是顶部的 MFChip（当前显示「默认排序」）→ 点开选择器选「按延迟」
      final chip = find.text(AppStrings.t('sort_default'));
      if (chip.evaluate().isNotEmpty) {
        await tester.tap(chip.first, warnIfMissed: false);
        await settle(tester, 600);
        final opt = find.text(AppStrings.t('sort_latency'));
        if (opt.evaluate().isNotEmpty) {
          await tester.tap(opt.last, warnIfMissed: false);
          await settle(tester, 900);
        }
        // ignore: avoid_print
        print('PROBE 排序: 已选「按延迟」');
      } else {
        // ignore: avoid_print
        print('PROBE 排序: 未找到排序入口（当前标签可能已变化）');
      }
    });
    perfSort.stop('按延迟排序');

    // ============================================================ G TCP 测速
    // 采样方式：测速期间**以 60Hz 驱动出帧**，统计每帧构建耗时 —— 这才是用户
    // 眼睛里的「卡不卡」（测速会逐个回填节点，触发整页重建）。
    final perfTcp = Perf()..start('测速·TCP(40节点)');
    var tcpTested = 0;
    var tcpMs = 0;
    await phase('测速 TCP', () async {
      conn.applySettings({'speedTestMode': speedTestModeKey(SpeedTestMode.tcp)});
      conn.speedTestMode = SpeedTestMode.tcp;
      final tags = {for (final n in conn.nodes.take(40)) n.tag};
      var done = false;
      final sw = Stopwatch()..start();
      unawaited(conn
          .speedTest(tags: tags, switchToBest: false, userInitiated: true)
          .then((v) => tcpTested = v)
          .whenComplete(() => done = true));
      // 每 16ms 出一帧，直到测速结束（上限 90s 防挂死）
      while (!done && sw.elapsed < const Duration(seconds: 90)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      tcpMs = sw.elapsedMilliseconds;
    });
    perfTcp.stop('测速·TCP(40节点)');
    // ignore: avoid_print
    print('PROBE TCP 测速: tested=$tcpTested elapsed=${tcpMs}ms err=${conn.speedTestError}');

    // ============================================================ H 单节点测速
    final perfOne = Perf()..start('单节点测速');
    await phase('单节点测速', () async {
      // 走与「点延迟胶囊」完全相同的生产路径（ConnectionController.testOneNode）。
      // 为什么不用 UI 点击：列表里可见行可能是 UDP-only/占位节点（胶囊显示
      // 「连接后测速」），点它们不会触发测速，测出来的帧也没意义。
      final target = conn.nodes.firstWhere(
        (n) => !n.isUdpOnly && !n.isPanelPseudo,
        orElse: () => conn.nodes.first,
      );
      var done = false;
      final sw = Stopwatch()..start();
      unawaited(conn
          .testOneNode(target)
          .whenComplete(() => done = true));
      while (!done && sw.elapsed < const Duration(seconds: 30)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // ignore: avoid_print
      print('PROBE 单节点测速: tag=${target.tag} elapsed=${sw.elapsedMilliseconds}ms');
    });
    perfOne.stop('单节点测速');

    // ============================================================ H2 未连接·内核测速
    // 桌面端**未连接**时走「临时探测内核」—— 这正是本次把默认测速方式改成
    // 内核测速后、用户点 ⚡ 的第一条路径，必须单独验证（移动端该路径会给出
    // 「请先连接」的可执行提示，所以只在桌面跑）。
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      final perfProbe = Perf()..start('测速·未连接探测内核(12节点)');
      var probeTested = 0;
      var probeMs = 0;
      await phase('测速 未连接(探测内核)', () async {
        final tags = {for (final n in conn.nodes.take(12)) n.tag};
        var done = false;
        final sw = Stopwatch()..start();
        unawaited(conn
            .speedTest(tags: tags, switchToBest: false, userInitiated: true)
            .then((v) => probeTested = v)
            .whenComplete(() => done = true));
        while (!done && sw.elapsed < const Duration(seconds: 120)) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        probeMs = sw.elapsedMilliseconds;
      });
      perfProbe.stop('测速·未连接探测内核(12节点)');
      // ignore: avoid_print
      print('PROBE 未连接内核测速: tested=$probeTested elapsed=${probeMs}ms '
          'err=${conn.speedTestError}');
      expect(probeTested, greaterThan(0),
          reason: '桌面端未连接时应能用探测内核完成测速（新默认路径）');
    }

    // ============================================================ I 连接/断开
    // Android：先申请 VPN 授权（系统弹窗由 adb appops 预先放行）
    if (Platform.isAndroid) {
      // ignore: avoid_print
      print('PROBE vpn-prepared=${await tester.runAsync(() => PermissionService.instance.prepareVpn())}');
    }
    final perfConnect = Perf()..start('连接');
    var connectedOk = false;
    await phase('连接', () async {
      // 不 await：连接过程要同时持续出帧，才能量化「连接时界面是否卡」
      unawaited(conn.connect());
      final sw = Stopwatch()..start();
      while (conn.status != ConnStatus.connected &&
          conn.status != ConnStatus.error &&
          sw.elapsed < const Duration(seconds: 90)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      connectedOk = conn.status == ConnStatus.connected;
      // ignore: avoid_print
      print('PROBE 连接: status=${conn.status} node=${conn.current?.tag} '
          'err=${conn.error ?? "-"} kind=${conn.errorKind}');
    });
    perfConnect.stop('连接');

    // ============================================================ J 模式切换
    final perfMode = Perf()..start('模式切换');
    await phase('模式切换', () async {
      mainTabIndex.value = 0; // 模式开关在首页
      await settle(tester, 900);
      if (connectedOk) {
        await tester.tap(find.text(AppStrings.t('global_mode')), warnIfMissed: false);
        await waitFor(tester, () => conn.smartMode == false,
            timeout: const Duration(seconds: 60));
        await waitFor(tester, () => conn.status == ConnStatus.connected,
            timeout: const Duration(seconds: 60));
        await tester.tap(find.text(AppStrings.t('smart_mode')), warnIfMissed: false);
        await waitFor(tester, () => conn.smartMode == true,
            timeout: const Duration(seconds: 60));
        await waitFor(tester, () => conn.status == ConnStatus.connected,
            timeout: const Duration(seconds: 60));
      }
    });
    perfMode.stop('模式切换');

    // ============================================================ K 内核测速
    // 这是本次默认值改动的核心路径：真连接测速（未连接→临时探测内核；
    // 已连接/移动端→当前内核）。每个节点都要真实建连 + HTTP 往返，
    // 逐节点回填 500+ 节点页 = 卡顿压力最大的地方，因此单独量化。
    final perfKernel = Perf()..start('测速·内核真连接(20节点)');
    var kernelTested = 0;
    var kernelMs = 0;
    await phase('测速 内核', () async {
      await SettingsStore.instance
          .update((x) => x['speedTestMode'] = speedTestModeKey(SpeedTestMode.kernel));
      conn.applySettings({'speedTestMode': speedTestModeKey(SpeedTestMode.kernel)});
      final tags = {for (final n in conn.nodes.take(20)) n.tag};
      var done = false;
      final sw = Stopwatch()..start();
      unawaited(conn
          .speedTest(tags: tags, switchToBest: false, userInitiated: true)
          .then((v) => kernelTested = v)
          .whenComplete(() => done = true));
      while (!done && sw.elapsed < const Duration(seconds: 150)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      kernelMs = sw.elapsedMilliseconds;
    });
    perfKernel.stop('测速·内核真连接(20节点)');
    final kernelOnline = conn.nodes.where((n) => n.online && n.latencyMs > 0).length;
    // ignore: avoid_print
    print('PROBE 内核测速: tested=$kernelTested elapsed=${kernelMs}ms '
        'online=$kernelOnline err=${conn.speedTestError}');

    // ============================================================ L 断开
    final perfDisconnect = Perf()..start('断开');
    await phase('断开', () async {
      await tester.runAsync(() => conn.disconnect());
      await waitFor(tester, () => conn.status == ConnStatus.disconnected,
          timeout: const Duration(seconds: 45));
    });
    perfDisconnect.stop('断开');

    // ============================================================ M 设置页走查
    final perfSettings = Perf()..start('设置页走查');
    var switchesOk = 0;
    var rowsOpened = 0;
    await phase('设置页', () async {
      mainTabIndex.value = 3; // 我的
      await settle(tester, 1200);
      final entry = find.text(AppStrings.t('settings'));
      await waitFor(tester, () => entry.evaluate().isNotEmpty,
          timeout: const Duration(seconds: 30));
      await tester.tap(entry.first, warnIfMissed: false);
      await settle(tester, 1500);

      // 开关：切换后必须真的落盘（防止「点了没反应」）
      final swCount = find.byType(Switch).evaluate().length;
      for (var i = 0; i < swCount && i < 3; i++) {
        final before = (await SettingsStore.instance.load()).toString();
        await tester.tap(find.byType(Switch).at(i), warnIfMissed: false);
        await settle(tester, 700);
        final after = (await SettingsStore.instance.load()).toString();
        if (before != after) switchesOk++;
        await tester.tap(find.byType(Switch).at(i), warnIfMissed: false); // 还原
        await settle(tester, 500);
      }

      // 列表项：能打开弹窗/子页并能返回
      final rows = find.byType(InkWell);
      for (var i = 0; i < 10 && i < rows.evaluate().length; i++) {
        await tester.tap(find.byType(InkWell).at(i), warnIfMissed: false);
        await settle(tester, 600);
        final opened = find.byType(Dialog).evaluate().isNotEmpty ||
            find.byType(BottomSheet).evaluate().isNotEmpty ||
            find.byType(BackButton).evaluate().isNotEmpty;
        if (opened) rowsOpened++;
        final cancel = find.text(AppStrings.t('cancel'));
        if (cancel.evaluate().isNotEmpty) {
          await tester.tap(cancel.first, warnIfMissed: false);
        } else if (find.byType(BackButton).evaluate().isNotEmpty) {
          await tester.pageBack();
        }
        await settle(tester, 450);
      }
      if (find.byType(BackButton).evaluate().isNotEmpty) await tester.pageBack();
      await settle(tester, 600);
    });
    perfSettings.stop('设置页走查');
    await popToRoot(tester); // 设置页是压栈路由：不 pop 掉，后面首页的按钮就找不到
    // ignore: avoid_print
    print('PROBE 设置页: switches_changed=$switchesOk rows_opened=$rowsOpened');

    // ============================================================ N 主题/语言
    final perfTheme = Perf()..start('主题/语言切换');
    await phase('主题/语言', () async {
      // 直接切主题（设置里 appearance）：深色 → 浅色，观察整页重建帧
      // 走设置页实际使用的 ThemeController（改主题 → 全量重建所有页面）
      for (final mode in ['black', 'dark', 'light']) {
        ThemeController.instance.setAppearance(mode);
        final sw = Stopwatch()..start();
        while (sw.elapsed < const Duration(milliseconds: 800)) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      for (final lang in ['en', 'zh']) {
        await tester.runAsync(() => AppStrings.setLang(lang, persist: false));
        await settle(tester, 700);
      }
      // ignore: avoid_print
      print('PROBE 主题/语言切换完成');
    });
    perfTheme.stop('主题/语言切换');

    // ============================================================ O 端口冲突自救
    // 仅桌面：Android 的本地端口在 VpnService 内部，无此场景。
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      await phase('端口冲突自救', () async {
        // 用一个真的监听者占住当前本地端口
        final s = await SettingsStore.instance.load();
        final port = (s['localPort'] as num?)?.toInt() ?? 2080;
        ServerSocket? squat;
        try {
          squat = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        } catch (_) {
          // 已被占用也满足测试前提
        }
        await popToRoot(tester);
        mainTabIndex.value = 0; // 错误区与「换端口并重连」按钮在首页
        await settle(tester, 900);
        final perfPort = Perf()..start('端口冲突报错');
        unawaited(conn.connect());
        final gotError = await waitFor(
            tester, () => conn.errorKind == ConnErrorKind.portInUse,
            timeout: const Duration(seconds: 40));
        perfPort.stop('端口冲突报错');
        // ignore: avoid_print
        print('PROBE 端口冲突: kind=${conn.errorKind} err=${conn.error}');
        expect(gotError, isTrue, reason: '端口被占用应给出 portInUse 类型化错误');
        expect(conn.error ?? '', contains('$port'), reason: '错误文案应点名端口');

        // 首页错误区的「换端口并重连」按钮
        final fixBtn = find.text(AppStrings.t('fix_port_btn'));
        await waitFor(tester, () => fixBtn.evaluate().isNotEmpty,
            timeout: const Duration(seconds: 20));
        if (fixBtn.evaluate().isEmpty) {
          final texts = tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .where((t) => t != null && t.isNotEmpty)
              .take(30)
              .toList();
          // ignore: avoid_print
          print('DIAG 首页可见文案: $texts');
          // ignore: avoid_print
          print('DIAG status=${conn.status} error=${conn.error} kind=${conn.errorKind} '
              'fixLabel=${AppStrings.t('fix_port_btn')}');
        }
        // ignore: avoid_print
        print('PROBE 换端口按钮出现=${fixBtn.evaluate().isNotEmpty}');
        if (fixBtn.evaluate().isNotEmpty) {
          await tester.tap(fixBtn.first, warnIfMissed: false);
          final recovered = await waitFor(
              tester, () => conn.status == ConnStatus.connected,
              timeout: const Duration(seconds: 90));
          // ignore: avoid_print
          print('PROBE 换端口自救: recovered=$recovered status=${conn.status} '
              'err=${conn.error ?? "-"}');
          final after = await SettingsStore.instance.load();
          // ignore: avoid_print
          print('PROBE 端口已改为 localPort=${after['localPort']}');
          if (recovered) {
            await tester.runAsync(() => conn.disconnect());
          }
          // 还原端口，避免影响后续使用
          await tester.runAsync(() => SettingsStore.instance
              .update((m) => m['localPort'] = port));
          await squat?.close();
        }
        await squat?.close();
      });
    }

    // ============================================================ 收尾
    // 无论前面哪一项失败，都别把用户的连接留在「已连接」状态（测试会改系统代理/
    // 隧道，收尾必须还原）。同时把测速方式留在设置页选定的值上。
    await phase('收尾断开', () async {
      if (conn.status != ConnStatus.disconnected) {
        await tester.runAsync(() => conn.disconnect());
        await waitFor(tester, () => conn.status == ConnStatus.disconnected,
            timeout: const Duration(seconds: 30));
      }
    });

    // ============================================================ 汇总
    // ignore: avoid_print
    print('===== PERF REPORT (${Platform.operatingSystem}) =====');
    for (final line in Perf.report) {
      // ignore: avoid_print
      print(line);
    }
    // ignore: avoid_print
    print('===== FAILURES (${failures.length}) =====');
    for (final f in failures) {
      // ignore: avoid_print
      print(f);
    }
    // ignore: avoid_print
    print('===== END =====');

    expect(failures, isEmpty, reason: '有功能未通过：\n${failures.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 16)));
}
