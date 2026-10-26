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
import 'package:mbox/pages/devices/devices_page.dart';
import 'package:mbox/theme/app_theme.dart';

/// 设备管理页的删除入口必须**只由后台开关决定**（用户明确要求）：
///   开关关闭（allow_delete_device=false）→ 页面上只有「升级设备数量」，没有任何删除入口；
///   开关打开（allow_delete_device=true）→ 每台设备都可删除（移除/踢下线）。
///
/// 开关随 `/subscriptions/devices` 每次请求实时下发（不是前端缓存），
/// 所以这里直接按接口返回的两种取值渲染页面来验证。

Map<String, dynamic> _env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

Map<String, dynamic> _device(int id, String name) => {
      'id': id,
      'device_name': name,
      'device_type': 'desktop',
      'is_active': true,
      'last_access': '2026-10-15 10:00:00',
      'access_count': 3,
    };

Dio _mockDio({required bool allowDelete}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  dio.httpClientAdapter = adapter;
  adapter.onGet('/subscriptions/devices', (s) => s.reply(200, _env({
        'devices': [_device(1, 'MBox - Windows 11'), _device(2, 'Clash Verge - Windows')],
        'total': 2,
        'page': 1,
        'size': 20,
        'total_active': 2,
        'total_recent': 0,
        'total_offline': 0,
        'allow_delete_device': allowDelete,
      })));
  // 升级设备页/账号刷新可能触发的请求（返回空即可，不影响本用例断言）
  adapter.onGet('/user/subscribe', (s) => s.reply(200, _env({
        'subscribe_url': 'https://x/api/v1/client/subscribe?token=t',
        'expire_time': '2032-06-06 08:00:00',
        'device_limit': 5,
        'current_devices': 2,
        'remaining_days': 2000,
        'is_expired': false,
        'status': 'active',
      })));
  adapter.onGet('/users/dashboard-info', (s) => s.reply(200, _env({})));
  return dio;
}

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pump();
  await tester.pump();
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

  testWidgets('开关关闭：设备管理只有「升级设备数量」，不出现删除入口', (tester) async {
    ApiClient.debugDio = _mockDio(allowDelete: false);
    await _pump(tester, _wrap(const DevicesPage()));

    // 两台设备都渲染出来了（确认不是"没加载出来"造成的假阴性）
    expect(find.textContaining('MBox'), findsWidgets);

    // 关键：**操作入口**只能有「升级设备数量」，不能有任何删除按钮
    // （说明性文案里出现"不支持删除设备"是允许的：那是在解释原因）
    expect(find.byIcon(Icons.delete_outline), findsNothing,
        reason: '后台关闭删除后，不该渲染任何删除按钮');
    expect(find.byIcon(Icons.delete), findsNothing);
    expect(find.byIcon(Icons.add_circle_outline), findsWidgets,
        reason: '关闭删除后，删除入口要换成「升级设备数量」');
    expect(find.text('升级设备数量'), findsWidgets);
  });

  testWidgets('开关打开：每台设备都能删除（出现删除入口）', (tester) async {
    ApiClient.debugDio = _mockDio(allowDelete: true);
    await _pump(tester, _wrap(const DevicesPage()));

    expect(find.textContaining('MBox'), findsWidgets);
    expect(find.byIcon(Icons.delete_outline), findsWidgets,
        reason: '后台允许删除时，每台设备都要有删除按钮');
    expect(find.byIcon(Icons.add_circle_outline), findsNothing,
        reason: '开关打开时不该把删除入口替换成升级入口');
  });
}
