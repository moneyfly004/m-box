// 节点页：下拉刷新 + 空态/无匹配态可滚动（不溢出）。
//
// 背景（UI 审计）：
//   1) 全项目其它列表页都有 RefreshIndicator 或等价物，节点页只有右上角一个
//      小刷新 chip —— 触屏用户习惯的「下拉刷新」在这里没有；
//   2) _EmptyNodesView 是不可滚动的居中 Column，文案来自服务端
//      （AccountService.blockText 在「账号被禁用」时就是后端原文），
//      长文案在 380×620 的最小窗口下只能 RenderFlex overflow（文字被裁掉）。
//
// 契约：列表可下拉刷新（真的触发了一次订阅重新拉取）；空态/无匹配态在最小窗口
//       下不抛任何渲染异常，且内容可滚动。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/subscription_service.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/main.dart';
import 'package:mbox/pages/nodes/nodes_page.dart';
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

/// 服务端订阅原文（刷新后应换成本配置里的节点）
String _clashYaml() => '''
proxies:
  - {name: 刷新后节点, type: ss, server: 9.9.9.9, port: 8388, cipher: aes-128-gcm, password: pw}
''';

/// 超长服务端文案：模拟「账号被禁用」时后端下发的长篇原文
String _longServerMessage() =>
    '账户已被禁用，无法使用服务，请联系客服核实。' * 40; // ≈ 800 字

ProxyNode _node(String tag, String code) => ProxyNode(
      tag: tag,
      type: 'ss',
      server: '1.2.3.4',
      port: 8388,
      countryCode: code,
      latencyMs: 30,
      raw: const {'type': 'ss', 'server': '1.2.3.4', 'port': 8388},
    );

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

/// 构建页面。**不要**包在 runAsync 里：实测在 runAsync 里 pumpWidget 会让后续
/// 下拉手势不再驱动刷新（RefreshIndicator 收不到完整的拖拽通知）。
Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(_wrap(page));
  await tester.pump();
  await tester.pump();
}

/// 换 mock：必须先重置 ApiClient 单例（它缓存了构造时的 dio）
void _useDio(void Function(DioAdapter a) routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  routes(adapter);
  dio.httpClientAdapter = adapter;
  ApiClient.resetInstance();
  ApiClient.debugDio = dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 测试环境禁止真实管理系统代理（stop() 会 spawn networksetup/scutil 挂住）
    ProxyCoreCli.manageSystemProxy = false;
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
    ConnectionController.instance.nodes = [];
    ConnectionController.instance.current = null;
  });

  testWidgets('节点列表有下拉刷新，且真的会重新拉取订阅', (tester) async {
    _useDio((a) {
      a.onGet('/user/subscribe', (s) => s.reply(200, _env(_subInfo())));
      // 订阅原文：route 用正则（fetchText 传的是绝对 URL，路径是全路径），
      // 且必须声明 text/plain —— 默认 application/json 会把 YAML 再 JSON 编码，
      // 解析出来是 0 个节点
      a.onGet(RegExp(r'/client/subscribe$'),
          (s) => s.reply(200, _clashYaml(), headers: {
                Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
              }));
    });

    final conn = ConnectionController.instance;
    conn.current = null;
    await conn.loadNodes([_node('香港-01', 'HK'), _node('日本-01', 'JP')]);
    for (final n in conn.nodes) {
      n.online = true;
    }

    await _pump(tester, const NodesPage());
    expect(find.byType(RefreshIndicator), findsOneWidget,
        reason: '节点页是全项目唯一没有下拉刷新的列表页');
    expect(find.text('香港'), findsOneWidget);

    // 下拉刷新：应该触发 _load(force: true) → 订阅被重新拉取。
    // 注意 pump 序列：RefreshIndicator 的 snap 动画走的是**测试假时钟**，
    // 只有 pump(Duration) 才会推进它（runAsync 里的 Future.delayed 是真实时间，
    // 推不动动画）—— 动画跑完才会调用 onRefresh。
    await tester.fling(find.byType(ListView), const Offset(0, 320), 1200);
    await tester.pump(); // 起手：指示器随下拉出现
    await tester.pump(const Duration(seconds: 1)); // 惯性结束 + snap 动画 → onRefresh
    // 真实异步（网络 + 订阅解析 isolate 需要真实时间）：交替「真实等待」与
    // pump（假时钟推进动画 + 排空在途 future 的微任务）
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    // 新订阅里的节点已应用（证明真的重新拉取了订阅，而不是只转了个圈）
    expect(ConnectionController.instance.nodes.map((n) => n.tag).toList(),
        contains('刷新后节点'),
        reason: '下拉刷新必须复用现有刷新逻辑拉取订阅');

    // 卸载页面，避免残留的周期/防抖定时器把用例判成 Pending timers
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('空态长文案（服务端原文）在 380×620 下不溢出且可滚动', (tester) async {
    tester.view.physicalSize = const Size(380, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 账号被禁用：blockText 直接是服务端原文（长度不可控）
    AccountService.instance.status = AccountStatus.accountDisabled;
    AccountService.instance.serverMessage = _longServerMessage();
    await ConnectionController.instance.loadNodes(const []);
    ConnectionController.instance.current = null;

    ApiClient.debugDio = null;
    await _pump(tester, const NodesPage());

    expect(find.textContaining('账户已被禁用'), findsOneWidget);
    // 可滚动：长文案能滚出来，而不是被裁掉
    expect(find.byType(SingleChildScrollView), findsWidgets,
        reason: '空态必须可滚动（旧实现是不可滚动的居中 Column）');
    expect(tester.takeException(), isNull,
        reason: '长服务端文案在最小窗口下溢出（RenderFlex overflow）');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('空态长文案：滚动到底能看到引导按钮（内容没被裁掉）', (tester) async {
    tester.view.physicalSize = const Size(380, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AccountService.instance.status = AccountStatus.expired;
    AccountService.instance.serverMessage = null;
    await ConnectionController.instance.loadNodes(const []);
    ConnectionController.instance.current = null;

    await _pump(tester, const NodesPage());
    expect(find.text(AppStrings.t('account_expired_block')), findsOneWidget);

    // 滚到底：按钮应可见（旧实现在这里会被裁掉，用户点不到）
    final sc = find.byType(SingleChildScrollView).first;
    await tester.drag(sc, const Offset(0, -400));
    await tester.pump();
    expect(find.text(AppStrings.t('go_purchase')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('搜索无匹配：提示可滚动，不溢出', (tester) async {
    tester.view.physicalSize = const Size(380, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final conn = ConnectionController.instance;
    conn.current = null;
    await conn.loadNodes([_node('香港-01', 'HK')]);
    for (final n in conn.nodes) {
      n.online = true;
    }

    await _pump(tester, const NodesPage());
    // 搜索防抖 300ms：输入后等它触发（定时器在断言前就跑完了）
    await tester.enterText(find.byType(TextField), 'zzz-no-such-node');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text(AppStrings.t('no_match_nodes')), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: '无匹配提示也不能在最小窗口下溢出');

    await tester.pumpWidget(const SizedBox());
  });
}
