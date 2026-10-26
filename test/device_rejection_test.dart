import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/subscription_service.dart';
import 'package:mbox/l10n/app_strings.dart';

/// 后端「拒绝载荷」识别 + 连接门禁的回归测试。
///
/// 背景（用户实测反馈）：上限设成 N 台时，**范围内的第 N 台**更新订阅后点连接
/// 提示"要升级设备"且连不上。根因是客户端把"当前设备数 ≥ 上限"直接当成
/// "本机被拒绝"，而该条件对范围内的第 N 台同样成立。
///
/// 后端真正拒绝某台设备时的响应形态是**固定的 4 个消息节点**（面板
/// generateErrorNodes），其中 `❌ 原因:` 写明原因（超限时=设备数量超限），
/// server 一律是 baidu.com:1234。客户端必须只认这个"拒绝载荷"。
///
/// 上限值一律取后端设置（这里用 5/7 等不同数字，证明没有写死的 5）。

/// 面板拒绝载荷（与 internal/services/config_update 的 generateErrorNodes 同形）
String _rejectionPayload({String reason = '设备数量超限', String solution = '当前设备 6/5，请在官网删除不使用的设备'}) => '''
proxies:
  - {name: "📢 官网: https://dy.moneyfly.top", server: baidu.com, port: 1234, type: ss, password: info, cipher: aes-128-gcm}
  - {name: "❌ 原因: $reason", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
  - {name: "💡 解决: $solution", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
  - {name: "💬 客服: 请在系统设置中配置", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
''';

/// 正常订阅：真实节点 + 信息节点（面板 addInfoNodes）
String _normalPayload() => '''
proxies:
  - {name: "📢 官网: https://dy.moneyfly.top", server: baidu.com, port: 1234, type: ss, password: info, cipher: aes-128-gcm}
  - {name: "到期: 2027-01-01", server: baidu.com, port: 1234, type: ss, password: info, cipher: aes-128-gcm}
  - {name: "香港-1", server: 198.51.100.10, port: 443, type: ss, password: pw, cipher: aes-128-gcm}
''';

void main() {
  // 这些用例会动 AccountService / SubscriptionService 的单例状态：
  // 每条前后都复位，避免"上一条把 deviceRejected 置真"影响下一条
  setUp(() {
    AccountService.instance.reset();
    SubscriptionService.instance.deviceRejected = false;
  });
  tearDown(() {
    AccountService.instance.reset();
    SubscriptionService.instance.deviceRejected = false;
  });

  group('拒绝载荷识别', () {
    test('面板超限载荷 → 原因=设备数量超限，归类 deviceFull', () {
      final raw = _rejectionPayload();
      // 解析器会过滤掉 baidu.com 消息节点 → 解析结果为空（用户点不到假节点）
      final nodes = SubscriptionService.parseClashYaml(raw);
      expect(nodes, isEmpty, reason: '假节点不该进入可连接列表');
      // 所以拒绝原因必须从**订阅原文**里认
      final reason = SubscriptionService.rejectionReasonFromRaw(raw);
      expect(reason, '设备数量超限');
      expect(SubscriptionService.issueFromRejectionReason(reason!),
          SubscribeIssue.deviceFull);
      expect(SubscriptionService.connectableNodes(nodes, reason), isEmpty,
          reason: '拒绝载荷里不能留下假节点给用户点');
    });

    test('正常订阅（真实节点 + 信息节点）→ 无拒绝原因，节点原样保留', () {
      final raw = _normalPayload();
      expect(SubscriptionService.rejectionReasonFromRaw(raw), isNull);
      final nodes = SubscriptionService.parseClashYaml(raw);
      expect(SubscriptionService.connectableNodes(nodes, null), hasLength(1),
          reason: '解析只剩真实节点（信息节点已被解析器过滤）');
      // 真实节点必须还在
      expect(nodes.any((n) => n.server == '198.51.100.10'), isTrue);
    });

    test('其它拒绝原因 → 对应分类（到期/失效/地址变更）', () {
      SubscribeIssue issueOf(String reason) =>
          SubscriptionService.issueFromRejectionReason(reason);
      expect(issueOf('订阅已过期'), SubscribeIssue.expired);
      expect(issueOf('订阅已失效'), SubscribeIssue.subscriptionDisabled);
      expect(issueOf('订阅地址已变更'), SubscribeIssue.noSubscribeUrl);
    });
  });

  group('连接门禁：设备满只是提示，被拒绝才阻断', () {
    SubscriptionInfo sub({required int limit, required int current}) =>
        SubscriptionInfo(
          subscribeUrl: 'https://x/client/subscribe?token=t&type=clash',
          expireTime: DateTime.now().add(const Duration(days: 30)),
          deviceLimit: limit,
          currentDevices: current,
          remainingDays: 30,
          isExpired: false,
          status: 'active',
          isActive: true,
        );

    test('上限 5、当前 5（范围内的第 5 台）→ 不阻断连接，但要有提示', () {
      final s = sub(limit: 5, current: 5);
      final svc = AccountService.instance..reset();
      svc.sub = s;
      svc.status = AccountService.classify(s);
      SubscriptionService.instance.deviceRejected = false; // 拿到真实节点
      expect(svc.status, AccountStatus.deviceFull, reason: '保留提示状态');
      expect(svc.needsAttention, isTrue, reason: '首页横幅要提示可升级设备');
      expect(svc.isConnectionBlocked, isFalse, reason: '范围内的设备必须能连');
    });

    test('上限 7、当前 7，但后端下发了拒绝载荷（第 8 台）→ 阻断并引导升级', () {
      final s = sub(limit: 7, current: 8);
      final svc = AccountService.instance..reset();
      svc.sub = s;
      svc.status = AccountService.classify(s);
      SubscriptionService.instance.deviceRejected = true; // 后端确实拒绝
      expect(svc.isConnectionBlocked, isTrue, reason: '超限设备必须拒绝连接');
      expect(svc.blockText, contains('设备数量已达上限'));
    });

    test('上限 0（该订阅未开放设备使用）→ 提示联系客服，而非删设备/升级名额', () {
      // 上限 0 的账号 classify 不会判成 deviceFull（禁止来自后端的拒绝载荷），
      // 因此文案要在展示拒绝提示的地方区分：见 SubscribeIssueView._title/_body
      final s = sub(limit: 0, current: 0);
      final svc = AccountService.instance..reset();
      svc.sub = s;
      svc.status = AccountService.classify(s);
      expect(svc.blockTitle, isNot('设备数量已达上限'));
      expect(AppStrings.t('device_zero_title'), '该订阅未开放设备使用');
      expect(AppStrings.t('device_zero_block'), contains('联系客服'));
    });

    test('上限取后端设置值：同一个账号换上限，判定跟着变', () {
      final svc = AccountService.instance..reset();
      SubscriptionService.instance.deviceRejected = false;
      for (final limit in [3, 5, 10]) {
        final under = sub(limit: limit, current: limit - 1);
        svc.sub = under;
        svc.status = AccountService.classify(under);
        expect(AccountService.classify(under), AccountStatus.ok,
            reason: '上限 $limit 时第 ${limit - 1} 台应为正常');
        expect(svc.isConnectionBlocked, isFalse);
      }
    });
  });
}
