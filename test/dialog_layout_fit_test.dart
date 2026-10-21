// 窄窗口（最小 380×620）布局回归测试：支付弹窗两按钮等高、加载/错误态不溢出。
//
// 背景（UI 审计）：
//   · payment_dialog：左侧 OutlinedButton 靠 padding 撑出 ~42 高、右侧容器写死
//     height: 50 —— 并排两个按钮不等高；窄窗口下整块内容也可能超高；
//   · upgrade_devices_page：加载态是一个裸的居中 spinner（套餐页早有骨架）；
//   · profile_page：错误态是 Center+Column，长文案没有限行。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/proxy/proxy_core_cli.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/core/services/user_service.dart';
import 'package:moneyfly/l10n/app_strings.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/package/package_page.dart';
import 'package:moneyfly/pages/package/upgrade_devices_page.dart';
import 'package:moneyfly/pages/payment/payment_dialog.dart';
import 'package:moneyfly/pages/profile/profile_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

Map<String, dynamic> _env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

Dio _mockDio(void Function(DioAdapter a) routes) {
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

void _minWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(380, 620);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProxyCoreCli.manageSystemProxy = false;
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  group('支付弹窗：底部两个按钮等高', () {
    testWidgets('380×620 下「取消」与「我已支付」高度一致，且不溢出', (tester) async {
      _minWindow(tester);
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/orders/ORD-LONG-20260101/status',
            (s) => s.reply(200, _env({'status': 'pending'})));
      });
      PaymentQrDialog.debugTimeoutSecsOverride = null;
      addTearDown(() => PaymentQrDialog.debugTimeoutSecsOverride = null);

      await tester.pumpWidget(_wrap(const PaymentQrDialog(
        qrContent: 'https://qr.alipay.com/xxx',
        orderNo: 'ORD-LONG-20260101-ABCDEFGHIJKLMNOP',
        amount: 19.9,
        methodName: '支付宝',
      )));
      await tester.pump();

      final cancelSize = tester.getSize(find.byType(OutlinedButton));
      final paidSize = tester.getSize(find
          .ancestor(
              of: find.text(AppStrings.t('i_paid')),
              matching: find.byType(Container))
          .first);

      expect(cancelSize.height, paidSize.height,
          reason: '两个按钮不等高（旧实现：左 ~42 / 右写死 50）');
      expect(cancelSize.height, greaterThanOrEqualTo(44),
          reason: '取消按钮也是可点目标，不能比右边矮一截');
      expect(tester.takeException(), isNull,
          reason: '窄窗口下弹窗内容溢出');

      // 订单号行保持单行省略（长订单号不能把弹窗撑宽/换行）
      final orderText = tester.widget<Text>(
          find.textContaining(AppStrings.t('order_no')).first);
      expect(orderText.maxLines, 1);
      expect(orderText.overflow, TextOverflow.ellipsis);

      // 卸载：弹窗内有 3s 周期轮询定时器
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
    });
  });

  group('升级设备页：加载态不再是裸 spinner', () {
    testWidgets('380×620 下加载中显示骨架（无转圈），加载完显示真实内容且不溢出', (tester) async {
      _minWindow(tester);
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/payment/methods',
            (s) => s.reply(200, _env([
                  {'id': 1, 'pay_type': 'alipay', 'name': '支付宝', 'sort_order': 1},
                ]), delay: const Duration(milliseconds: 400)));
        a.onPost(
            '/orders/upgrade-devices',
            (s) => s.reply(200, _env({'amount': 30.0, 'final_amount': 30.0}),
                delay: const Duration(milliseconds: 50)),
            data: Matchers.any);
      });

      await tester.pumpWidget(_wrap(const UpgradeDevicesPage()));
      await tester.pump();

      // 加载中：骨架（无 CircularProgressIndicator、无真实内容）
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '裸的居中 spinner 已换成套餐页同款骨架');
      expect(find.text(AppStrings.t('upgrade_current')), findsNothing);
      expect(tester.takeException(), isNull, reason: '骨架在最小窗口下溢出');

      // 等加载完成：DioAdapter 的 delay 是**假时钟**里的 Timer（必须 pump(Duration)
      // 才推进），页面里可能还有真实异步（磁盘缓存写入）→ 两者交替推进
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pump();
      }

      expect(find.text(AppStrings.t('upgrade_current')), findsOneWidget);
      // 30 元预览价：按钮文案带金额（口径与套餐页一致，不带 .00）
      // 天数选项从 5 个增加到 7 个（与后台月份卡片对齐）+ 多一行提示后，
      // 页面变长，底部按钮可能落在首屏之外（ListView 懒构建）→ 先滚到可见。
      final payText = '${AppStrings.t('upgrade_pay_btn')} ¥30';
      await tester.scrollUntilVisible(
        find.text(payText),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text(payText), findsOneWidget,
          reason: '30 元预览价应显示「立即支付 ¥30」');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('套餐页：错误态长文案在最小窗口下不溢出', () {
    testWidgets('服务端返回一整段 HTML 错误页时，错误态可滚动、不抛渲染异常', (tester) async {
      _minWindow(tester);
      // ApiClient.errorMsg 对「响应体是字符串」会**原样返回服务端正文**
      // （例如网关吐的整页 HTML），长度不可控
      final longError = '<html><body>${'Internal Server Error ' * 40}</body></html>';
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/packages', (s) => s.reply(500, longError));
        a.onGet('/payment/methods', (s) => s.reply(500, longError));
      });

      await tester.pumpWidget(_wrap(const PackagePage()));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
      }
      await tester.pump();

      expect(find.text(AppStrings.t('retry')), findsOneWidget,
          reason: '加载失败要给重试入口');
      expect(tester.takeException(), isNull,
          reason: '长服务端错误正文把固定高度的错误态撑爆（RenderFlex overflow）');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5)); // SnackBar 定时器
    });
  });

  group('我的页：错误态在最小窗口下不溢出', () {    testWidgets('380×620 下加载失败：可滚动、文案限行、无渲染异常', (tester) async {
      _minWindow(tester);
      UserService.instance.invalidateCache();
      ApiClient.debugDio = _mockDio((a) {
        a.onGet('/users/dashboard-info', (s) => s.reply(500, _env(null)));
      });

      await tester.runAsync(() async {
        await tester.pumpWidget(_wrap(const ProfilePage()));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.pump();

      expect(find.text(AppStrings.t('profile_load_fail')), findsOneWidget);
      final t = tester.widget<Text>(find.text(AppStrings.t('profile_load_fail')));
      expect(t.maxLines, isNotNull, reason: '错误文案必须限行（无限行会被长文案撑爆）');
      expect(t.overflow, TextOverflow.ellipsis);
      // 整页可滚动（错误态在 ListView 里，长文案/小窗口都能滚）
      expect(find.byType(Scrollable), findsWidgets);
      expect(find.text(AppStrings.t('retry')), findsOneWidget,
          reason: '错误态必须给重试入口');
      expect(tester.takeException(), isNull);

      // 卸载：SnackBar 有自动消失定时器
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
