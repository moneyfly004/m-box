// 「小窗口 + 英文/中文都不溢出」的回归测试。
//
// 背景：设置类页面把「一行」写成 `Container(height: 52)`，标题/描述和「值(≤150px)」
// 挤在同一行 —— 380 宽（应用允许的最小窗口）下描述只剩 ~94px 宽，英文说明要折成
// 十几行，实测一次设置页停留就抛 37 次 RenderFlex overflow（中文也会），
// 表现是文字被裁掉/画到卡片外面。同一个「一行」被复制到 kernel_page 与 geo_update_page。
//
// 现在三页统一用 lib/widgets/mf_row.dart 的 MBRow（最小高度 + 描述独占一行 + 省略号），
// 这条用例在 380×620 与 420×780 下把三页从头滚到底，断言**一个渲染异常都没有**。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/geo_update_page.dart';
import 'package:mbox/pages/settings/kernel_page.dart';
import 'package:mbox/pages/settings/settings_page.dart';
import 'package:mbox/theme/app_theme.dart';

Future<void> _pump(WidgetTester tester, Widget page, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: ConnectionController.instance),
      ChangeNotifierProvider.value(value: AccountService.instance),
    ],
    child: MaterialApp(theme: buildMBoxTheme(), home: page),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 整页滚到底：让所有懒加载的行都建出来
Future<void> _scrollAll(WidgetTester tester) async {
  final sc = find.byType(Scrollable).first;
  for (var i = 0; i < 40; i++) {
    await tester.drag(sc, const Offset(0, -300));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppStrings.setLang('zh', persist: false));

  testWidgets('英文 + 最小窗口：行尾控件不能把标题挤没（旧实现标题宽度 = 0）', (tester) async {
    await AppStrings.setLang('en', persist: false);
    await _pump(tester, const SettingsPage(), const Size(380, 620));
    final title = find.text(AppStrings.t('settings_default_mode'));
    expect(title, findsOneWidget);
    expect(tester.getSize(title).width, greaterThan(40),
        reason: '「Default mode」标题被行尾的分段开关挤成 0 宽 —— 文字看不见');
    // 行尾控件最多占 55%
    final row = tester.getRect(find.ancestor(
        of: title, matching: find.byType(Row)).first);
    final seg = find.text(AppStrings.t('global_mode'));
    expect(tester.getRect(seg).right, lessThanOrEqualTo(row.right + .5));
  });

  for (final lang in ['zh', 'en']) {
    for (final size in const [Size(380, 620), Size(420, 780)]) {
      testWidgets('设置页 $lang @ ${size.width.toInt()}x${size.height.toInt()}：渲染零异常',
          (tester) async {
        await AppStrings.setLang(lang, persist: false);
        await _pump(tester, const SettingsPage(), size);
        await _scrollAll(tester);
        expect(tester.takeException(), isNull,
            reason: '固定高度 52 的行在最小窗口下会把 $lang 描述裁掉');
      });

      testWidgets('内核页 $lang @ ${size.width.toInt()}x${size.height.toInt()}：渲染零异常',
          (tester) async {
        await AppStrings.setLang(lang, persist: false);
        await _pump(tester, const KernelPage(), size);
        await _scrollAll(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Geo 数据页 $lang @ ${size.width.toInt()}x${size.height.toInt()}：渲染零异常',
          (tester) async {
        await AppStrings.setLang(lang, persist: false);
        await _pump(tester, const GeoUpdatePage(), size);
        await _scrollAll(tester);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
