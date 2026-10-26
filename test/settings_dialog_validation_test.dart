// 设置页对话框交互回归测试（UI 审计 P1 ~ P4）。
//
// 背景（都是这次审计发现的）：
//   P1 文本对话框（本地端口 / Clash API 端口 / 测速地址 / 主 DNS 列表 / fake-ip
//      过滤）都是同一个坏模式：**先 `Navigator.pop(ctx, 值)`、关闭之后才校验**，
//      失败只能弹一个 4 秒的 snackbar —— 用户（尤其一次性粘贴一整串 DNS 的）输入
//      全被丢掉，必须重新打开对话框、重新输入。
//      现在校验在对话框内部执行：只有通过才 pop，失败时对话框不关、错误常驻在
//      输入框下方（errorText）、内容原样保留。
//   P2 选择器对话框不标当前值（节点页 / 内核页都有勾）；`_seg2` 与外观色卡用
//      GestureDetector + Container，按下去没有任何反馈。
//   P3 语言对话框标题写死英文 'Language'。
//
// 本文件只覆盖上述行为，不改动任何既有测试文件。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/settings_page.dart';
import 'package:mbox/theme/app_theme.dart';
import 'package:mbox/theme/theme_controller.dart';

const String _settingsKey = 'mbox_settings_v1';

/// 起页面：380×620 是应用允许的最小窗口（对话框最挤的尺寸）
Future<void> _pump(WidgetTester tester, {Size size = const Size(380, 620)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: ConnectionController.instance),
      ChangeNotifierProvider.value(value: AccountService.instance),
    ],
    child: MaterialApp(theme: buildMBoxTheme(), home: const SettingsPage()),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 点开某一行（设置页是懒加载 ListView，目标行常在视口外）
Future<void> _tapRow(WidgetTester tester, String title) async {
  final f = find.text(title);
  await tester.scrollUntilVisible(f, 220,
      scrollable: find.byType(Scrollable).first);
  await tester.pump();
  await tester.tap(f);
  await tester.pumpAndSettle(); // 对话框入场动画走完，再点里面的控件
}

Finder _inDialog(Finder matching) =>
    find.descendant(of: find.byType(Dialog), matching: matching);

Finder _dlgField() => _inDialog(find.byType(TextField));

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(_dlgField()).controller!.text;

/// 让真实的异步写盘跑完。设置写盘走 SerialExecutor + SharedPreferences 通道：
/// pop 动画与微任务靠 pump 推进，而真正的落盘需要真实时间（纯 fake-async 的 pump
/// 推不动它）—— 仓库惯例同 autostart_test.dart 的 _tapSwitch。
Future<void> _flushWrites(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 60));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
  }
  await tester.pump();
}

/// 点对话框里的「保存」：校验通过 → 对话框关闭 + 落盘；不通过 → 原地不动
Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(_inDialog(find.text(AppStrings.t('save'))));
  await tester.pumpAndSettle();
  await _flushWrites(tester);
}

Future<void> _tapCancel(WidgetTester tester) async {
  await tester.tap(_inDialog(find.text(AppStrings.t('cancel_text'))));
  await tester.pumpAndSettle();
  await _flushWrites(tester);
}

/// 对话框仍在（pumpAndSettle 之后再断言 —— 若真的 pop 了，动画已走完、找不到）
void _expectDialogOpen() {
  expect(find.byType(AlertDialog), findsOneWidget,
      reason: '非法输入必须留在对话框里让用户就地改，不能关掉再弹 4 秒 snackbar');
}

/// 清掉 snackbar 的 4 秒定时器，避免测试结束时留下挂起 timer
Future<void> _drainSnackBars(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 写队列是进程级单例：上一个用例若留下未跑完的入队任务，本用例的所有落盘
    // 都会静默排在它后面（表现为「单独跑通过、整文件跑就值没存上」）
    SettingsStore.resetForTest();
    ThemeController.instance.appearance = 'light';
  });
  tearDown(() {
    AppStrings.setLang('zh', persist: false);
    ThemeController.instance.appearance = 'light';
  });

  group('P1 对话框「先关闭再校验」修复：非法输入不关、不丢', () {
    testWidgets('主 DNS 列表：第 N 个非法 → 不关对话框、错误常驻、粘贴内容不丢',
        (tester) async {
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_dns'));
      expect(find.byType(AlertDialog), findsOneWidget);

      // 默认值预填（用户是在现有一串上改/粘贴）
      expect(_fieldText(tester), '223.5.5.5, 119.29.29.29');

      const pasted = '223.5.5.5, 8.8.8.8, 不是DNS';
      await tester.enterText(_dlgField(), pasted);
      await _tapSave(tester);

      // ① 对话框没关 ② 错误常驻在输入框下方 ③ 整串输入还在
      _expectDialogOpen();
      expect(find.text(AppStrings.t('dns_list_invalid', {'n': '3'})),
          findsOneWidget,
          reason: '错误必须常驻在输入框下方，而不是闪 4 秒的 snackbar');
      expect(_fieldText(tester), pasted, reason: '用户的输入被丢掉了');
      expect(find.byType(SnackBar), findsNothing,
          reason: '旧实现弹 snackbar 时对话框已经关了');
      expect(tester.takeException(), isNull,
          reason: '最小窗口 380×620 下多一行错误文案不能溢出');

      // 就地改对 → 保存成功、对话框关闭、值真的落盘
      await tester.enterText(_dlgField(), '1.1.1.1, 223.5.5.5');
      await _tapSave(tester);
      expect(find.byType(AlertDialog), findsNothing);
      final s = await SettingsStore.instance.load();
      expect(s['dnsNameservers'], <String>['1.1.1.1', '223.5.5.5']);
    });

    testWidgets('主 DNS 列表：清空 → 提示至少保留一个（同样不关）', (tester) async {
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_dns'));

      await tester.enterText(_dlgField(), '   ');
      await _tapSave(tester);

      _expectDialogOpen();
      expect(find.text(AppStrings.t('dns_list_required')), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('本地代理端口：越界 / 与 Clash API 端口相同都不关，合法值才保存并关闭',
        (tester) async {
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_local_port'));

      // 越界（<1024）
      await tester.enterText(_dlgField(), '80');
      await _tapSave(tester);
      _expectDialogOpen();
      expect(find.text(AppStrings.t('local_port_invalid')), findsOneWidget);
      expect(_fieldText(tester), '80');
      expect(find.byType(SnackBar), findsNothing);

      // 与 Clash API 端口（默认 9090）冲突
      await tester.enterText(_dlgField(), '9090');
      await _tapSave(tester);
      _expectDialogOpen();
      expect(find.text(AppStrings.t('local_port_invalid')), findsOneWidget);
      expect(_fieldText(tester), '9090');

      // 合法值 → 关闭 + 落盘
      await tester.enterText(_dlgField(), '2081');
      await _tapSave(tester);
      expect(find.byType(AlertDialog), findsNothing);
      final s = await SettingsStore.instance.load();
      expect(s['localPort'], 2081);
      // 未连接时保存成功会提示一次（pump 掉它的 4 秒定时器）
      await _drainSnackBars(tester);
    });

    testWidgets('测速地址：非 http(s) 不关对话框，改对后保存', (tester) async {
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_test_url'));

      await tester.enterText(_dlgField(), 'ftp://example.com/probe');
      await _tapSave(tester);
      _expectDialogOpen();
      expect(find.text(AppStrings.t('test_url_invalid')), findsOneWidget);
      expect(_fieldText(tester), 'ftp://example.com/probe');
      expect(find.byType(SnackBar), findsNothing);

      await tester.enterText(_dlgField(), 'https://example.com/generate_204');
      await _tapSave(tester);
      expect(find.byType(AlertDialog), findsNothing);
      final s = await SettingsStore.instance.load();
      expect(s['testUrl'], 'https://example.com/generate_204');
    });

    testWidgets('fake-ip 过滤：非法域名不关；合法项规范化后保存', (tester) async {
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_fakeip_extra'));

      await tester.enterText(_dlgField(), '*.lan\nbad_domain!');
      await _tapSave(tester);
      _expectDialogOpen();
      expect(
          find.text(AppStrings.t('fakeip_invalid', {'line': '2'})), findsOneWidget);
      expect(_fieldText(tester), '*.lan\nbad_domain!');
      expect(find.byType(SnackBar), findsNothing);

      // 合法（含大小写 / `*.` 前缀规范化）
      await tester.enterText(_dlgField(), '*.Lan\nrouter.local');
      await _tapSave(tester);
      expect(find.byType(AlertDialog), findsNothing);
      final s = await SettingsStore.instance.load();
      expect(s['fakeIpFilterExtra'], <String>['*.lan', 'router.local']);
    });

    testWidgets('取消不写入任何东西（校验失败的路径也没有副作用）', (tester) async {
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_dns'));
      await tester.enterText(_dlgField(), 'not_a_dns!!');
      await _tapSave(tester);
      _expectDialogOpen();

      await _tapCancel(tester);
      expect(find.byType(AlertDialog), findsNothing);
      final s = await SettingsStore.instance.load();
      expect(s['dnsNameservers'], <String>['223.5.5.5', '119.29.29.29']);
    });
  });

  group('P2 选择器标出当前值', () {
    Finder optionRow(String label) => find.ancestor(
        of: find.text(label), matching: find.byType(SimpleDialogOption));

    testWidgets('后台测速间隔：勾在「存的那一项」上（60 分钟），其余行没有勾',
        (tester) async {
      // 存的是 60 而不是默认 30 —— 勾必须跟着实际值走
      SharedPreferences.setMockInitialValues({
        _settingsKey: jsonEncode({'testIntervalMin': 60})
      });
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_test_interval'));

      final min = AppStrings.t('settings_minutes');
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(
          find.descendant(
              of: optionRow('60 $min'), matching: find.byIcon(Icons.check)),
          findsOneWidget,
          reason: '当前值那一行必须有勾（旧实现选完就关了，重开看不出选的哪个）');
      expect(
          find.descendant(
              of: optionRow('30 $min'), matching: find.byIcon(Icons.check)),
          findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget, reason: '只有一个当前值');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TUN 模式：勾在当前模式那一行（存的是 force）', (tester) async {
      if (Platform.isAndroid || Platform.isIOS) return; // 移动端不显示该行
      SharedPreferences.setMockInitialValues({
        _settingsKey: jsonEncode({'tunMode': 'force'})
      });
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_tun'));

      expect(
          find.descendant(
              of: optionRow(AppStrings.t('tun_force')),
              matching: find.byIcon(Icons.check)),
          findsOneWidget);
      expect(
          find.descendant(
              of: optionRow(AppStrings.t('tun_off')),
              matching: find.byIcon(Icons.check)),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DNS 模式：勾在当前模式那一行（存的是 fake-ip）', (tester) async {
      SharedPreferences.setMockInitialValues({
        _settingsKey: jsonEncode({'dnsMode': 'fake-ip'})
      });
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_dns_mode'));

      expect(
          find.descendant(
              of: optionRow(AppStrings.t('dns_mode_fakeip')),
              matching: find.byIcon(Icons.check)),
          findsOneWidget);
      expect(
          find.descendant(
              of: optionRow(AppStrings.t('dns_mode_auto')),
              matching: find.byIcon(Icons.check)),
          findsNothing);
    });
  });

  group('P3 语言对话框标题', () {
    testWidgets('中文下标题是「语言」，不再写死英文 Language', (tester) async {
      await AppStrings.setLang('zh', persist: false);
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_language'));

      expect(
          find.descendant(
              of: find.byType(SimpleDialog),
              matching: find.text(AppStrings.t('settings_language'))),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(SimpleDialog), matching: find.text('Language')),
          findsNothing,
          reason: '项目默认中文，标题写死英文与界面其它文案不一致');
    });

    testWidgets('英文下标题是 Language', (tester) async {
      await AppStrings.setLang('en', persist: false);
      await _pump(tester);
      await _tapRow(tester, AppStrings.t('settings_language'));

      expect(
          find.descendant(
              of: find.byType(SimpleDialog), matching: find.text('Language')),
          findsOneWidget);
    });
  });

  group('P4 按压反馈', () {
    testWidgets('分段控件可点区域是 InkWell（旧实现 GestureDetector 按下去毫无反应）',
        (tester) async {
      await _pump(tester);
      final smart = find.text(AppStrings.t('smart_mode'));

      // 有 InkWell + 自己的墨水层（Material），水波纹才有地方画
      expect(find.ancestor(of: smart, matching: find.byType(InkWell)),
          findsWidgets,
          reason: '旧实现是 GestureDetector，没有按压反馈');
      final mat = find.ancestor(of: smart, matching: find.byType(Material)).first;
      expect(tester.widget<Material>(mat).color, Colors.transparent);

      // 按下确实落在这个可点区域上：点「全局模式」→ 设置真的改了
      await tester.tap(find.text(AppStrings.t('global_mode')));
      await tester.pumpAndSettle();
      await _flushWrites(tester);
      final s = await SettingsStore.instance.load();
      expect(s['defaultMode'], 'global');
    });

    testWidgets('外观色卡也是 InkWell（旧实现按下去没有反馈）', (tester) async {
      await _pump(tester);
      final label = AppStrings.t(mfThemeLabels['darkblue'] ?? '');
      expect(label, isNotEmpty);

      final f = find.text(label);
      await tester.scrollUntilVisible(f, 220,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(find.ancestor(of: f, matching: find.byType(InkWell)), findsWidgets);

      await tester.tap(f);
      await tester.pumpAndSettle();
      await _flushWrites(tester);
      expect(ThemeController.instance.appearance, 'darkblue');
      final s = await SettingsStore.instance.load();
      expect(s['appearance'], 'darkblue');
    });
  });
}
