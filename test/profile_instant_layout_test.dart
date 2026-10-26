// 「我的」页：布局必须固定、立即上屏，不能等数据。
//
// 用户实测反馈：
//   「每次点击我的都要等待一下才出来，刷新才出来；它不应该是固定的吗？
//     唯一变化的是上边到期时间、设备数量、账号信息，剩下的卡片应该是固定的。」
//
// 旧实现把**整页内容**（含设置/订单/客服/退出登录）挂在「数据是否就绪」上：
//   _loading && 无缓存 → 整块大转圈；失败 → 整块错误占位。
// 于是每次进页面都要等一次网络，固定项也跟着消失。
//
// 现在的契约（本文件守的就是这四条）：
//   1) 无数据时**固定项立即可见**（设置/订单/设备/通知/检查更新/退出登录）；
//   2) 无数据时数值显示「—」（不是全 0，误导用户以为没套餐）；
//   3) 加载失败：给内联提示 + 重试，但页面结构与固定项**不动**；
//   4) 切回本页在 TTL 内不重复请求（响应缓存，不是每次进都刷新）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/settings_store.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/core/services/user_service.dart';
import 'package:moneyfly/l10n/app_strings.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/profile/profile_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

Map<String, dynamic> _env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

Dio _mockDio(void Function(DioAdapter adapter) routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  dio.httpClientAdapter = adapter;
  routes(adapter);
  return dio;
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

Future<void> _pump(WidgetTester tester, Widget page,
    {int ms = 150}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(Duration(milliseconds: ms));
  });
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsStore.resetForTest();
    await AppStrings.setLang('zh', persist: false);
    // 每个用例从"没有任何缓存"开始
    UserService.instance.invalidateCache();
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
    UserService.instance.invalidateCache();
  });

  testWidgets('无数据且接口还挂着：固定项立即渲染、数值显示「—」', (tester) async {
    // 两个接口都缓慢响应（3s），模拟"网络慢"：旧实现这里只能转圈
    ApiClient.debugDio = _mockDio((a) {
      a.onGet('/user/subscribe',
          (s) => s.reply(200, _env({'device_limit': 0}), delay: const Duration(seconds: 3)));
      a.onGet('/users/dashboard-info',
          (s) => s.reply(200, _env({}), delay: const Duration(seconds: 3)));
    });

    await _pump(tester, _wrap(const ProfilePage()), ms: 200);

    // 1) 固定项必须立刻在（用户要的"位置固定、马上出现"）
    expect(find.text(AppStrings.t('settings')), findsOneWidget,
        reason: '设置入口必须立即可见（不能被 loading 挡住）');
    expect(find.text(AppStrings.t('profile_orders')), findsOneWidget);
    expect(find.text(AppStrings.t('profile_devices')), findsOneWidget);
    expect(find.text(AppStrings.t('profile_notifications')), findsOneWidget);
    expect(find.text(AppStrings.t('settings_check_update')), findsOneWidget);
    expect(find.text(AppStrings.t('logout')), findsWidgets,
        reason: '退出登录是固定项');

    // 2) 没有数据时不能把 0 当真值展示（会被误解为"没套餐/0 天"）
    expect(find.text('0'), findsNothing, reason: '数值未知时应显示「—」而不是 0');
    expect(find.text('—'), findsWidgets);
  });

  testWidgets('加载失败：内联提示 + 重试，固定项仍可用（不整页替换）', (tester) async {
    // 不注册任何路由 → 请求失败
    ApiClient.debugDio = _mockDio((a) {});

    await _pump(tester, _wrap(const ProfilePage()), ms: 400);

    expect(find.text(AppStrings.t('profile_load_fail')), findsWidgets,
        reason: '失败要有明确提示');
    expect(find.text(AppStrings.t('retry')), findsWidgets, reason: '要有重试入口');
    // 关键：失败也不影响固定项
    expect(find.text(AppStrings.t('settings')), findsOneWidget,
        reason: '数据失败时设置入口仍必须可点（旧实现整块被错误占位替换）');
    expect(find.text(AppStrings.t('profile_orders')), findsOneWidget);
  });

  testWidgets('有缓存时立即显示真实数字（不再显示占位）', (tester) async {
    ApiClient.debugDio = _mockDio((a) {
      a.onGet('/user/subscribe', (s) => s.reply(200, _env({
            'subscribe_url': 'https://x/api/v1/client/subscribe?token=t',
            'expire_time': '2032-06-06 08:00:00',
            'device_limit': 8,
            'current_devices': 7,
            'remaining_days': 2104,
            'is_expired': false,
            'status': 'active',
          })));
      a.onGet('/users/dashboard-info', (s) => s.reply(200, _env({
            'username': 'tracy',
            'email': 't@x.com',
            'balance': '0.00',
            'membership': 'VIP',
            'online_devices': 7,
            'total_devices': 8,
            'expire_time': '2032-06-06 08:00:00',
            'remaining_days': 2104,
            'has_subscription': true,
          })));
    });

    await _pump(tester, _wrap(const ProfilePage()), ms: 400);

    expect(find.text('7/8'), findsWidgets, reason: '设备数字应已上屏');
    expect(find.text('2104'), findsWidgets, reason: '剩余天数应已上屏');
    expect(find.text('tracy'), findsWidgets);
  });

  testWidgets('切回本页在 TTL 内不重复请求（缓存优先，不"每次都要刷新"）', (tester) async {
    var dashboardHits = 0;
    var subscribeHits = 0;
    ApiClient.debugDio = _mockDio((a) {
      a.onGet('/user/subscribe', (s) {
        subscribeHits++;
        return s.reply(200, _env({
          'subscribe_url': 'https://x/api/v1/client/subscribe?token=t',
          'expire_time': '2032-06-06 08:00:00',
          'device_limit': 8,
          'current_devices': 7,
          'remaining_days': 2104,
          'is_expired': false,
          'status': 'active',
        }));
      });
      a.onGet('/users/dashboard-info', (s) {
        dashboardHits++;
        return s.reply(200, _env({
          'username': 'tracy',
          'online_devices': 7,
          'total_devices': 8,
          'has_subscription': true,
        }));
      });
    });

    await _pump(tester, _wrap(const ProfilePage()), ms: 400);
    final firstDashboard = dashboardHits;
    final firstSubscribe = subscribeHits;
    expect(firstDashboard, greaterThan(0), reason: '首次进入应有一次真实拉取');

    // 模拟"切走再切回「我的」"多次（TTL 内）
    for (var i = 0; i < 3; i++) {
      mainTabIndex.value = 0;
      await tester.pump();
      mainTabIndex.value = 3;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
    }

    expect(dashboardHits, firstDashboard,
        reason: 'TTL 内切回不应再请求 dashboard（否则就是"每次都要等刷新"）');
    expect(subscribeHits, firstSubscribe,
        reason: 'TTL 内切回不应再请求订阅信息');
    // 数字仍然在（缓存上屏）
    expect(find.text('7/8'), findsWidgets);
  });
}
