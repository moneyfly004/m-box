import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/subscription_service.dart';
import 'package:mbox/main.dart';
import 'package:mbox/pages/profile/profile_page.dart';
import 'package:mbox/theme/app_theme.dart';

/// 「首页」与「我的」设备数字必须同源。
///
/// 用户实测反馈：客户 tracycheung0722@outlook.com 首页显示 7 台、「我的」显示 6 台。
/// 根因是两页读**不同接口**：首页读 /user/subscribe（AccountService），
/// 「我的」读 /users/dashboard-info（UserService），两个接口刷新时机不同，
/// 设备增删后同一个客户就会看到差 1 的两个数字。
///
/// 现在的口径：「我的」页设备数字取 AccountService 的订阅信息（与首页同一来源），
/// 并在进入本页时一并强刷。dashboard 只在订阅信息尚未就绪时兜底。

Map<String, dynamic> _env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

Dio _mockDio(void Function(DioAdapter adapter) routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  dio.httpClientAdapter = adapter;
  routes(adapter);
  return dio;
}

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pump();
  await tester.pump();
}

/// 等到某个文本出现（最多 5s）。
///
/// 为什么需要：页面是「挂载 → 异步强刷两个接口 → 重建」，固定 150ms 在高负载
/// runner 上不够（CI 上两个测试组并行跑时实测偶发拿不到 `7/8`，本地必过）。
/// 改成「轮询直到出现」，与机器快慢无关。
Future<bool> _pumpUntil(WidgetTester tester, Finder finder,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }
  return finder.evaluate().isNotEmpty;
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildMBoxTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SessionState()..setLoggedIn(true)),
          ChangeNotifierProvider.value(value: ConnectionController.instance),
          ChangeNotifierProvider.value(value: AccountService.instance),
        ],
        child: child,
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('我的页设备数字取订阅信息（与首页同源），dashboard 旧数据不覆盖',
      (tester) async {
    ApiClient.debugDio = _mockDio((a) {
      // 首页用的订阅信息：已用 7 / 上限 8
      a.onGet('/user/subscribe', (s) => s.reply(200, _env({
            'subscribe_url': 'https://x/api/v1/client/subscribe?token=t',
            'expire_time': '2032-06-06 08:00:00',
            'device_limit': 8,
            'current_devices': 7,
            'remaining_days': 2104,
            'is_expired': false,
            'status': 'active',
          })));
      // dashboard 里还是旧的 6 / 8（模拟刷新时机不同造成的滞后）
      a.onGet('/users/dashboard-info', (s) => s.reply(200, _env({
            'username': 'tracy',
            'email': 'tracycheung0722@outlook.com',
            'balance': '0.00',
            'membership': 'VIP',
            'online_devices': 6,
            'total_devices': 8,
            'expire_time': '2032-06-06 08:00:00',
            'remaining_days': 2104,
            'has_subscription': true,
          })));
    });
    // 注意：不要在这里直接 await 网络请求 —— flutter_test 的测试体不在真实
    // 异步区，网络调用会永久挂住。页面自身在 _load 里就会强刷两个接口，
    // 由 _pump 的 runAsync 真实异步区完成。
    await _pump(tester, _wrap(const ProfilePage()));
    final appeared = await _pumpUntil(tester, find.text('7/8'));
    expect(appeared, isTrue, reason: '我的页必须与首页显示同一组数字 7/8');
    expect(find.text('6/8'), findsNothing,
        reason: 'dashboard 的滞后数字不得展示（否则首页 7、我的 6）');
  });
}
