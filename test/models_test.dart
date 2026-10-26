import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';

void main() {
  group('PayMethod 解析（实测后端返回 key 字段）', () {
    test('key=alipay 识别为支付宝', () {
      final m = PayMethod.fromJson({'id': 1, 'key': 'alipay', 'name': '支付宝', 'status': 1});
      expect(m.isAlipay, isTrue);
      expect(m.name, '支付宝');
    });
    test('key=yipay_wxpay 识别为微信', () {
      final m = PayMethod.fromJson({'id': 2, 'key': 'yipay_wxpay', 'name': '易支付-微信'});
      expect(m.isWechat, isTrue);
      expect(m.isAlipay, isFalse);
    });
    test('key=usdt 识别为加密货币', () {
      final m = PayMethod.fromJson({'id': 3, 'key': 'usdt', 'name': 'USDT 加密货币'});
      expect(m.isCrypto, isTrue);
    });
    test('兼容旧 pay_type 字段', () {
      final m = PayMethod.fromJson({'id': 4, 'pay_type': 'alipay', 'name': '支付宝'});
      expect(m.isAlipay, isTrue);
    });
  });

  group('设备解析', () {
    test('remark/设备名/在线状态', () {
      final d = DeviceInfo.fromJson({
        'id': 11, 'device_name': 'iPhone', 'os_name': 'iOS', 'os_version': '18',
        'ip_address': '1.2.3.4', 'location': '广东', 'is_active': true,
        'access_count': 5, 'remark': '我的手机', 'last_seen': '2026-09-01 12:00:00',
      });
      expect(d.remark, '我的手机');
      expect(d.displayName, 'iPhone');
      expect(d.isActive, isTrue);
    });
  });

  group('订单解析', () {
    test('状态与金额', () {
      final o = OrderItem.fromJson({
        'id': 9, 'order_no': 'MF202609011234', 'amount': 49.9, 'final_amount': 44.9,
        'status': 'paid', 'package': {'name': '季付套餐'}, 'created_at': '2026-09-01 12:00:00',
      });
      expect(o.statusLabel, '已支付');
      expect(o.packageName, '季付套餐');
      expect(o.finalAmount, 44.9);
    });
    test('OrderStatus 解析', () {
      final s = OrderStatus.fromJson({'order_no': 'X', 'status': 'paid', 'amount': 19.9, 'final_amount': 19.9, 'type': 'order'});
      expect(s.isPaid, isTrue);
    });
  });

  group('优惠券折扣', () {
    test('百分比折扣', () {
      final c = Coupon.fromJson({'code': 'VIP50', 'discount_type': 'percent', 'discount_value': 50});
      expect(c.applyTo(100), closeTo(50, 0.01));
    });
    test('固定金额折扣', () {
      final c = Coupon.fromJson({'code': 'OFF10', 'discount_type': 'fixed', 'discount_value': 10});
      expect(c.applyTo(49.9), closeTo(39.9, 0.01));
    });
    test('折扣不低于 0.01', () {
      final c = Coupon.fromJson({'code': 'OFF999', 'discount_type': 'fixed', 'discount_value': 999});
      expect(c.applyTo(10), 0.01);
    });
  });

  group('仪表盘解析', () {
    test('余额字符串兼容', () {
      final d = DashboardInfo.fromJson({
        'username': 'test', 'email': 't@t.com', 'balance': '12.50',
        'online_devices': 2, 'total_devices': 3, 'subscription_status': 'active',
        'expire_time': '2026-11-30 00:00:00', 'remaining_days': 89,
      });
      expect(d.balance, 12.5);
      expect(d.hasSubscription, isTrue);
    });
  });

  group('国家识别扩充（南非/爱沙尼亚/沙特等）', () {
    String infer(String name) =>
        ProxyNode.fromClashMap({'name': name, 'server': 's', 'port': 1}).countryCode ?? 'XX';

    test('用户报告缺失的国家全部可识别', () {
      expect(infer('南非-约翰内斯堡 01'), 'ZA');
      expect(infer('爱沙尼亚 Tallinn'), 'EE');
      expect(infer('沙特阿拉伯-利雅得'), 'SA');
      expect(infer('匈牙利 Budapest'), 'HU');
      expect(infer('丹麦 Copenhagen 1'), 'DK');
      expect(infer('澳大利亚-墨尔本'), 'AU');
      expect(infer('奥地利 维也纳'), 'AT');
      expect(infer('哈萨克斯坦 Almaty'), 'KZ');
      expect(infer('柬埔寨-金边'), 'KH');
      expect(infer('以色列 Tel Aviv'), 'IL');
      expect(infer('EE-Tallinn-01'), 'EE');
      expect(infer('dk01.example'), 'DK');
    });

    test('子串歧义修复：印尼/内蒙古/ROMANIA/NO.x 编号', () {
      expect(infer('印度尼西亚 雅加达'), 'ID', reason: '不能被「印度」抢先命中');
      expect(infer('印度 孟买'), 'IN');
      expect(infer('内蒙古中转'), 'CN', reason: '不能命中「蒙古」');
      expect(infer('蒙古 乌兰巴托'), 'MN');
      expect(infer('ROMANIA-01'), 'RO', reason: '不能被子串 OMAN 抢先命中');
      expect(infer('OMAN Muscat'), 'OM');
      expect(infer('香港NO.1'), 'HK');
      expect(infer('IPLC NO.3 中转'), 'XX', reason: 'NO.x 编号不能误判为挪威');
      expect(infer('挪威 Oslo'), 'NO');
      expect(infer('AUSTRIA Vienna'), 'AT');
      expect(infer('AUSTRALIA Sydney'), 'AU');
      expect(infer('美国 AT&T 洛杉矶'), 'US', reason: 'AT&T 不能误判为奥地利');
      expect(infer('CN2 GIA 香港'), 'HK', reason: 'CN2 线路标注不参与国家码匹配');
    });

    test('排序：新国家分组稳定且未知恒最后', () {
      expect(ProxyNode.countryRank('DK') < ProxyNode.countryRank('ZA'), isTrue);
      expect(ProxyNode.countryRank('EE') < 200, isTrue, reason: '已列入排序表');
      expect(ProxyNode.countryRank('XX'), 999);
      // 合法但未收录的代码（如 AQ 南极洲）：按字母分组，仍在未知之前
      final aq = ProxyNode.countryRank('AQ');
      expect(aq >= 200 && aq < 999, isTrue);
    });

    test('旗帜按码计算，任意国家可用', () {
      expect(ProxyNode.flagEmoji('ZA'), '\u{1F1FF}\u{1F1E6}');
      expect(ProxyNode.flagEmoji('EE'), '\u{1F1EA}\u{1F1EA}');
      expect(ProxyNode.flagEmoji('XX'), '\u{1F310}');
      expect(ProxyNode.flagEmoji(null), '\u{1F310}');
      expect(ProxyNode.flagEmoji('1A'), '\u{1F310}');
    });
  });
}
