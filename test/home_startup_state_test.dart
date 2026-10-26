// 冷启动首页状态：不能把「订阅还在路上」显示成「节点加载失败」。
//
// 实测反馈：软件打开一瞬间，主页先闪一句「节点加载失败，请检查网络后重试」+
// 重试按钮。根因是 `_ensureNodes` 把 `_loadingNodes = true` 放在**账号刷新之后**，
// 而它前面还有网络请求与磁盘读缓存两个 await —— 那段时间 nodes 为空、loading 为
// false，正好落进「空且非加载中」的报错分支。
//
// 这里用「延迟回包」的 mock 把「在途状态」确定性撑住再断言；全程 runAsync
// （真实异步），与仓库既有测试一致，避免 fake-async 把 Dio 定时器记成 pending。
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
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/main.dart';
import 'package:mbox/pages/home/home_page.dart';
import 'package:mbox/theme/app_theme.dart';

Map<String, dynamic> _env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

Map<String, dynamic> _subInfo() => {
      'subscribe_url': 'https://dy.moneyfly.top/api/v1/client/subscribe',
      'expire_time': '2032-06-06 08:00:00',
      'device_limit': 600,
      'current_devices': 3,
      'remaining_days': 2104,
      'is_expired': false,
      'status': 'active',
    };

/// 订阅拉取故意慢一点：把「正在更新订阅」这个在途状态稳定撑开
const _slow = Duration(milliseconds: 500);

/// 可被解析的最小 Clash 订阅（一个 ss 节点），让加载流程能真正走完
const _clashYaml = '''
proxies:
  - {name: 测试节点, type: ss, server: 1.2.3.4, port: 8388, cipher: aes-128-gcm, password: pw}
''';

/// 注册两个请求：账号信息（慢，用来撑开在途态）与订阅本体（快）
void _mock(DioAdapter adapter) {
  adapter.onGet('/user/subscribe',
      (s) => s.reply(200, _env(_subInfo()), delay: _slow));
  adapter.onGet('/client/subscribe',
      (s) => s.reply(200, _clashYaml, delay: const Duration(milliseconds: 60)));
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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('冷启动「订阅在途」时显示「正在更新订阅」，不显示加载失败', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
    final adapter = DioAdapter(dio: dio);
    _mock(adapter);
    ApiClient.debugDio = dio;

    await ConnectionController.instance.loadNodes(const []);

    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(const HomePage()));
      // 仍在途：订阅回包要 500ms 才到
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();

    expect(find.text(AppStrings.t('sub_updating_wait')), findsOneWidget,
        reason: '冷启动应先告诉用户「正在更新订阅」');
    expect(find.text(AppStrings.t('nodes_empty_retry')), findsNothing,
        reason: '这一瞬间只是订阅在路上，不该显示成加载失败');
    expect(find.text(AppStrings.t('retry_btn')), findsNothing,
        reason: '同理不该出现「重试」按钮（会让人以为真出错了）');

    // 收尾：让在途请求跑完，避免留下未完成的异步
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 3000));
    });
    await tester.pump();
  });

  testWidgets('加载结束后「正在更新订阅」必须收起（不会无限挂在页面上）', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
    final adapter = DioAdapter(dio: dio);
    _mock(adapter);
    ApiClient.debugDio = dio;

    await ConnectionController.instance.loadNodes(const []);

    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(const HomePage()));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    expect(find.text(AppStrings.t('sub_updating_wait')), findsOneWidget);

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 3000));
    });
    await tester.pump();
    await tester.pump();

    expect(find.text(AppStrings.t('sub_updating_wait')), findsNothing,
        reason: '过程提示结束后必须收起');
  });
}
