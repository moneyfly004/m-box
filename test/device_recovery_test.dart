import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/subscription_cache.dart';
import 'package:moneyfly/core/services/subscription_service.dart';

/// 用户实测（账号 454487210 / henry11）暴露的两类"永久卡住"问题：
///
/// ① 后台把设备上限从 1 改成 500 后，客户端一直停在"升级/删除设备"、无法更新订阅；
/// ② 能访问 API 域名，但**拉节点的订阅域名在其网络不可达** → 客户端此前会静默
///    回退到磁盘缓存里的旧内容（正好是早先 limit=0 时下发的「设备数量超限」拒绝
///    载荷）→ 永久显示超限/无法拉取，而服务端根本收不到任何拉取请求。
///
/// 这三条用例把恢复链路钉住。

/// 面板在"超限被拒"时下发的 4 个消息节点（与 generateErrorNodes 同形）
const _rejectionPayload = '''
proxies:
  - {name: "官网提示", server: baidu.com, port: 1234, type: ss, password: info, cipher: aes-128-gcm}
  - {name: "❌ 原因: 设备数量超限", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
  - {name: "💡 解决: 当前设备 2/1，请在官网删除不使用的设备", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
  - {name: "💬 客服: 3219904322", server: baidu.com, port: 1234, type: ss, password: error, cipher: aes-128-gcm}
''';

const _normalPayload = '''
proxies:
  - {name: "香港-1", server: 198.51.100.10, port: 443, type: ss, password: pw, cipher: aes-128-gcm}
''';

Map<String, dynamic> _envelope(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

ResponseBody _jsonBody(Object body) => ResponseBody.fromString(
    jsonEncode(body), 200,
    headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});

/// 可切换状态的假后端：先模拟"上限 1 被拒"，改上限后再模拟"上限 500 正常"
class _FakeBackend implements HttpClientAdapter {
  _FakeBackend(
      {required this.limit, required this.current, required this.subscribeBody});

  int limit;
  int current;
  String subscribeBody;
  int subscribeCalls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final uri = options.uri;
    if (uri.path.endsWith('/user/subscribe')) {
      return _jsonBody(_envelope({
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
    return _jsonBody(_envelope(null));
  }

  @override
  void close({bool force = false}) {}
}

/// 账号接口正常，但**订阅地址**全部不可达的假后端（客户 henry11 的真实情形）
class _SubscribeUrlUnreachableBackend implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.uri.path.endsWith('/user/subscribe')) {
      return _jsonBody(_envelope({
        'subscribe_url':
            'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?token=t&type=clash',
        'subscribe_urls': [
          'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?token=t&type=clash',
          'https://moneyfly.dpdns.org/api/v1/client/subscribe?token=t&type=clash',
        ],
        'expire_time': '2032-06-06 08:00:00',
        'device_limit': 5,
        'current_devices': 1,
        'remaining_days': 2000,
        'is_expired': false,
        'status': 'active',
      }));
    }
    throw DioException.connectionError(
        requestOptions: options, reason: '测试注入：订阅地址不可达');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SubscriptionCache.instance.clear();
    SubscriptionService.instance.deviceRejected = false;
  });
  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  test('上限从 1 改成 500 后：状态自动跟随、拒绝标记清除、重新拿到真实节点',
      () async {
    final backend =
        _FakeBackend(limit: 1, current: 1, subscribeBody: _rejectionPayload);
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

  test('拒绝载荷不写磁盘缓存（否则会成为"回退内容"永久卡住用户）', () async {
    ApiClient.debugDio = Dio()
      ..httpClientAdapter =
          _FakeBackend(limit: 5, current: 1, subscribeBody: _rejectionPayload);

    final nodes = await SubscriptionService.instance.fetchNodes(force: true);
    expect(nodes, isEmpty);
    expect(SubscriptionService.instance.deviceRejected, isTrue);

    final cached = await SubscriptionCache.instance.readLatest();
    expect(
        cached == null ||
            SubscriptionService.rejectionReasonFromRaw(cached.raw) == null,
        isTrue,
        reason: '拒绝载荷只是"此刻被拒"的快照；写进磁盘后一旦订阅域名不可达，'
            '就会被当成内容回退，用户永久停在超限提示');
  });

  test('订阅地址在其网络全部不可达时：如实报错（不静默回退旧内容）', () async {
    ApiClient.debugDio = Dio()
      ..httpClientAdapter = _SubscribeUrlUnreachableBackend();

    Object? err;
    List<Object?>? got;
    try {
      got = await SubscriptionService.instance.fetchNodes(force: true);
    } catch (e) {
      err = e;
    }
    expect(err, isNotNull, reason: '所有订阅地址失败时应如实报错，供 UI 提示 + 自动重试');
    expect(got, isNull, reason: '不能返回空列表装作"没有节点"');
    expect(SubscriptionService.instance.lastIssue, SubscribeIssue.network,
        reason: '应归类为网络问题');
  });
}
