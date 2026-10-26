// 主页「卡片来回跳动」的回归测试。
//
// 症状来源（2026-09 实测）：主页卡片内容每秒左右抖 / 上下跳。根因不是随机 bug，
// 而是「数值文本每秒变宽 + 布局没给这些位置留固定槽位」，外加两处「有/无」会
// 改变高度。这些用例用**几何断言**把它钉住 —— 抖动是可测量的，不是主观感受。
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
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/main.dart';
import 'package:mbox/pages/home/home_page.dart';
import 'package:mbox/theme/app_theme.dart';

Map<String, dynamic> _env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

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

Future<void> _pumpHome(WidgetTester tester) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  adapter.onGet('/user/subscribe', (s) => s.reply(200, _env({
        'subscribe_url': 'https://x/subscribe?token=t',
        'expire_time': '2032-06-06 08:00:00',
        'device_limit': 600,
        'current_devices': 3,
        'remaining_days': 2104,
        'is_expired': false,
        'status': 'active',
      })));
  ApiClient.debugDio = dio;
  await tester.runAsync(() async {
    await tester.pumpWidget(_wrap(const HomePage()));
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  group('formatSpeed：单位迟滞（消除 0.1 MB/s 附近的来回翻转）', () {
    test('完全空闲不切单位，且数值固定为 0.0', () {
      expect(formatSpeed(0), (value: '0.0', unit: 'MB/s'));
      // 上一秒是 KB/s 时也不翻回 MB/s（否则空闲抖动会来回切）
      expect(formatSpeed(0, lastUnit: 'KB/s'), (value: '0.0', unit: 'KB/s'));
    });

    test('低速用 KB/s，且数值为整数（不含小数点）', () {
      final r = formatSpeed(0.05);
      expect(r.unit, 'KB/s');
      expect(r.value, '51');
    });

    test('迟滞：已在 KB/s 时，0.12 不会切回 MB/s（关键回归点）', () {
      // 旧实现按固定阈值 0.1：0.12 >= 0.1 会立刻切回 MB/s，
      // 而速率在 0.1 附近抖动时就变成每秒翻转 → 卡片数字来回跳
      expect(formatSpeed(0.12, lastUnit: 'KB/s').unit, 'KB/s');
      // 明确变快了（>= 0.15）才切回
      expect(formatSpeed(0.16, lastUnit: 'KB/s').unit, 'MB/s');
    });

    test('迟滞：已在 MB/s 时，0.09 不会切到 KB/s（同一抖动区间的另一侧）', () {
      expect(formatSpeed(0.09, lastUnit: 'MB/s').unit, 'MB/s');
      expect(formatSpeed(0.05, lastUnit: 'MB/s').unit, 'KB/s');
    });

    test('高速保持 MB/s 且一位小数', () {
      expect(formatSpeed(12.34), (value: '12.3', unit: 'MB/s'));
      expect(formatSpeed(1023.9), (value: '1023.9', unit: 'MB/s'));
    });

    test('同一数值区间内反复抖动不再翻转单位', () {
      // 模拟速率在 0.08~0.13 之间来回抖动 20 次
      var unit = 'MB/s';
      final seen = <String>{};
      for (var i = 0; i < 20; i++) {
        final mbps = i.isEven ? 0.09 : 0.12;
        final r = formatSpeed(mbps, lastUnit: unit);
        unit = r.unit;
        seen.add(unit);
      }
      expect(seen.length, 1, reason: '抖动区间内单位发生了翻转：$seen');
    });
  });

  group('主页几何：单位与卡片高度不随数值变化', () {
    testWidgets('速率数值变化时，上行单位的位置不变', (tester) async {
      final conn = ConnectionController.instance;
      await conn.loadNodes([
        ProxyNode(tag: '香港-01', type: 'vless', server: '1.2.3.4', port: 443, countryCode: 'HK', latencyMs: 35),
      ]);
      conn.current = conn.nodes.first;
      await _pumpHome(tester);

      // 单位是固定槽位：先测一次「零速率」下的位置
      conn.speedNotifier.value = const SpeedSnapshot();
      await tester.pump();
      final before = tester.getTopLeft(find.text('MB/s').first);

      // 数值变化 + 下行单位切换（KB/s），上行单位必须原地不动
      conn.speedNotifier.value =
          const SpeedSnapshot(upMbps: 12.3, downMbps: 0.05);
      await tester.pump();
      final after = tester.getTopLeft(find.text('MB/s').first);

      expect(after, before, reason: '速率数值变化把单位推走了（旧实现就是这样每秒抖一次）');
      // 数值字符串变了（说明确实重绘了，而不是断言空转）
      expect(find.text('12.3'), findsOneWidget);
    });

    testWidgets('趋势线从「无样本」到「有样本」不改变下方内容位置', (tester) async {
      final conn = ConnectionController.instance;
      await conn.loadNodes([
        ProxyNode(tag: '香港-01', type: 'vless', server: '1.2.3.4', port: 443, countryCode: 'HK', latencyMs: 35),
      ]);
      conn.current = conn.nodes.first;
      conn.upHistory.clear();
      conn.downHistory.clear();
      await _pumpHome(tester);
      conn.speedNotifier.value = const SpeedSnapshot();
      await tester.pump();

      // 快速切换国家区在速率卡片**下方**：它的 y 位移 = 上方卡片高度是否变了
      final finder = find.text(AppStrings.t('quick_switch_country'));
      expect(finder, findsOneWidget, reason: '需要下方锚点才能测高度变化');
      final yNoSamples = tester.getTopLeft(finder).dy;

      // 补足样本 → 趋势线开始绘制（旧实现此时会多出 36px 高度）。
      // 注意：upHistory 是普通 List，改它不会通知监听者 —— 必须像真实链路那样
      // 由 speedNotifier 打一拍，否则统计卡根本不重建，断言就变成空转。
      conn.upHistory.addAll([1.0, 2.0, 3.0]);
      conn.downHistory.addAll([1.0, 2.0, 3.0]);
      conn.speedNotifier.value =
          const SpeedSnapshot(upMbps: 1.2, downMbps: 2.3);
      await tester.pump();
      final yWithSamples = tester.getTopLeft(finder).dy;

      expect(yWithSamples, yNoSamples,
          reason: '趋势线出现/消失改变了卡片高度 → 下方内容上下跳');
    });

    testWidgets('断开（清空趋势数据）也不移动下方内容', (tester) async {
      final conn = ConnectionController.instance;
      await conn.loadNodes([
        ProxyNode(tag: '香港-01', type: 'vless', server: '1.2.3.4', port: 443, countryCode: 'HK', latencyMs: 35),
      ]);
      conn.current = conn.nodes.first;
      conn.upHistory.addAll([1.0, 2.0, 3.0]);
      conn.downHistory.addAll([1.0, 2.0, 3.0]);
      await _pumpHome(tester);

      final finder = find.text(AppStrings.t('quick_switch_country'));
      final yConnected = tester.getTopLeft(finder).dy;

      conn.upHistory.clear();
      conn.downHistory.clear();
      conn.speedNotifier.value = const SpeedSnapshot();
      await tester.pump();
      expect(tester.getTopLeft(finder).dy, yConnected,
          reason: '清空历史后卡片缩回，下方内容上移了');
    });
  });
}
