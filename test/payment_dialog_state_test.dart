// 支付弹窗的「轮询状态可见性」回归测试。
//
// 背景（用户看不到的钱风险）：旧实现里 _pollOnce 超时后只是 `_polling = false; return;`
// —— 界面毫无变化，用户以为还在查单，可能对着一个已经不再被查询（很可能已失效）的
// 二维码继续付款；订单被后端置为 cancelled/expired 时也只有一闪而过的 toast，
// 从支付 App 切回来看不到。
//
// 契约：
//   · 轮询中 → 有「正在等待支付结果」提示；
//   · 超时（15 分钟）→ 有明确的「已停止自动查询」提示（不再是静默）；
//   · 后端终态 → 提示留在界面上（不是只闪 2 秒的 toast）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/payment/payment_dialog.dart';
import 'package:mbox/theme/app_theme.dart';

Dio _mockDio(DioAdapter adapter, String status) {
  adapter.onGet('/orders/ORD1/status', (s) => s.reply(200, {
        'success': true,
        'data': {
          'order_no': 'ORD1',
          'status': status,
          'amount': 19.9,
          'final_amount': 19.9,
          'type': 'order',
        },
      }));
  return adapter.dio;
}

Future<void> _pump(WidgetTester tester, String status) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.mbox.top/api/v1'));
  ApiClient.debugDio = _mockDio(DioAdapter(dio: dio), status);
  ApiClient.persistTokens = false;
  ApiClient.resetInstance();
  addTearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    PaymentQrDialog.debugTimeoutSecsOverride = null;
  });
  await tester.pumpWidget(MaterialApp(
    theme: buildMBoxTheme(),
    home: const Scaffold(
      body: PaymentQrDialog(
        qrContent: 'https://qr.alipay.com/xxx',
        orderNo: 'ORD1',
        amount: 19.9,
        methodName: '支付宝',
      ),
    ),
  ));
  await tester.pump();
}

/// 弹窗里有周期轮询定时器：用例结束前必须把弹窗卸载掉，否则 flutter_test
/// 会以「Pending timers」失败。
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // 让 Dio 在途请求里那个 0 时长定时器跑完（否则 flutter_test 报 Pending timers）
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppStrings.setLang('zh', persist: false));

  testWidgets('轮询中：界面明确显示「正在等待支付结果」', (tester) async {
    await _pump(tester, 'pending');
    expect(find.text(AppStrings.t('pay_waiting')), findsOneWidget,
        reason: '旧实现在等待期间没有任何状态提示');
    await _dispose(tester);
  });

  testWidgets('轮询超时：必须给出「已停止自动查询」，不能静默停掉', (tester) async {
    PaymentQrDialog.debugTimeoutSecsOverride = 3; // 一个轮询周期即超时
    await _pump(tester, 'pending');
    expect(find.text(AppStrings.t('pay_waiting')), findsOneWidget);
    // 让周期定时器跑到超时分支（周期 3s）
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.text(AppStrings.t('pay_poll_stopped')), findsOneWidget,
        reason: '超时后界面毫无变化 = 用户以为还在查单');
    await _dispose(tester);
  });

  testWidgets('后端终态：原因留在界面上（不只闪一下 toast）', (tester) async {
    await _pump(tester, 'expired');
    // 首查立即返回终态
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        find.textContaining(AppStrings.t('expired'), findRichText: true),
        findsWidgets);
    // 再等一会儿，toast 已经消失，但界面提示仍在
    await tester.pump(const Duration(seconds: 5));
    expect(
        find.textContaining(AppStrings.t('expired'), findRichText: true),
        findsWidgets,
        reason: '终态不能只靠 2 秒的 toast');
    await _dispose(tester);
  });
}
