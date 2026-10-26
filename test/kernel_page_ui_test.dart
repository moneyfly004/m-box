// 内核管理页（KernelPage）UI 审计回归：
//
// 1) P2：「内核变体」行的值以前是 `'${_variantLabel(_variant)} ▾'`，而行本身
//    由 MBRow 追加了一个 chevron_right 箭头 —— 同一行两个互相打架的指示符。
//    （本机是 macOS arm64，`KernelManager.supportsVariant` 为 false，
//     这一行在 widget 测试里渲染不出来，所以用源码级守卫 + 行组件约定断言。）
// 2) P2：「连接状态」行以前在 build 里直接读 `ConnectionController.instance.status`
//    的快照，连上/断开后不会刷新。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/kernel_page.dart';
import 'package:mbox/theme/app_theme.dart';
import 'package:mbox/widgets/mf_row.dart';

const Size _kMinWindow = Size(380, 620);

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = _kMinWindow;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      theme: buildMBoxTheme(), home: const KernelPage()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppStrings.setLang('zh', persist: false);
    ConnectionController.instance.status = ConnStatus.disconnected;
  });

  tearDown(() async {
    ConnectionController.instance.status = ConnStatus.disconnected;
    await AppStrings.setLang('zh', persist: false);
  });

  test('「内核变体」的值不再自带 ▾（行尾箭头由 MBRow 统一提供）', () {
    final src = File('lib/pages/settings/kernel_page.dart').readAsStringSync();
    // 只看代码，不看注释（注释里会引用这个被去掉的字符）
    final code = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(code.contains('▾'), isFalse,
        reason: '值里再拼一个 ▾ 会和 MBRow 行尾的 chevron_right 打架');
    expect(code.contains('value: _variantLabel(_variant),'), isTrue,
        reason: '变体行的值应就是变体名本身');
    // 行尾箭头的唯一来源：MBRow（value != null 时自动追加）
    expect(code.contains('Icon(Icons.chevron_right'), isFalse,
        reason: '页面自己再加一个箭头 = 又回到两个指示符');
  });

  testWidgets('「连接状态」行随控制器刷新（不再读死快照）', (tester) async {
    await _pump(tester);
    expect(find.text(AppStrings.t('kernel_stopped')), findsOneWidget);

    ConnectionController.instance.status = ConnStatus.connected;
    ConnectionController.instance.applySettings(const <String, dynamic>{});
    await tester.pump();

    expect(find.text(AppStrings.t('kernel_running')), findsOneWidget,
        reason: '旧实现读死快照：连上后这一行还是「未连接」');
    expect(find.text(AppStrings.t('kernel_stopped')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('行仍是 MBRow（最小高度 + 描述独占一行），最小窗口零渲染异常', (tester) async {
    await _pump(tester);
    expect(find.byType(MBRow), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
