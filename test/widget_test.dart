import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/main.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'moneyfly_lang': 'zh'}));
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('MBox 启动冒烟测试：应显示登录页', (WidgetTester tester) async {
    await tester.pumpWidget(const MoneyFlyApp());
    await tester.pump(const Duration(milliseconds: 300));

    // 未登录时进入登录页，应出现品牌与登录按钮
    expect(find.text('MBox'), findsOneWidget);
    expect(find.text('登 录'), findsOneWidget);
    expect(find.textContaining('注册', findRichText: true), findsWidgets);
    expect(find.textContaining('忘记密码', findRichText: true), findsWidgets);
  });
}
