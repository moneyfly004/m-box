// 设置页「测速方式」入口的组件测试 + 节点页测速口径提示。
//
// 守卫的是「用户能看见、能切换、切换真的落盘」这条链路：
//   1) 设置页有「测速方式」行，默认显示「内核测速」（真连接，保证节点能用）；
//   2) 点开选择器能看到两项，选 TCP 后写入 SettingsStore（值是 'tcp'）；
//   3) 再切回内核测速 → 写入 'kernel'（用户可以来回切，不会卡死）；
//   4) 节点页显示当前测速口径（来源标识），切换后提示随之变化。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:mbox/core/services/speed_test_mode.dart';
import 'package:mbox/core/services/subscription_service.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/nodes/nodes_page.dart';
import 'package:mbox/pages/settings/settings_page.dart';
import 'package:mbox/theme/app_theme.dart';

Widget _wrap(Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ConnectionController.instance),
        ChangeNotifierProvider.value(value: AccountService.instance),
      ],
      child: MaterialApp(theme: buildMBoxTheme(), home: child),
    );

/// 限定在弹窗内查找控件（设置行的描述文案常与选项文案撞词）
Finder _inDialog(Finder matching) =>
    find.descendant(of: find.byType(Dialog), matching: matching);

/// 设置页是懒加载 ListView，目标行常在视口外
Future<void> _scrollTo(WidgetTester tester, String title) async {
  final f = find.text(title);
  await tester.scrollUntilVisible(f, 220,
      scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'mbox_lang': 'zh'});
    SettingsStore.resetForTest();
    await AppStrings.setLang('zh', persist: false);
    ProxyCoreCli.manageSystemProxy = false;
    ConnectionController.instance.speedTestMode = defaultSpeedTestMode;
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('设置页有「测速方式」行，默认显示内核测速', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));

    await _scrollTo(tester, AppStrings.t('settings_speed_mode'));
    expect(find.text(AppStrings.t('settings_speed_mode')), findsOneWidget);
    // 默认值必须是内核测速（真连接 → 测出延迟的节点真能用；用户可切到 TCP）
    expect(find.text(AppStrings.t('speed_mode_kernel')), findsOneWidget);
    expect(find.text(AppStrings.t('speed_mode_tcp')), findsNothing);
  });

  testWidgets('设置页默认（未存任何设置）时选择器把内核测速排第一且勾在它上面', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));
    await _scrollTo(tester, AppStrings.t('settings_speed_mode'));
    await tester.tap(find.text(AppStrings.t('settings_speed_mode')));
    await tester.pumpAndSettle();

    // 「默认内核、可选 TCP」在 UI 上要看得见：第一行就是默认项，且带当前项勾选
    final options = tester
        .widgetList<SimpleDialogOption>(find.byType(SimpleDialogOption))
        .toList();
    expect(options.length, 2, reason: '测速方式只有两项：内核测速（默认）/ TCP');
    final first = find.descendant(
        of: find.byType(SimpleDialogOption).first,
        matching: find.textContaining(AppStrings.t('speed_mode_kernel')));
    expect(first, findsOneWidget, reason: '默认项（内核测速）必须排在第一行');
    // 勾选标记（Icons.check）落在第一行 = 当前生效的就是默认项
    expect(
        find.descendant(
            of: find.byType(SimpleDialogOption).first,
            matching: find.byIcon(Icons.check)),
        findsOneWidget,
        reason: '未存设置时当前项应是默认的内核测速');
    expect(
        find.descendant(
            of: find.byType(SimpleDialogOption).last,
            matching: find.byIcon(Icons.check)),
        findsNothing);
    // 选项说明里写明「默认」，用户不必猜
    expect(
        find.descendant(
            of: find.byType(Dialog),
            matching: find.textContaining(AppStrings.t('speed_mode_kernel_desc'))),
        findsOneWidget);
    expect(AppStrings.t('speed_mode_kernel_desc'), contains('默认'),
        reason: '中文默认项说明应带「默认」字样');
  });

  testWidgets('切换到 TCP 测速：落到 SettingsStore（值 tcp），控制器同步', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));
    await _scrollTo(tester, AppStrings.t('settings_speed_mode'));
    await tester.tap(find.text(AppStrings.t('settings_speed_mode')));
    await tester.pumpAndSettle();

    // 选择器里两项都在（带取舍说明）。注意必须限定在对话框内：设置行的
    // 描述文案里也含「TCP 测速」字样，直接 textContaining 会命中那一行。
    expect(_inDialog(find.textContaining(AppStrings.t('speed_mode_kernel'))),
        findsOneWidget);
    expect(_inDialog(find.textContaining(AppStrings.t('speed_mode_tcp'))),
        findsOneWidget);
    await tester.tap(_inDialog(find.textContaining(AppStrings.t('speed_mode_tcp'))));
    await tester.pumpAndSettle();

    // 即时生效到控制器（_set 里同步调用 applySettings，用户立刻看到变化）
    expect(ConnectionController.instance.speedTestMode, SpeedTestMode.tcp,
        reason: '设置页 _set 会立刻同步到连接控制器');
    // 落盘：_set 的持久化是排队异步的（unawaited + 串行写队列），
    // widget 测试里必须放真实异步时间（runAsync）才能等到它落盘。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    final s = await SettingsStore.instance.load();
    expect(s['speedTestMode'], 'tcp');
    // 行右侧的值也变了（用户能看见）
    expect(find.text(AppStrings.t('speed_mode_tcp')), findsOneWidget);
  });

  testWidgets('再切回内核测速 → 值回到 kernel（可来回切换）', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 预置「用户上次选了 TCP」的状态。注意：widget 测试里直接 await
    // SettingsStore 的写盘会挂在假异步 zone 上（平台通道的 Future 不推进），
    // 必须放进 runAsync 用真实异步执行。
    await tester.runAsync(() async {
      await SettingsStore.instance
          .update((s) => s['speedTestMode'] = 'tcp');
    });
    ConnectionController.instance.speedTestMode = SpeedTestMode.tcp;

    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));
    await _scrollTo(tester, AppStrings.t('settings_speed_mode'));
    expect(find.text(AppStrings.t('speed_mode_tcp')), findsOneWidget);

    await tester.tap(find.text(AppStrings.t('settings_speed_mode')));
    await tester.pumpAndSettle();
    await tester.tap(
        _inDialog(find.textContaining(AppStrings.t('speed_mode_kernel'))));
    await tester.pumpAndSettle();

    expect(ConnectionController.instance.speedTestMode, SpeedTestMode.kernel);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect((await SettingsStore.instance.load())['speedTestMode'], 'kernel');
  });

  testWidgets('节点页默认（未设置）时口径提示显示内核测速', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // setUp 里把控制器重置成 defaultSpeedTestMode（= 内核测速）——不额外设置
    // 任何东西，模拟「用户从未改过测速方式」的真实默认状态
    final conn = ConnectionController.instance;
    expect(conn.speedTestMode, SpeedTestMode.kernel);
    conn.lastSpeedTestTime = null;
    await conn.loadNodes([
      ProxyNode(
          tag: '香港-01',
          type: 'vless',
          server: '127.0.0.1',
          port: 9,
          countryCode: 'HK',
          raw: const {}),
    ]);

    await tester.pumpWidget(_wrap(const NodesPage()));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text(AppStrings.t('speed_mode_label',
          {'mode': AppStrings.t('speed_mode_kernel_short')})),
      findsOneWidget,
      reason: '默认口径必须是内核测速（与 defaultSpeedTestMode 一致）',
    );
  });

  testWidgets('节点页显示当前测速口径（来源标识），切换后随之变化', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final conn = ConnectionController.instance;
    conn.speedTestMode = SpeedTestMode.kernel;
    conn.lastSpeedTestTime = null;
    await conn.loadNodes([
      ProxyNode(
          tag: '香港-01',
          type: 'vless',
          server: '127.0.0.1',
          port: 9,
          countryCode: 'HK',
          raw: const {}),
    ]);

    await tester.pumpWidget(_wrap(const NodesPage()));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text(AppStrings.t('speed_mode_label',
          {'mode': AppStrings.t('speed_mode_kernel_short')})),
      findsOneWidget,
    );

    // 切到 TCP 测速 → 提示改为 TCP 口径
    conn.speedTestMode = SpeedTestMode.tcp;
    conn.notifyListeners();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text(AppStrings.t('speed_mode_label',
          {'mode': AppStrings.t('speed_mode_tcp_short')})),
      findsOneWidget,
    );
  });

  testWidgets('测速完成后节点页显示「上次测速 时刻 · 方式」', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final conn = ConnectionController.instance;
    conn.speedTestMode = SpeedTestMode.kernel;
    conn.lastSpeedTestTime = '14:32';
    conn.lastSpeedTestMode = SpeedTestMode.kernel;
    await conn.loadNodes([
      ProxyNode(
          tag: '香港-01',
          type: 'vless',
          server: '127.0.0.1',
          port: 9,
          countryCode: 'HK',
          raw: const {}),
    ]);

    await tester.pumpWidget(_wrap(const NodesPage()));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text(AppStrings.t('speed_last_result', {
        'time': '14:32',
        'mode': AppStrings.t('speed_mode_kernel_short'),
      })),
      findsOneWidget,
    );
  });
}
