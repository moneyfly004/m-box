import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/auth/register_page.dart';
import 'package:moneyfly/pages/settings/settings_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'moneyfly_lang': 'zh'}));
  testWidgets('启动进入登录页', (tester) async {
    await tester.pumpWidget(const MoneyFlyApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MBox'), findsOneWidget);
    expect(find.text('登 录'), findsOneWidget);
    expect(find.textContaining('注册', findRichText: true), findsWidgets);
    expect(find.textContaining('忘记密码', findRichText: true), findsWidgets);
  });

  testWidgets('登录按钮空输入提示', (tester) async {
    await tester.pumpWidget(const MoneyFlyApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('登 录'));
    await tester.pump();
    expect(find.text('请输入账号和密码'), findsOneWidget);
  });

  testWidgets('注册页渲染与校验', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterPage()));
    await tester.pump();
    expect(find.text('注册账号'), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget);
    // 未填邮箱点发送 → 提示
    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    expect(find.text('请先输入正确的邮箱'), findsOneWidget);
  });

  testWidgets('设置页渲染', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));
    // 2.2.23 重新分组后：①组更名为「连接与内核」，首行是「默认模式」
    expect(find.text('连接与内核'), findsOneWidget);
    expect(find.text('默认模式'), findsOneWidget);
    // 「自动测速并选最优」已挪到②「测速」组（同类功能集中），需滚动到
    await tester.scrollUntilVisible(find.text('自动测速并选最优'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('测速'), findsOneWidget);
    expect(find.text('自动测速并选最优'), findsOneWidget);
  });
}
