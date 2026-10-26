// 刚登录时的「正在同步订阅…」状态。
//
// 回归背景：登录后订阅还在拉取，连接按钮下方却挂着红色错误文案（上一会话
// 残留的 error / 或把「节点还没到」当成错误），用户以为软件出问题了。
// 同步是**过程**，应该显示进度，只有真的失败了才报错。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/subscription_service.dart';
import 'package:mbox/main.dart';
import 'package:mbox/pages/home/home_page.dart';
import 'package:mbox/theme/app_theme.dart';

Map<String, dynamic> env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

Dio mockDio(void Function(DioAdapter adapter) routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  dio.httpClientAdapter = adapter;
  routes(adapter);
  return dio;
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

Future<void> pumpPage(WidgetTester tester, Widget page) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pump();
  await tester.pump();
}

void main() {
  final subInfo = {
    'subscribe_url':
        'https://dy.moneyfly.top/api/v1/client/subscribe?token=t&type=clash',
    'expire_time': '2032-06-06 08:00:00',
    'device_limit': 600,
    'current_devices': 3,
    'remaining_days': 2104,
    'is_expired': false,
    'status': 'active',
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SubscriptionService.instance.syncing.value = false;
  });
  tearDown(() {
    SubscriptionService.instance.syncing.value = false;
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  test('同步开始 → 清掉残留错误；同步结束 → 状态复位', () {
    final conn = ConnectionController.instance;
    conn.error = '上一会话残留的错误';
    expect(conn.syncingSubscription, isFalse);

    SubscriptionService.instance.syncing.value = true;
    expect(conn.syncingSubscription, isTrue);
    expect(conn.error, isNull, reason: '同步一开始就不该再挂着旧错误');

    SubscriptionService.instance.syncing.value = false;
    expect(conn.syncingSubscription, isFalse);
    expect(conn.error, isNull, reason: '同步正常结束后不该凭空冒出错误');
  });

  test('订阅同步中调用 connect：不报「没有可用节点」，同步结束后才如实报错', () async {
    final conn = ConnectionController.instance;
    await conn.loadNodes(const []);
    SubscriptionService.instance.syncing.value = true;

    await conn.connect();
    expect(conn.error, isNull, reason: '同步期间"节点还没到"是过程，不是错误');

    SubscriptionService.instance.syncing.value = false;
    await conn.connect();
    expect(conn.error, isNotNull, reason: '同步确实结束了且没有节点，这才该报错');
    conn.error = null;
  });

  testWidgets('首页：订阅同步中显示「正在同步订阅…」，不显示错误文案', (tester) async {
    ApiClient.debugDio = mockDio((a) {
      a.onGet('/user/subscribe', (s) => s.reply(200, env(subInfo)));
    });
    final conn = ConnectionController.instance;
    await conn.loadNodes([
      ProxyNode(
          tag: '香港-01',
          type: 'vless',
          server: '1.2.3.4',
          port: 443,
          countryCode: 'HK',
          latencyMs: 35),
    ]);
    conn.current = conn.nodes.first;
    conn.error = '上一会话残留的错误';
    conn.notifyListeners();

    await pumpPage(tester, _wrap(const HomePage()));
    // 等页面自身的首次同步（账号+订阅）彻底结束，避免下面断言被它串扰
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pump();
    SubscriptionService.instance.syncing.value = false;
    await tester.pump();
    expect(SubscriptionService.instance.syncing.value, isFalse);

    // 同步开始
    SubscriptionService.instance.syncing.value = true;
    await tester.pump();

    expect(find.text('正在同步订阅…'), findsOneWidget);
    expect(find.text('上一会话残留的错误'), findsNothing,
        reason: '同步期间不该显示（残留的）错误');

    // 同步结束
    SubscriptionService.instance.syncing.value = false;
    await tester.pump();
    expect(SubscriptionService.instance.syncing.value, isFalse);
    expect(find.text('正在同步订阅…'), findsNothing);
  });

  testWidgets('首页：非同步状态下真实错误照常显示（不能把错误藏起来）', (tester) async {
    ApiClient.debugDio = mockDio((a) {
      a.onGet('/user/subscribe', (s) => s.reply(200, env(subInfo)));
    });
    final conn = ConnectionController.instance;
    await conn.loadNodes([
      ProxyNode(
          tag: '香港-01',
          type: 'vless',
          server: '1.2.3.4',
          port: 443,
          countryCode: 'HK',
          latencyMs: 35),
    ]);
    conn.current = conn.nodes.first;
    await pumpPage(tester, _wrap(const HomePage()));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pump();
    SubscriptionService.instance.syncing.value = false;
    await tester.pump();

    conn.error = '内核启动失败';
    conn.notifyListeners();
    await tester.pump();

    expect(find.text('内核启动失败'), findsOneWidget);
    expect(find.text('正在同步订阅…'), findsNothing);
    conn.error = null;
  });
}
