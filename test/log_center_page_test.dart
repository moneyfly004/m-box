// 日志中心（LogCenterPage）UI 审计回归：
//
// 1) P2：内核日志 tab 的「清空」以前是 `setState(_lines.clear)` 直接清空，
//    而 App 日志 tab 有确认框 —— 一次误点就毁掉客服最需要的现场日志。
//    现在两个 tab 走同一份确认实现：取消后日志必须还在。
// 2) P2：日志行以前是**每行一个 SelectableText**（最多 600 个选区状态，
//    低端机明显卡顿），现在改成普通 Text + 整块一个 SelectionArea。
//    （滚动本身仍是 ListView，颜色分级/等宽字体/复制入口都不能变。）
// 3) P2：等级筛选 chip 以前是 GestureDetector + ~23px 容器（无按压反馈、命中区小），
//    现在是 InkWell 且命中区 ≥40。
// 4) P2：工具栏的「未连接」提示以前直接读单例快照，连接状态变了不会刷新。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/log_center_page.dart';
import 'package:mbox/theme/app_theme.dart';

const Size _kMinWindow = Size(380, 620);
const String _errLine = 'time="2024" level=error msg="boom-alpha"';
const String _dbgLine = 'time="2024" level=debug msg="debug-only-line"';

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = _kMinWindow;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      theme: buildMBoxTheme(), home: const LogCenterPage()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 塞一行内核日志（页面在非 Android 平台订阅 [ProxyCoreCli.kernelLogStream]）
Future<void> _feed(WidgetTester tester, String line) async {
  ProxyCoreCli.kernelLogStream.add(line);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

Finder _dialogButton(String label) => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(TextButton, label));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // 级别设为 debug，保证两类日志行都可见（与本用例关注点无关）
    SharedPreferences.setMockInitialValues({
      'mbox_settings_v1': jsonEncode({'kernelLogLevel': 'debug'}),
    });
    await AppStrings.setLang('zh', persist: false);
    ConnectionController.instance.status = ConnStatus.disconnected;
  });

  tearDown(() async {
    ConnectionController.instance.status = ConnStatus.disconnected;
    await AppStrings.setLang('zh', persist: false);
  });

  testWidgets('内核日志「清空」必须先确认；取消后日志仍在', (tester) async {
    await _pump(tester);
    await _feed(tester, _errLine);
    expect(find.text(_errLine), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.t('clear_log')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: '旧实现这里直接清空，没有任何确认');
    expect(find.text(AppStrings.t('kernel_log_clear_confirm')), findsOneWidget);

    await tester.tap(_dialogButton(AppStrings.t('cancel_text')));
    await tester.pumpAndSettle();
    expect(find.text(_errLine), findsOneWidget, reason: '取消后日志必须还在');

    await tester.tap(find.byTooltip(AppStrings.t('clear_log')));
    await tester.pumpAndSettle();
    await tester.tap(_dialogButton(AppStrings.t('clear_log')));
    await tester.pumpAndSettle();
    expect(find.text(_errLine), findsNothing, reason: '确认后才清空');
    expect(tester.takeException(), isNull);
  });

  testWidgets('日志行：不再是每行一个 SelectableText，但仍是可选可复制的普通 Text',
      (tester) async {
    await _pump(tester);
    await _feed(tester, _errLine);

    expect(find.byType(SelectableText), findsNothing,
        reason: '600 个 SelectableText 各自带选区状态，是这页卡顿的根因');
    expect(find.byType(SelectionArea), findsWidgets,
        reason: '整块仍需可选择');

    final line = find.text(_errLine);
    expect(line, findsOneWidget);
    // 颜色分级（error=红）与等宽字体不变
    final style = tester.widget<Text>(line).style!;
    expect(style.color, const Color(0xFFFF6B6B));
    expect(style.fontFamily, kNumFont);
    // 复制入口仍在
    expect(find.byTooltip(AppStrings.t('copy')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('等级 chip：命中区 ≥40 且是 InkWell（点击即切换过滤）', (tester) async {
    // 这一个用例要看「过滤」，所以级别先用默认 warning
    SharedPreferences.setMockInitialValues({
      'mbox_settings_v1': jsonEncode({'kernelLogLevel': 'warning'}),
    });
    await _pump(tester);
    await _feed(tester, _dbgLine);
    expect(find.text(_dbgLine), findsNothing, reason: 'warning 级别下过滤掉 debug 行');

    final chip = find
        .ancestor(of: find.text('DEBUG'), matching: find.byType(InkWell))
        .first;
    final size = tester.getSize(chip);
    expect(size.height, greaterThanOrEqualTo(40),
        reason: '旧实现 ~23px 高且没有按压反馈');
    expect(size.width, greaterThanOrEqualTo(40));

    await tester.tap(chip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(_dbgLine), findsOneWidget, reason: '切到 DEBUG 后应能看见');
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具栏连接状态随控制器刷新（不再读死快照）', (tester) async {
    await _pump(tester);
    expect(find.text(AppStrings.t('kernel_stopped')), findsOneWidget);

    // 连接状态变化 + 控制器通知（applySettings 会 notifyListeners）
    ConnectionController.instance.status = ConnStatus.connected;
    ConnectionController.instance.applySettings(const <String, dynamic>{});
    await tester.pump();

    expect(find.text(AppStrings.t('kernel_stopped')), findsNothing,
        reason: '旧实现在 build 里读单例快照，连上后这里还显示「未连接」');
    expect(tester.takeException(), isNull);
  });
}
