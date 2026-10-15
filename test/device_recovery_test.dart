import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/subscription_service.dart';

/// 用户实测场景（账号 454487210）：设备上限 1 台时第 2 台被拒 →
/// 客户端进入"设备已满"状态；管理员随后把上限改成 500，客户端必须能**自动跟随**
/// 后台设置：重新拉到订阅与状态、恢复连接，而不是一直停在"升级/删除设备"。
///
/// 这条用例把整条恢复链路钉住：
///   ① 被拒时 deviceRejected=true、isConnectionBlocked=true；
///   ② 后台放宽后，即使**不**带 force（不等 60 秒），受限状态也要重新拉账号信息；
///   ③ 拿到"本机在范围内"的信息后立刻清掉粘滞的拒绝标记；
///   ④ 节点缓存也不拦：立刻重新拿到真实节点。

/// 面板在"超限被拒"时下发的 4 个消息节点（与 generateErrorNodes 同形）
const _rejectionPayload = '''
proxies:
  - {name: "📢 官网: https://dy.moneyfly.top", server: baidu.com, port: 1234, type: ss, password: info, cipher: aes-128-gcm}
  - {name: "❌ 原因: 设备数量超限", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
  - {name: "💡 解决: 当前设备 2/1，请在官网删除不使用的设备", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
  - {name: "💬 客服: 3219904322", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
''';

const _normalPayload = '''
proxies:
  - {name: "香港-1", server: 198.51.100.10, port: 443, type: ss, password: pw, cipher: aes-128-gcm}
''';

/// 可切换状态的假后端：先模拟"上限 1 被拒"，改上限后再模拟"上限 500 正常"
class _FakeBackend implements HttpClientAdapter {
  _FakeBackend({required this.limit, required this.current, required this.subscribeBody});

  int limit;
  int current;
  String subscribeBody;
  int subscribeCalls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    final uri = options.uri;
    Map<String, dynamic> envelope(dynamic data) =>
        {'success': true, 'code': 0, 'message': '', 'data': data};
    ResponseBody json(Object body) => ResponseBody.fromString(jsonEncode(body), 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});

    if (uri.path.endsWith('/user/subscribe')) {
      return json(envelope({
        'subscribe_url':
            'https://dy.moneyfly.top/api/v1/client/subscribe?token=t&type=clash',
        'expire_time': '2032-06-06 08:00:00',
        'device_limit': limit,
        'current_devices': current,
        'remaining_days': 2000,
        'is_expired': false,
        'status': 'active',
      }));
    }
    if (uri.path.contains('/client/subscribe')) {
      subscribeCalls++;
      return ResponseBody.fromString(subscribeBody, 200,
          headers: {Headers.contentTypeHeader: ['text/plain']});
    }
    return json(envelope(null));
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  test('上限从 1 改成 500 后：状态自动跟随、拒绝标记清除、重新拿到真实节点',
      () async {
    final backend = _FakeBackend(
        limit: 1, current: 1, subscribeBody: _rejectionPayload);
    ApiClient.debugDio = Dio()..httpClientAdapter = backend;

    final acc = AccountService.instance;
    await acc.refresh(force: true);
    expect(acc.status, AccountStatus.deviceFull, reason: '上限 1、已用 1 → 设备满');

    final nodes = await SubscriptionService.instance.fetchNodes(force: true);
    expect(nodes, isEmpty, reason: '超限时只下发了消息节点，过滤后没有可连接节点');
    expect(SubscriptionService.instance.deviceRejected, isTrue);
    expect(acc.isConnectionBlocked, isTrue, reason: '被后端拒绝 → 不允许连接');

    // ——— 管理员在后台把上限改成 500（订阅没变，只有上限变了）———
    backend.limit = 500;
    backend.current = 1;
    backend.subscribeBody = _normalPayload;

    // 关键：不带 force 也要重取（受限状态不吃会话缓存，无需等 60 秒）
    await acc.refresh();
    expect(acc.status, AccountStatus.ok, reason: '上限放宽后状态要跟着后台变');
    expect(acc.sub?.deviceLimit, 500, reason: '客户端要显示后台的真实上限');
    expect(SubscriptionService.instance.deviceRejected, isFalse,
        reason: '本机已在范围内，粘滞的"被拒绝"标记必须清掉');
    expect(acc.isConnectionBlocked, isFalse, reason: '恢复后必须允许连接');

    // 节点缓存也不能拦住恢复（被拒状态下不吃 30 分钟缓存）
    final fresh = await SubscriptionService.instance.fetchNodes();
    expect(fresh.any((n) => n.server == '198.51.100.10'), isTrue,
        reason: '恢复后要能重新拉到真实节点');
  });
}
