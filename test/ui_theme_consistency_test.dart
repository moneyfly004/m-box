// 外观模式（6 套）与通用控件的一致性守卫。
//
// 背景（都是这次审计/实测发现的）：
//  1) 开关的「关闭」态轨道写死深蓝 `0xFF2A3242`：在 light / warm / gray 这些
//     浅色外观下，关闭的开关看起来就是一个深色药丸 —— 和「打开」几乎一样，
//     用户分不清 TUN / 自动重连 / 证书校验到底开没开。
//  2) 我的 / 套餐 / 升级设备三处卡片写死 `0x..455FE9`（浅色模式的品牌蓝），
//     切到其它 5 套外观后卡片还是蓝的，和边框/文字的品牌色对不上。
//  3) 注册页的「同意条款」是写死的中文，且《用户协议》《隐私政策》只是彩色
//     文字、点了没有任何反应；勾选框只有 18×18 可点。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/auth/register_page.dart';
import 'package:mbox/theme/app_theme.dart';
import 'package:mbox/widgets/mf_input.dart';
import 'package:mbox/theme/theme_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => ThemeController.instance.appearance = 'light');
  tearDown(() => ThemeController.instance.appearance = 'light');

  /// 复刻 main.dart 的主题接线：外观模式决定用哪套 palette，
  /// MaterialApp 会同时建 light/dark 两套（真实渲染的那套由 themeMode 决定）
  ThemeData themeOf(String appearance) {
    ThemeController.instance.appearance = appearance;
    final isDark = mfThemeOf(appearance).isDark;
    return buildMBoxTheme(
        brightness: isDark ? Brightness.dark : Brightness.light);
  }

  test('浅色外观下「关闭」的开关不能是深色（否则看起来像打开）', () {
    final theme = themeOf('light');
    final off = theme.switchTheme.trackColor!.resolve({});
    final on = theme.switchTheme.trackColor!.resolve({WidgetState.selected});
    expect(off, isNotNull);
    expect(off, isNot(const Color(0xFF2A3242)),
        reason: '关闭态轨道写死深蓝 = 浅色外观下开关看起来是开的');
    // 浅色外观：关闭态必须是浅色（亮度高）
    expect(off!.computeLuminance(), greaterThan(0.5),
        reason: '浅色外观下关闭态轨道应该是浅色底');
    expect(off, isNot(on));
  });

  test('6 套外观模式的关闭态开关都各自跟着主题走', () {
    final seen = <Color>{};
    for (final k in ['light', 'warm', 'gray', 'darkgray', 'darkblue', 'black']) {
      final off = themeOf(k).switchTheme.trackColor!.resolve({})!;
      seen.add(off);
      if (mfThemeOf(k).isDark) {
        expect(off, const Color(0xFF2A3242), reason: '$k 是深色外观，关闭态应保持深色轨道');
      } else {
        expect(off.computeLuminance(), greaterThan(0.5),
            reason: '$k 是浅色外观，关闭态轨道不该是深色');
      }
    }
    expect(seen.length, greaterThan(1), reason: '所有外观共用同一个关闭态颜色 = 没跟随主题');
  });

  test('卡片品牌光晕不能写死浅色模式的品牌蓝', () {
    // 源码级守卫：0x..455FE9 是 light 模式的品牌蓝，写死就会无视外观切换
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File) continue;
      // Windows 的路径分隔符是 \ —— 必须归一化后再比较，否则
      // 「排除调色板本身」这条在 Windows 上失效，app_theme.dart 里的
      // 品牌色定义会被当成违规（CI Windows job 实测红过一次）
      final rel = f.path.replaceAll(r'\', '/');
      if (!rel.endsWith('.dart')) continue;
      if (rel.endsWith('theme/app_theme.dart')) continue; // 调色板本身
      final src = f.readAsStringSync();
      for (final m in RegExp(r'0x[0-9A-Fa-f]{2}455FE9').allMatches(src)) {
        offenders.add('$rel: ${m.group(0)}');
      }
    }
    expect(offenders, isEmpty,
        reason: '品牌色请用 MBColors.brand.withValues(alpha: ...)，否则 6 套外观里只有 1 套是对的');
  });

  testWidgets('主按钮禁用态必须看得出来（旧实现和启用态长得一样）', (tester) async {
    // 启用态：品牌渐变 + 白字
    await tester.pumpWidget(MaterialApp(
      theme: buildMBoxTheme(brightness: Brightness.light),
      home: Scaffold(
          body: MBPrimaryButton(label: 'GO', onPressed: () {})),
    ));
    final on = tester
        .widget<DecoratedBox>(find.descendant(
            of: find.byType(MBPrimaryButton), matching: find.byType(DecoratedBox)).first)
        .decoration as BoxDecoration;
    expect(on.gradient, isNotNull);

    // 禁用态：无渐变、卡片底色、文字用弱化色 —— 用户一眼能看出不可点
    await tester.pumpWidget(MaterialApp(
      theme: buildMBoxTheme(brightness: Brightness.light),
      home: const Scaffold(body: MBPrimaryButton(label: 'GO')),
    ));
    final off = tester
        .widget<DecoratedBox>(find.descendant(
            of: find.byType(MBPrimaryButton), matching: find.byType(DecoratedBox)).first)
        .decoration as BoxDecoration;
    expect(off.gradient, isNull, reason: '禁用态仍是完整渐变 = 看起来可点，点了没反应');
    expect(off.color, MBColors.card2);
    final label = tester.widget<Text>(find.text('GO'));
    expect(label.style!.color, MBColors.txt3);
  });

  test('输入框只有一套样式：mfInput 与全局 inputDecorationTheme 一致', () {
    final deco = mfInput(hint: 'hint', errorText: 'bad');
    final theme = buildMBoxTheme(brightness: Brightness.light);
    final t = theme.inputDecorationTheme;
    expect(deco.fillColor, t.fillColor, reason: '两处填充色不同 = 同一种输入框两个样子');
    expect(deco.hintStyle!.fontSize, t.hintStyle!.fontSize);
    expect((deco.enabledBorder! as OutlineInputBorder).borderRadius,
        (t.enabledBorder! as OutlineInputBorder).borderRadius);
    // 错误态有专门的样式（旧实现定义了 errorStyle 但没人用）
    expect(deco.errorText, 'bad');
    expect(deco.errorStyle, isNotNull);
  });

  testWidgets('注册页同意条款：随语言本地化、链接可点、整行可点', (tester) async {
    await AppStrings.setLang('en', persist: false);
    final opened = <String>[];
    RegisterPage.debugOpenUrlOverride = (url) async {
      opened.add(url);
      return true;
    };
    addTearDown(() => RegisterPage.debugOpenUrlOverride = null);

    // 注册页很长，同意条款在最下面 —— 窗口开高一点，保证它可见可点
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildMBoxTheme(brightness: Brightness.light),
        home: const RegisterPage()));
    await tester.pump();

    // 不再出现写死的中文
    expect(find.textContaining('我已阅读并同意', findRichText: true), findsNothing);
    expect(find.textContaining('Terms of Service', findRichText: true), findsOneWidget);

    // 点《用户协议》→ 真的打开外链（旧实现点了没反应）
    await tester.tapOnText(find.textRange.ofSubstring('Terms of Service'));
    await tester.pump();
    expect(opened, [RegisterPage.docsUrl]);

    // 勾选框整行可点，命中区域高度 ≥ 40（旧实现只有 18×18）
    final box = find.byType(RegisterPage);
    expect(box, findsOneWidget);
    final hit = tester.getSize(find.ancestor(
        of: find.textContaining('Terms of Service', findRichText: true),
        matching: find.byType(GestureDetector)).first);
    expect(hit.height, greaterThanOrEqualTo(40),
        reason: '勾选框命中区域太小（旧实现 18×18）');
  });
}
