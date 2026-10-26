import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/services/order_service.dart';
import 'package:mbox/core/services/payment_service.dart';

void main() {
  late Dio dio;
  late DioAdapter adapter;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://test.mbox.top/api/v1'));
    adapter = DioAdapter(dio: dio);
    ApiClient.debugDio = dio;
    ApiClient.persistTokens = false;
    ApiClient.resetInstance();
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
  });

  test('创建订单返回 order_no', () async {
    adapter.onPost('/orders', (s) => s.reply(200, {
      'success': true, 'data': {'id': 42, 'order_no': 'ORD2026090401', 'amount': 19.9},
    }), data: Matchers.any);

    final result = await OrderService.instance.create(packageId: 1);
    expect(result['order_no'], 'ORD2026090401');
    expect(result['amount'], 19.9);
  });

  test('发起支付返回 qr_code', () async {
    adapter.onPost('/payment', (s) => s.reply(200, {
      'success': true,
      'data': {'payment_qr_code': 'https://qr.alipay.com/xxx', 'order_no': 'ORD001', 'status': 'pending'},
    }), data: Matchers.any);

    final result = await OrderService.instance.pay(orderId: 42, paymentMethodId: 1);
    expect(result.qrCode, 'https://qr.alipay.com/xxx');
    expect(result.orderNo, 'ORD001');
    expect(result.status, 'pending');
  });

  test('轮询订单状态 pending → paid', () async {
    // 首次返回 pending
    adapter.onGet('/orders/ORD001/status', (s) => s.reply(200, {
      'success': true,
      'data': {'order_no': 'ORD001', 'status': 'pending', 'amount': 19.9, 'final_amount': 19.9, 'type': 'order'},
    }));

    final st1 = await OrderService.instance.status('ORD001');
    expect(st1.isPaid, false);
    expect(st1.status, 'pending');

    // 第二次返回 paid（重新注册 mock）
    adapter.onGet('/orders/ORD001/status', (s) => s.reply(200, {
      'success': true,
      'data': {'order_no': 'ORD001', 'status': 'paid', 'amount': 19.9, 'final_amount': 19.9, 'type': 'order'},
    }));

    final st2 = await OrderService.instance.status('ORD001');
    expect(st2.isPaid, true);
    expect(st2.status, 'paid');
  });

  test('支付方式列表解析', () async {
    adapter.onGet('/payment/methods', (s) => s.reply(200, {
      'success': true,
      'data': [
        {'id': 1, 'key': 'alipay', 'name': '支付宝', 'sort_order': 1},
        {'id': 2, 'key': 'wechat', 'name': '微信支付', 'sort_order': 2},
      ],
    }));

    final methods = await PaymentService.instance.methods();
    expect(methods.length, 2);
    expect(methods.first.isAlipay, true);
    expect(methods.last.isWechat, true);
  });
}
