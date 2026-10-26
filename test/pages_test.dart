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
import 'package:mbox/pages/devices/devices_page.dart';
import 'package:mbox/pages/home/home_page.dart';
import 'package:mbox/pages/notifications/notifications_page.dart';
import 'package:mbox/pages/orders/orders_page.dart';
import 'package:mbox/theme/app_theme.dart';

/// 信封包装（与后端一致）
Map<String, dynamic> env(dynamic data) => {
      'success': true,
      'code': 0,
      'message': '',
      'data': data,
    };

Dio mockDio(void Function(DioAdapter adapter) routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  dio.httpClientAdapter = adapter;
  routes(adapter);
  return dio;
}

/// 在真实异步区构建页面并等待 mock 请求完成
Future<void> pumpPage(WidgetTester tester, Widget page) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pump();
  await tester.pump();
}

/// 点击后等待异步刷新完成（tap 在真实异步区内执行）
Future<void> tapSettle(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pumpAndSettle();
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  group('首页', () {
    Map<String, dynamic> stubSubInfo() => {
          'subscribe_url':
              'https://dy.moneyfly.top/api/v1/client/subscribe?token=t&type=clash',
          'expire_time': '2032-06-06 08:00:00',
          'device_limit': 600,
          'current_devices': 3,
          'remaining_days': 2104,
          'is_expired': false,
          'status': 'active',
        };

    testWidgets('渲染连接卡/模式/速率统计', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/user/subscribe', (s) => s.reply(200, stubSubInfo()));
      });
      final conn = ConnectionController.instance;
      await conn.loadNodes([
        ProxyNode(tag: '香港-01', type: 'vless', server: '1.2.3.4', port: 443, countryCode: 'HK', latencyMs: 35),
        ProxyNode(tag: '日本东京', type: 'trojan', server: '5.6.7.8', port: 443, countryCode: 'JP', latencyMs: 88),
      ]);
      conn.current = conn.nodes.first;
      await pumpPage(tester, _wrap(const HomePage()));
      expect(find.text('智能模式'), findsOneWidget);
      expect(find.text('全局模式'), findsOneWidget);
      expect(find.text('上行'), findsOneWidget);
      expect(find.text('下行'), findsOneWidget);
      expect(find.text('香港-01'), findsOneWidget);
      // #3 订阅信息条
      expect(find.text('2104 天'), findsOneWidget);
    });

    testWidgets('模式切换点击生效', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/user/subscribe', (s) => s.reply(200, stubSubInfo()));
      });
      await pumpPage(tester, _wrap(const HomePage()));
      await tapSettle(tester, find.text('全局模式'));
      expect(ConnectionController.instance.smartMode, isFalse);
      await tapSettle(tester, find.text('智能模式'));
      expect(ConnectionController.instance.smartMode, isTrue);
    });
  });

  group('首页·受限状态（到期/设备满/正常）', () {
    Future<void> pumpHome(WidgetTester tester, Map<String, dynamic> sub,
        {List<ProxyNode>? nodes}) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/user/subscribe', (s) => s.reply(200, sub));
      });
      final conn = ConnectionController.instance;
      await conn.loadNodes(nodes ?? []);
      await pumpPage(tester, _wrap(const HomePage()));
    }

    testWidgets('套餐到期 → 顶部横幅引导去续费，且显示「已到期」', (tester) async {
      await pumpHome(tester, {
        'subscribe_url':
            'https://dy.moneyfly.top/api/v1/client/subscribe?token=t&type=clash',
        'expire_time': '2020-01-01T08:00:00',
        'device_limit': 3,
        'current_devices': 3,
        'remaining_days': 0,
        'is_expired': true,
        'status': 'active',
      });
      // 信息条到期格显示「已到期」；横幅给出续费引导（到期才出现续费按钮）
      expect(find.text('已到期'), findsOneWidget);
      expect(find.textContaining('您的套餐已到期'), findsOneWidget);
      expect(find.text('去续费'), findsOneWidget);
      expect(find.text('去开通'), findsNothing);
    });

    testWidgets('设备数已达上限 → 横幅提示上限并引导管理设备/升级', (tester) async {
      await pumpHome(tester, {
        'subscribe_url':
            'https://dy.moneyfly.top/api/v1/client/subscribe?token=t&type=clash',
        'expire_time': '2032-06-06 08:00:00',
        'device_limit': 3,
        'current_devices': 3,
        'remaining_days': 2104,
        'is_expired': false,
        'status': 'active',
      });
      expect(find.textContaining('设备数量已达上限'), findsOneWidget);
      expect(find.text('管理设备'), findsOneWidget);
      // 未到期不出现「去续费」
      expect(find.text('去续费'), findsNothing);
    });

    testWidgets('正常账号但节点为空 → 提示重试而非「去开通」', (tester) async {
      await pumpHome(tester, {
        'subscribe_url':
            'https://dy.moneyfly.top/api/v1/client/subscribe?token=t&type=clash',
        'expire_time': '2032-06-06 08:00:00',
        'device_limit': 3,
        'current_devices': 1,
        'remaining_days': 2104,
        'is_expired': false,
        'status': 'active',
      });
      // 正常状态不弹任何购买引导
      expect(find.text('去开通'), findsNothing);
      expect(find.text('去续费'), findsNothing);
      // 空节点给重试提示而非购买按钮
      expect(find.textContaining('节点加载失败'), findsOneWidget);
    });
  });

  group('首页·类型化连接失败引导', () {
    Map<String, dynamic> sub() => {
          'subscribe_url':
              'https://dy.moneyfly.top/api/v1/client/subscribe?token=t&type=clash',
          'expire_time': '2032-06-06 08:00:00',
          'device_limit': 600,
          'current_devices': 3,
          'remaining_days': 2104,
          'is_expired': false,
          'status': 'active',
        };

    Future<void> pumpError(
        WidgetTester tester, ConnErrorKind kind, String msg) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/user/subscribe', (s) => s.reply(200, sub()));
      });
      final conn = ConnectionController.instance;
      addTearDown(() {
        conn.status = ConnStatus.disconnected;
        conn.error = null;
        conn.errorKind = ConnErrorKind.none;
      });
      conn.status = ConnStatus.error;
      conn.error = msg;
      conn.errorKind = kind;
      // 预置节点：避免「节点为空」区域额外渲染一个「重试」，干扰错误区断言
      await conn.loadNodes([
        ProxyNode(
            tag: '香港-01', type: 'vless', server: '1.2.3.4', port: 443,
            countryCode: 'HK', latencyMs: 35),
      ]);
      await pumpPage(tester, _wrap(const HomePage()));
    }

    testWidgets('缺 VPN 权限 → 显示「授权 VPN 权限」而非通用「重试」', (tester) async {
      await pumpError(tester, ConnErrorKind.noVpnPermission, '需要授予 VPN 权限才能连接');
      expect(find.text('授权 VPN 权限'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('后台启动受限 → 提示保持前台 + 重试按钮', (tester) async {
      await pumpError(tester, ConnErrorKind.backgroundStartBlocked, '后台启动受限');
      expect(find.text('请保持 App 在前台，再点重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('授权 VPN 权限'), findsNothing);
    });

    testWidgets('未知错误 → 通用重试按钮', (tester) async {
      await pumpError(tester, ConnErrorKind.unknown, '内核启动超时');
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('授权 VPN 权限'), findsNothing);
    });
  });

  group('设备管理', () {
    testWidgets('空状态', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/subscriptions/devices', (s) => s.reply(200, env({'devices': []})));
      });
      await pumpPage(tester, _wrap(const DevicesPage()));
      expect(find.text('暂无设备'), findsOneWidget);
    });

    testWidgets('列表渲染 + 删除确认弹窗', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        // allow_delete_device=true：模拟后台「允许用户删除设备」——
        // 只有此时设备卡片才渲染删除按钮（开关关闭时换成「升级设备数量」入口）
        a.onGet('/subscriptions/devices', (s) => s.reply(200, env({'devices': [
          {
            'id': 11, 'device_name': 'iPhone 15', 'os_name': 'iOS', 'os_version': '18.0',
            'ip_address': '1.2.3.4', 'location': '广东', 'is_active': true,
            'access_count': 5, 'remark': '我的手机', 'last_seen': '2026-09-01 12:00:00',
            'device_type': 'phone', 'device_model': '', 'device_brand': 'Apple',
            'software_name': 'MBox', 'software_version': '1.0.0', 'is_allowed': true,
            'first_seen': '', 'last_access': '', 'created_at': '', 'subscription_id': 1,
          },
        ], 'allow_delete_device': true})));
        a.onDelete('/devices/11', (s) => s.reply(200, env(null)));
      });
      await pumpPage(tester, _wrap(const DevicesPage()));
      expect(find.text('我的手机'), findsOneWidget); // 备注优先显示
      expect(find.text('在线'), findsOneWidget);
      // 点删除 → 确认弹窗
      await tester.tap(find.text('删除'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 弹窗文案使用设备名（displayName，多行内容用 textContaining）
      expect(find.textContaining('确定删除「iPhone 15」吗？'), findsOneWidget);
      // 点取消 → 弹窗关闭
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确定删除「iPhone 15」吗？'), findsNothing);
    });
  });

  group('订单', () {
    testWidgets('列表渲染状态徽标', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/orders', (s) => s.reply(200, env([
          {
            'id': 9, 'order_no': 'MF202609011234', 'amount': 49.9, 'final_amount': 44.9,
            'status': 'paid', 'type': 'order', 'package': {'name': '季付套餐'},
            'payment_method_name': '支付宝', 'created_at': '2026-09-01 12:00:00',
          },
          {
            'id': 10, 'order_no': 'MF202609011235', 'amount': 19.9, 'final_amount': 19.9,
            'status': 'pending', 'type': 'order', 'package': {'name': '月付套餐'},
            'created_at': '2026-09-01 12:05:00',
          },
        ])));
      });
      await pumpPage(tester, _wrap(const OrdersPage()));
      expect(find.text('季付套餐'), findsOneWidget);
      expect(find.text('已支付'), findsOneWidget);
      expect(find.text('待支付'), findsOneWidget);
      expect(find.text('继续支付'), findsOneWidget);
      expect(find.text('取消订单'), findsOneWidget);
    });

    testWidgets('取消订单二次确认', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/orders', (s) => s.reply(200, env([
          {
            'id': 10, 'order_no': 'MF202609011235', 'amount': 19.9, 'final_amount': 19.9,
            'status': 'pending', 'type': 'order', 'package': {'name': '月付套餐'},
            'created_at': '2026-09-01 12:05:00',
          },
        ])));
        a.onPost('/orders/MF202609011235/cancel', (s) => s.reply(200, env(null)));
      });
      await pumpPage(tester, _wrap(const OrdersPage()));
      await tester.tap(find.text('取消订单'));
      await tester.pump();
      expect(find.text('确定取消这笔待支付订单吗？'), findsOneWidget);
      await tester.tap(find.text('再想想'));
      await tester.pump();
      expect(find.text('确定取消这笔待支付订单吗？'), findsNothing);
    });
  });

  group('通知', () {
    testWidgets('列表 + 全部已读', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/notifications', (s) => s.reply(200, env([
          {'id': 1, 'title': '套餐即将到期', 'content': '您的套餐还剩 3 天到期，请及时续费。', 'type': 'system', 'is_read': false, 'created_at': '2026-09-01 10:00:00'},
          {'id': 2, 'title': '新公告', 'content': '欢迎使用 MBox。', 'type': 'announcement', 'is_read': true, 'created_at': '2026-09-01 09:00:00'},
        ])));
        a.onPut('/notifications/read-all', (s) => s.reply(200, env(null)));
      });
      await pumpPage(tester, _wrap(const NotificationsPage()));
      expect(find.text('套餐即将到期'), findsOneWidget);
      expect(find.text('新公告'), findsOneWidget);
      expect(find.text('全部已读'), findsOneWidget);
      // 点击「全部已读」→ 应显示成功反馈（证明 PUT 调用链完成）
      await tester.runAsync(() async {
        await tester.tap(find.text('全部已读'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(find.text('已全部标记为已读'), findsOneWidget);
    });
  });
}
