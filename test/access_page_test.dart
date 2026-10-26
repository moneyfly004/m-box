// 应用代理页（AccessPage）UI 审计回归：
//
// 1) P2：AppBar 的「重连生效」以前在 build 里直接读
//    `ConnectionController.instance.status` 的快照 —— 连上/断开后这一格不刷新。
// 2) P2：`catch (_) {}` 把「平台通道读取失败」和「读到了但列表为空」
//    混成一句「请去系统设置开权限」；现在失败要如实报错并可重试。
// 3) P2：模式按钮以前是 GestureDetector + ~30px 容器（无按压反馈、命中区偏小）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/access_page.dart';
import 'package:mbox/theme/app_theme.dart';

const Size _kMinWindow = Size(380, 620);
const MethodChannel _channel = MethodChannel('top.mbox/vpn_core');

List<Map<String, String>> _apps = const [
  {'package': 'com.demo.one', 'label': 'Demo One'},
  {'package': 'com.demo.two', 'label': 'Demo Two'},
];

/// 让原生通道返回应用列表 / 直接失败
void _mockApps({required bool fail}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method != 'getInstalledApps') return null;
    if (fail) throw PlatformException(code: 'channel-error');
    return _apps;
  });
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = _kMinWindow;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
      MaterialApp(theme: buildMBoxTheme(), home: const AccessPage()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'mbox_settings_v1': jsonEncode({'accessControlMode': 'all'}),
    });
    await AppStrings.setLang('zh', persist: false);
    ConnectionController.instance.status = ConnStatus.disconnected;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    ConnectionController.instance.status = ConnStatus.disconnected;
    await AppStrings.setLang('zh', persist: false);
  });

  testWidgets('AppBar「重连生效」随连接状态刷新', (tester) async {
    _mockApps(fail: false);
    await _pump(tester);

    // 未连接：显示「更改已保存…」且不可点（点了本来也什么都不做）
    final idle = find.widgetWithText(TextButton, AppStrings.t('access_saved_tip'));
    expect(idle, findsOneWidget);
    expect(tester.widget<TextButton>(idle).onPressed, isNull);

    // 连上（控制器 notifyListeners）
    ConnectionController.instance.status = ConnStatus.connected;
    ConnectionController.instance.applySettings(const <String, dynamic>{});
    await tester.pump();

    final live =
        find.widgetWithText(TextButton, AppStrings.t('access_reconnect_btn'));
    expect(live, findsOneWidget,
        reason: '旧实现读死快照：连上后 AppBar 还是旧文案');
    expect(tester.widget<TextButton>(live).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('平台读取失败：如实报错 + 可重试（不再误引导去开权限）', (tester) async {
    _mockApps(fail: true);
    await _pump(tester);

    expect(find.text(AppStrings.t('access_load_error')), findsOneWidget,
        reason: '读取失败必须有区别于「权限」的文案');
    expect(find.text(AppStrings.t('access_empty_perm')), findsNothing);
    expect(find.text(AppStrings.t('retry')), findsOneWidget);

    // 故障恢复后重试 → 列表出现
    _mockApps(fail: false);
    await tester.tap(find.text(AppStrings.t('retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Demo One'), findsOneWidget);
    expect(find.text(AppStrings.t('access_load_error')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('成功但列表为空：仍是「权限」引导（与读取失败区分开）', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => <Map>[]);
    await _pump(tester);

    expect(find.text(AppStrings.t('access_empty_perm')), findsOneWidget);
    expect(find.text(AppStrings.t('access_load_error')), findsNothing);
  });

  testWidgets('模式按钮：命中区 ≥40 且是 InkWell（有按压反馈）', (tester) async {
    _mockApps(fail: false);
    await _pump(tester);

    for (final label in [
      AppStrings.t('access_mode_all'),
      AppStrings.t('access_mode_selected'),
      AppStrings.t('access_mode_denied'),
    ]) {
      final btn =
          find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;
      final size = tester.getSize(btn);
      expect(size.height, greaterThanOrEqualTo(40),
          reason: '「$label」命中区偏小（旧实现 ~30px 且无按压反馈）');
      expect(size.width, greaterThanOrEqualTo(40));
    }

    // 点击切模式仍然生效
    await tester.tap(find.text(AppStrings.t('access_mode_denied')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(AppStrings.t('access_hint_denied')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
