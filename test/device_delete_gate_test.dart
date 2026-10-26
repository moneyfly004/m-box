// 后台开关「允许用户删除设备」→ 客户端行为（新增测试，纯新增文件）。
//
// 需求（2026-10 用户提出）：后台可以决定客户是否能删除设备。
//   * 开关关闭 → 客户端**不显示**删除按钮，改为「升级设备数量」入口 + 原因说明；
//   * 开关开启 → 正常显示删除按钮（保留二次确认与列表刷新）。
//
// 覆盖四件事：
//   1) 解析层 parseAllowDeleteDevice：true/false/字段缺失/类型异常/无订阅(空数组)
//      —— 字段缺失必须落到**安全默认 false**（旧后端上不能误显示删除按钮）；
//   2) DeviceService.listWithPolicy：一次请求同时拿到列表与开关；
//   3) 组件层两种开关状态的渲染分支（用 Icons 定位卡片内按钮，避免与顶部
//      升级卡片同文案的干扰）；
//   4) 开关中途被后台关掉：DELETE 403 → 提示后台原文并自动重拉列表，
//      删除入口当场换成升级入口。

import 'dart:convert';
import 'dart:typed_data';

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
import 'package:mbox/core/services/device_service.dart';
import 'package:mbox/core/services/subscription_service.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/main.dart';
import 'package:mbox/pages/devices/devices_page.dart';
import 'package:mbox/pages/package/upgrade_devices_page.dart';
import 'package:mbox/theme/app_theme.dart';

/// 后端信封（与 ApiClient._unwrap 的契约一致）
Map<String, dynamic> _env(dynamic data) => {
      'success': true,
      'code': 0,
      'message': '',
      'data': data,
    };

Dio _mockDio(void Function(DioAdapter a) routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  dio.httpClientAdapter = adapter;
  routes(adapter);
  return dio;
}

/// 逐请求计算的假后端：`DioAdapter` 的 reply 在注册时就固定了，
/// 无法模拟「同一个 GET 第二次返回不同开关值」，所以这个用例用裸适配器。
class _RecAdapter implements HttpClientAdapter {
  _RecAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions o) handler;
  final List<String> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    calls.add('${options.method} ${options.uri.path}');
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? body, [int code = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      code,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );

/// 一台设备的完整字段（与后端 formatDeviceList 输出一致）
Map<String, dynamic> _deviceJson({int id = 11, String name = '我的手机'}) => {
      'id': id,
      'device_name': name,
      'os_name': 'iOS',
      'os_version': '18.0',
      'ip_address': '1.2.3.4',
      'location': '广东',
      'is_active': true,
      'access_count': 5,
      'remark': '',
      'last_seen': '2026-09-01 12:00:00',
      'device_type': 'phone',
      'device_model': '',
      'device_brand': 'Apple',
      'software_name': 'MBox',
      'software_version': '1.0.0',
      'is_allowed': true,
      'first_seen': '',
      'last_access': '',
      'created_at': '',
      'subscription_id': 1,
    };

/// 设备列表响应：allowDelete == null 时不带 allow_delete_device 字段
/// （模拟旧后端 / XBoard 兼容返回）
Map<String, dynamic> _listBody(List<Map<String, dynamic>> devices,
        {bool? allowDelete}) =>
    {
      'devices': devices,
      'total': devices.length,
      'page': 1,
      'size': 100,
      'allow_delete_device': ?allowDelete,
    };

Future<void> _pumpDevices(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      theme: buildMBoxTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SessionState()..setLoggedIn(true)),
          ChangeNotifierProvider.value(value: ConnectionController.instance),
          ChangeNotifierProvider.value(value: AccountService.instance),
        ],
        child: const DevicesPage(),
      ),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pump();
  await tester.pump();
}

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

  group('allow_delete_device 解析（安全默认不可删除）', () {
    test('true → 允许删除', () {
      expect(parseAllowDeleteDevice({'allow_delete_device': true}), isTrue);
    });

    test('false → 不允许删除', () {
      expect(parseAllowDeleteDevice({'allow_delete_device': false}), isFalse);
    });

    test('字段缺失（旧后端）→ 安全默认 false', () {
      expect(parseAllowDeleteDevice({'devices': [], 'total': 0}), isFalse);
    });

    test('无订阅时后端返回空数组 → 安全默认 false', () {
      expect(parseAllowDeleteDevice(<dynamic>[]), isFalse);
      expect(parseAllowDeleteDevice(null), isFalse);
    });

    test('类型异常不抛异常 → 安全默认 false', () {
      expect(parseAllowDeleteDevice({'allow_delete_device': 'yes'}), isFalse);
      expect(parseAllowDeleteDevice({'allow_delete_device': <String>[]}), isFalse);
      // 兼容型后端用 0/1 或 "true"/"false" 字符串时也能正确解析
      expect(parseAllowDeleteDevice({'allow_delete_device': 1}), isTrue);
      expect(parseAllowDeleteDevice({'allow_delete_device': 0}), isFalse);
      expect(parseAllowDeleteDevice({'allow_delete_device': 'true'}), isTrue);
      expect(parseAllowDeleteDevice({'allow_delete_device': 'False'}), isFalse);
    });

    test('DeviceListResult.empty 是安全默认', () {
      expect(DeviceListResult.empty.allowDelete, isFalse);
      expect(DeviceListResult.empty.devices, isEmpty);
    });
  });

  group('DeviceService.listWithPolicy：列表与开关一次取回', () {
    test('后端下发 false → 列表照常返回、开关为 false', () async {
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/subscriptions/devices',
            (s) => s.reply(200, _env(_listBody([_deviceJson()], allowDelete: false))));
      });
      final r = await DeviceService.instance.listWithPolicy();
      expect(r.devices, hasLength(1));
      expect(r.devices.first.displayName, '我的手机');
      expect(r.allowDelete, isFalse);
      // list() 便捷入口语义等价
      expect(await DeviceService.instance.list(), hasLength(1));
    });

    test('后端下发 true → 开关为 true', () async {
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/subscriptions/devices',
            (s) => s.reply(200, _env(_listBody([_deviceJson()], allowDelete: true))));
      });
      final r = await DeviceService.instance.listWithPolicy();
      expect(r.allowDelete, isTrue);
    });

    test('字段缺失（旧后端）→ 开关为 false，列表仍可用', () async {
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/subscriptions/devices',
            (s) => s.reply(200, _env(_listBody([_deviceJson()]))));
      });
      final r = await DeviceService.instance.listWithPolicy();
      expect(r.devices, hasLength(1));
      expect(r.allowDelete, isFalse);
    });

    test('无订阅（后端返回空数组）→ 空列表 + 安全默认', () async {
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/subscriptions/devices', (s) => s.reply(200, _env(<dynamic>[])));
      });
      final r = await DeviceService.instance.listWithPolicy();
      expect(r.devices, isEmpty);
      expect(r.allowDelete, isFalse);
    });
  });

  group('设备页：开关决定「删除」还是「升级设备数量」', () {
    testWidgets('开关关闭 → 无删除按钮 + 升级入口 + 原因说明', (tester) async {
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/subscriptions/devices',
            (s) => s.reply(200, _env(_listBody([_deviceJson()], allowDelete: false))));
      });
      await _pumpDevices(tester);

      // 设备正常渲染
      expect(find.text('我的手机'), findsOneWidget);
      // 删除入口整体不渲染（不是置灰）
      expect(find.byIcon(Icons.delete_outline), findsNothing,
          reason: '后台关闭删除后设备卡片不得出现删除按钮');
      expect(find.text('删除'), findsNothing);
      // 改为升级设备数量入口
      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget,
          reason: '关闭删除后应显示「升级设备数量」入口');
      expect(find.text(AppStrings.t('upgrade_devices_btn')), findsWidgets);
      // 原因说明：不能只删按钮不解释
      expect(find.text(AppStrings.t('device_delete_disabled_notice')), findsOneWidget);
      // 新入口本身要可用：InkWell 按压反馈 + 命中区 ≥40（与既有操作按钮同规格）
      final hit = find.ancestor(
          of: find.byIcon(Icons.add_circle_outline), matching: find.byType(InkWell));
      expect(hit, findsWidgets, reason: '升级入口没有 InkWell（无按压反馈）');
      expect(tester.getRect(hit.first).height, greaterThanOrEqualTo(40),
          reason: '升级入口命中区不足 40px');
      // 超长元信息（IPv6 + 长地址）下也不能溢出
      expect(tester.takeException(), isNull);
    });

    testWidgets('开关关闭 → 点升级入口进入升级设备页', (tester) async {
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/subscriptions/devices',
            (s) => s.reply(200, _env(_listBody([_deviceJson()], allowDelete: false))));
        a.onGet('/payment/methods', (s) => s.reply(200, _env(<dynamic>[])));
        a.onPost('/orders/upgrade-devices',
            (s) => s.reply(200, _env({'final_amount': 40.0, 'original_amount': 40.0})));
      });
      await _pumpDevices(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.add_circle_outline));
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UpgradeDevicesPage), findsOneWidget,
          reason: '关闭删除时的升级入口必须能进到既有的升级设备页');
    });

    testWidgets('开关开启 → 显示删除按钮、无原因说明', (tester) async {
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/subscriptions/devices',
            (s) => s.reply(200, _env(_listBody([_deviceJson()], allowDelete: true))));
        a.onDelete('/devices/11', (s) => s.reply(200, _env(null)));
      });
      await _pumpDevices(tester);

      expect(find.byIcon(Icons.delete_outline), findsOneWidget,
          reason: '后台开启删除后必须显示删除按钮');
      expect(find.text('删除'), findsOneWidget);
      expect(find.byIcon(Icons.add_circle_outline), findsNothing);
      expect(find.text(AppStrings.t('device_delete_disabled_notice')), findsNothing);

      // 二次确认仍然保留
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.delete_outline));
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('确定删除「我的手机」吗？'), findsOneWidget);
    });

    testWidgets('开关字段缺失（旧后端）→ 安全默认：不显示删除按钮', (tester) async {
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/subscriptions/devices',
            (s) => s.reply(200, _env(_listBody([_deviceJson()]))));
      });
      await _pumpDevices(tester);

      expect(find.text('我的手机'), findsOneWidget, reason: '旧后端上列表仍要能显示');
      expect(find.byIcon(Icons.delete_outline), findsNothing,
          reason: '开关未知时必须按不可删除处理，不能让用户点了才被 403 拒绝');
      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    });

    testWidgets('开关中途被后台关掉：DELETE 403 → 提示原文并把删除入口换成升级入口',
        (tester) async {
      // 页面加载时开关是「允许」，用户点删除前管理员把它关了 —— 真实竞态
      var allowDelete = true;
      final adapter = _RecAdapter((o) async {
        final p = o.uri.path;
        if (o.method == 'GET' && p.endsWith('/subscriptions/devices')) {
          return _json(_env(_listBody([_deviceJson()], allowDelete: allowDelete)));
        }
        if (o.method == 'DELETE' && p.endsWith('/devices/11')) {
          return _json({
            'success': false,
            'code': 403,
            'message': '管理员已关闭设备删除，如需更换设备请升级设备数量',
            'data': null,
          }, 403);
        }
        return _json(_env(null));
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
      dio.httpClientAdapter = adapter;
      ApiClient.debugDio = dio;

      await _pumpDevices(tester);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // 后台此时把开关关掉：下一次列表请求就会带回 false
      allowDelete = false;
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.delete_outline));
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 确认删除
      await tester.runAsync(() async {
        await tester.tap(find.descendant(
            of: find.byType(AlertDialog), matching: find.text('删除')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(adapter.calls, contains('DELETE /api/v1/devices/11'));
      // 后端原文必须如实透出（不能只说「失败」）
      expect(find.textContaining('管理员已关闭设备删除'), findsOneWidget,
          reason: '403 时要把后台的原因告诉用户');
      // 并已按新开关重渲染
      expect(find.byIcon(Icons.delete_outline), findsNothing,
          reason: '403 后必须重拉开关，删除入口当场消失');
      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    });
  });
}
