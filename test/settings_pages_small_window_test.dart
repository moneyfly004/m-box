// 我这次改动的三个页面（直连名单 / 应用代理 / 日志中心）在**最小窗口 380×620**
// 下的渲染回归：中英文都不能出现 RenderFlex overflow 等渲染异常。
//
// 背景：Ahem 测试字体每个字符都是方块（比真实字体宽约 1.6 倍），英文标签比中文长，
// 所以「中英双语 × 最小窗口」是这轮 UI 审计的硬门槛（与 test/page_overflow_test.dart
// 对 settings/kernel/geo 三页的要求一致）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/proxy/proxy_core_cli.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/access_page.dart';
import 'package:mbox/pages/settings/bypass_page.dart';
import 'package:mbox/pages/settings/log_center_page.dart';
import 'package:mbox/theme/app_theme.dart';

const Size _kMinWindow = Size(380, 620);
const MethodChannel _channel = MethodChannel('top.mbox/vpn_core');

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = _kMinWindow;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildMBoxTheme(), home: page));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'mbox_settings_v1': jsonEncode({
        'kernelLogLevel': 'debug',
        'accessControlMode': 'selected',
        'bypassDomains': <String>[
          'company.com',
          'DOMAIN:portal.example.com',
          'IP-CIDR:192.168.1.0/24',
        ],
      }),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method != 'getInstalledApps') return null;
      return <Map<String, String>>[
        {'package': 'com.demo.one', 'label': 'Demo One'},
        {'package': 'com.demo.two', 'label': 'Demo Two'},
      ];
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    BypassPage.debugLoadOverride = null;
    await AppStrings.setLang('zh', persist: false);
  });

  for (final lang in ['zh', 'en']) {
    testWidgets('直连名单 $lang @ 380x620：渲染零异常（含错误态）', (tester) async {
      await AppStrings.setLang(lang, persist: false);
      await _pump(tester, const BypassPage());
      expect(tester.takeException(), isNull);

      // 错误态同样要在最小窗口下成立（先卸载再挂载，让 initState 重跑）
      BypassPage.debugLoadOverride = () async => throw StateError('boom');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await _pump(tester, const BypassPage());
      expect(find.text(AppStrings.t('bypass_load_fail')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('应用代理 $lang @ 380x620：渲染零异常', (tester) async {
      await AppStrings.setLang(lang, persist: false);
      await _pump(tester, const AccessPage());
      expect(find.text('Demo One'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('日志中心 $lang @ 380x620：渲染零异常（含长日志行）', (tester) async {
      await AppStrings.setLang(lang, persist: false);
      await _pump(tester, const LogCenterPage());
      // 一行很长的 error 日志（内核日志真实长度），必须换行而不是溢出
      ProxyCoreCli.kernelLogStream.add(
          'time="2024-01-01T00:00:00Z" level=error msg="failed to get the '
          'second response from https://www.gstatic.com/generate_204: '
          'context deadline exceeded (Client.Timeout exceeded while awaiting headers)"');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(tester.takeException(), isNull);
    });
  }
}
