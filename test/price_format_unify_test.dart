// 金额显示口径统一（formatPrice）回归测试。
//
// 背景：lib/theme/app_theme.dart 里的 formatPrice() 专门解决「0.02 元套餐被
// toStringAsFixed(0) 显示成 0 元」和「多余尾零」两个问题；套餐页与支付弹窗用了它，
// 但「我的」页余额、升级设备页的金额仍在用 toStringAsFixed(2) —— 同一个金额
// 在两个页面显示成「¥200」和「¥200.00」，用户会以为不是同一个数。
//
// 契约：200 → 「200」（不是 200.00）；0.02 → 「0.02」（不是 0）；
//       200.5 → 「200.5」；同一金额在套餐页 / 我的页 / 升级设备页显示完全一致。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/payment_service.dart';
import 'package:moneyfly/core/services/user_service.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/package/package_page.dart';
import 'package:moneyfly/pages/package/upgrade_devices_page.dart';
import 'package:moneyfly/pages/profile/profile_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

Map<String, dynamic> _env(dynamic data) => {
      'success': true,
      'code': 0,
      'message': '',
      'data': data,
    };

Dio _dio(void Function(DioAdapter a) routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  dio.httpClientAdapter = adapter;
  routes(adapter);
  return dio;
}

/// 换 mock：必须先重置 ApiClient 单例（它缓存了构造时的 dio）
void _useDio(void Function(DioAdapter a) routes) {
  ApiClient.resetInstance();
  ApiClient.debugDio = _dio(routes);
}

/// 在真实异步区构建页面并等 mock 请求返回
/// 构建页面并等待异步数据落地。
///
/// 旧实现固定 `delayed(120ms)` 就断言 —— CI 上（尤其 macOS 真实内核那个 job）
/// 机器负载高时接口回调偶尔超过 120ms，页面还停在骨架态，断言就报
/// "Found 0 widgets with text containing ¥200"，属于时序型 flaky
/// （v2.2.28 构建时真实踩到一次，导致发布作业被跳过）。
/// 现在改成"最多等 3 秒，出现 [until] 就返回"，既稳又快。
Future<void> _pumpPage(WidgetTester tester, Widget page,
    {Finder? until, Duration timeout = const Duration(seconds: 3)}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(_wrap(page));
    final deadline = DateTime.now().add(timeout);
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (until == null || until.evaluate().isNotEmpty) break;
      if (DateTime.now().isAfter(deadline)) break;
    }
  });
  await tester.pump();
  await tester.pump();
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildMoneyFlyTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SessionState()..setLoggedIn(true)),
          ChangeNotifierProvider.value(value: ConnectionController.instance),
          ChangeNotifierProvider.value(value: AccountService.instance),
        ],
        child: child,
      ),
    );

Map<String, dynamic> _planJson({required int id, required double price}) => {
      'id': id,
      'name': '套餐$id',
      'price': price,
      'duration_days': 30,
      'device_limit': 3,
      'is_recommended': false,
    };

Map<String, dynamic> _dashboardJson({required double balance}) => {
      'username': 'tester',
      'email': 'tester@test.com',
      'balance': balance,
      'membership': '月付会员',
      'online_devices': 1,
      'total_devices': 3,
      'subscription_status': 'active',
      'expire_time': '2032-06-06 08:00:00',
      'remaining_days': 300,
      'has_special_nodes': false,
      'is_active': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 测试环境没有 path_provider 平台实现 → loadCachedDashboard() 走 catch 分支
    // 返回 null（不会有磁盘缓存干扰断言），无需注入 debugSupportDir。
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    UserService.instance.invalidateCache();
  });

  group('formatPrice 本身的口径', () {
    test('整数金额不显示尾零；小额不被凑整成 0；一位小数保留', () {
      expect(formatPrice(200), '200');
      expect(formatPrice(0.02), '0.02');
      expect(formatPrice(0), '0');
      expect(formatPrice(200.5), '200.5');
      expect(formatPrice(19.90), '19.9');
    });
  });

  testWidgets('同一金额 200：套餐页价格 与 我的页余额 显示完全一致', (tester) async {
    // 套餐页：plan.price = 200
    _useDio((a) {
      a.onGet('/packages',
          (s) => s.reply(200, _env([_planJson(id: 1, price: 200)])));
      a.onGet('/payment/methods', (s) => s.reply(200, _env([])));
    });
    await _pumpPage(tester, const PackagePage(),
        until: find.textContaining('¥200', findRichText: true));
    expect(find.textContaining('¥200', findRichText: true), findsWidgets,
        reason: '套餐页应显示 ¥200');
    expect(find.textContaining('200.00', findRichText: true), findsNothing,
        reason: '套餐页不该出现 200.00');

    // 我的页：balance = 200
    _useDio((a) {
      a.onGet('/users/dashboard-info',
          (s) => s.reply(200, _env(_dashboardJson(balance: 200))));
    });
    await _pumpPage(tester, const ProfilePage(), until: find.text('¥200'));
    expect(find.text('¥200'), findsOneWidget,
        reason: '我的页余额必须与套餐页同口径：¥200（旧实现是 ¥200.00）');
    expect(find.textContaining('200.00', findRichText: true), findsNothing,
        reason: '我的页余额写死 toStringAsFixed(2) → 同金额两处显示不一致');
  });

  testWidgets('小额 0.02：我的页余额不显示成 ¥0.00 / ¥0', (tester) async {
    _useDio((a) {
      a.onGet('/users/dashboard-info',
          (s) => s.reply(200, _env(_dashboardJson(balance: 0.02))));
    });
    await _pumpPage(tester, const ProfilePage());
    expect(find.text('¥0.02'), findsOneWidget);
    expect(find.text('¥0'), findsNothing, reason: '0.02 被凑整显示成 0 = 用户以为余额为 0');
  });

  testWidgets('升级设备页：折扣价/原价/按钮金额都用同一口径（200 不带 .00）', (tester) async {
    _useDio((a) {
      a.onGet('/payment/methods', (s) => s.reply(200, _env([
            {'id': 1, 'pay_type': 'alipay', 'name': '支付宝', 'sort_order': 1},
          ])));
      a.onPost('/orders/upgrade-devices',
          (s) => s.reply(200, _env({'amount': 240.0, 'final_amount': 200.0})),
          data: Matchers.any);
    });
    await _pumpPage(tester, const UpgradeDevicesPage());

    expect(find.textContaining('¥200', findRichText: true), findsWidgets,
        reason: '实付金额应为 ¥200');
    expect(find.textContaining('¥240', findRichText: true), findsOneWidget,
        reason: '划线原价应为 ¥240');
    expect(find.textContaining('200.00', findRichText: true), findsNothing,
        reason: '升级设备页写死 toStringAsFixed(2) → 与套餐页口径不一致');
    expect(find.textContaining('240.00', findRichText: true), findsNothing);

    // 与套餐页同口径的交叉验证：同一个 200 在两页渲染出的字符串完全相同
    expect(find.text('立即支付 ¥200'), findsOneWidget);
  });

  testWidgets('升级设备页：0.02 元预览价不显示成 ¥0.00', (tester) async {
    _useDio((a) {
      a.onGet('/payment/methods', (s) => s.reply(200, _env([
            {'id': 1, 'pay_type': 'alipay', 'name': '支付宝', 'sort_order': 1},
          ])));
      a.onPost('/orders/upgrade-devices',
          (s) => s.reply(200, _env({'amount': 0.02, 'final_amount': 0.02})),
          data: Matchers.any);
    });
    await _pumpPage(tester, const UpgradeDevicesPage());
    expect(find.textContaining('¥0.02', findRichText: true), findsWidgets);
    expect(find.textContaining('¥0.00', findRichText: true), findsNothing);
  });

  test('套餐页与升级设备页共用的 formatPrice 与 PaymentService 注入的目录价格一致', () {
    // 目录缓存注入不改变价格口径（上游数据源不同、显示层必须统一）
    PaymentService.instance.adoptCatalog(
      [Plan(id: 9, name: 'p', price: 200, durationDays: 30, deviceLimit: 3, isRecommended: false)],
      const [],
    );
    expect(formatPrice(200), '200');
  });
}
