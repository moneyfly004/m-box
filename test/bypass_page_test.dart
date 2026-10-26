// 直连名单页（BypassPage）UI 审计回归：
//
// 1) P1：设置读取抛错时**不能**死在一个没有 AppBar/返回按钮的转圈页
//    （旧实现 `SettingsStore.instance.load().then(...)` 没有 catchError，
//    一旦抛错 `_loaded` 永远为 false → 页面永远转圈、只能重启 App）。
// 2) P1：「添加」在空输入时不能点了毫无反应（按钮必须呈禁用态；
//    键盘回车这条路径给明确提示）。
// 3) P2：删除按钮是破坏性操作，命中区 ≥40 且要有按压反馈（InkWell）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/bypass_page.dart';
import 'package:mbox/theme/app_theme.dart';

/// 小窗口（应用允许的最小窗口），Ahem 测试字体下依然不能溢出/不可点
const Size _kMinWindow = Size(380, 620);

Future<void> _pump(WidgetTester tester, {bool pushed = false}) async {
  tester.view.physicalSize = _kMinWindow;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final page = MaterialApp(theme: buildMBoxTheme(), home: const BypassPage());
  if (!pushed) {
    await tester.pumpWidget(page);
  } else {
    // 从上一页 push 进来，才能验证 AppBar 的返回按钮真的能返回
    await tester.pumpWidget(MaterialApp(
      theme: buildMBoxTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const BypassPage())),
            child: const Text('open-bypass'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open-bypass'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppStrings.setLang('zh', persist: false);
  });

  tearDown(() async {
    BypassPage.debugLoadOverride = null;
    await AppStrings.setLang('zh', persist: false);
  });

  testWidgets('设置读取抛错：不是死转圈 —— 有 AppBar、错误说明与重试', (tester) async {
    BypassPage.debugLoadOverride = () async => throw StateError('boom');
    await _pump(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '读取失败后仍在转圈 = 用户永远等不到结果');
    expect(find.byType(AppBar), findsOneWidget, reason: '旧实现这一页没有 AppBar');
    expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget,
        reason: '没有返回入口 → 只能重启 App');
    expect(find.text(AppStrings.t('bypass_load_fail')), findsOneWidget,
        reason: '错误态必须能看懂，不能只有转圈');
    expect(find.text(AppStrings.t('retry')), findsOneWidget, reason: '必须能重试');
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置读取抛错：返回按钮真的能退出这一页', (tester) async {
    BypassPage.debugLoadOverride = () async => throw StateError('boom');
    await _pump(tester, pushed: true);

    expect(find.byType(BypassPage), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();

    expect(find.byType(BypassPage), findsNothing, reason: '错误态下必须能返回');
  });

  testWidgets('设置读取抛错 → 重试成功：名单正常显示', (tester) async {
    BypassPage.debugLoadOverride = () async => throw StateError('boom');
    await _pump(tester);
    expect(find.text(AppStrings.t('bypass_load_fail')), findsOneWidget);

    // 故障恢复（例如 prefs 恢复可用）后重试
    BypassPage.debugLoadOverride =
        () async => <String, dynamic>{'bypassDomains': <String>['company.com']};
    await tester.tap(find.text(AppStrings.t('retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(AppStrings.t('bypass_load_fail')), findsNothing);
    expect(find.text('company.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空输入：「添加」是禁用态，回车给出明确提示', (tester) async {
    BypassPage.debugLoadOverride =
        () async => <String, dynamic>{'bypassDomains': <String>[]};
    await _pump(tester);

    final addBtn = find.widgetWithText(InkWell, AppStrings.t('bypass_add'));
    expect(addBtn, findsOneWidget);
    expect(tester.widget<InkWell>(addBtn).onTap, isNull,
        reason: '空输入时按钮看着能点、点了却毫无反应（旧实现）');
    expect(tester.getSize(addBtn).height, greaterThanOrEqualTo(40),
        reason: '禁用态不能让命中区变小');

    // 键盘回车（onSubmitted）也必须给出「为什么没反应」
    await tester.enterText(find.byType(TextField), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(AppStrings.t('bypass_input_empty')), findsOneWidget);
  });

  testWidgets('输入合法域名：按钮恢复可点，点击后条目入列', (tester) async {
    BypassPage.debugLoadOverride =
        () async => <String, dynamic>{'bypassDomains': <String>[]};
    await _pump(tester);

    await tester.enterText(find.byType(TextField), 'company.com');
    await tester.pump();
    final addBtn = find.widgetWithText(InkWell, AppStrings.t('bypass_add'));
    expect(tester.widget<InkWell>(addBtn).onTap, isNotNull,
        reason: '有输入时按钮必须可点');

    await tester.tap(addBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('company.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除按钮：命中区 ≥40×40 且用 InkWell（破坏性操作要有反馈）', (tester) async {
    BypassPage.debugLoadOverride = () async =>
        <String, dynamic>{'bypassDomains': <String>['company.com']};
    await _pump(tester);

    final del = find
        .ancestor(of: find.byIcon(Icons.close), matching: find.byType(InkWell))
        .first;
    final size = tester.getSize(del);
    expect(size.height, greaterThanOrEqualTo(40),
        reason: '旧实现 30×30 命中区偏小（且无按压反馈）');
    expect(size.width, greaterThanOrEqualTo(40));
    expect(tester.takeException(), isNull);
  });
}
