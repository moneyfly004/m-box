import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/proxy_core.dart';

/// 订阅定时/启动刷新结果接入（applySubscriptionNodes）行为测试：
/// 保证「覆盖旧节点配置」不会误伤正在使用的连接/正在建立的连接。
void main() {
  ProxyNode node(String tag, {int latencyMs = -1}) => ProxyNode(
        tag: tag,
        type: 'ss',
        server: '1.2.3.4',
        port: 8388,
        latencyMs: latencyMs,
        raw: const {'type': 'ss', 'server': '1.2.3.4', 'port': 8388},
      );

  tearDown(() {
    // 复位单例状态，避免污染其它用例
    final c = ConnectionController.instance;
    c.status = ConnStatus.disconnected;
    c.nodes = [];
    c.current = null;
  });

  test('断开状态：新订阅整体覆盖旧节点配置', () async {
    final c = ConnectionController.instance;
    c.nodes = [node('old-1'), node('old-2')];
    c.current = node('old-1');

    await c.applySubscriptionNodes([node('new-1'), node('new-2')]);

    expect(c.nodes.map((n) => n.tag), ['new-1', 'new-2']);
    expect(c.current, isNull); // 旧线路已不在新订阅中
  });

  test('已连接且当前线路仍在 → 列表整体替换为新订阅', () async {
    final c = ConnectionController.instance;
    c.status = ConnStatus.connected;
    c.nodes = [node('hk-1'), node('hk-2')];
    c.current = node('hk-1');

    await c.applySubscriptionNodes([node('hk-1'), node('jp-9')]);

    expect(c.nodes.map((n) => n.tag), ['hk-1', 'jp-9']);
    expect(c.current!.tag, 'hk-1'); // 当前线路保留
  });

  test('已连接但当前线路不在新订阅 → 保持现状不打断连接', () async {
    final c = ConnectionController.instance;
    c.status = ConnStatus.connected;
    c.nodes = [node('hk-old')];
    c.current = node('hk-old');

    await c.applySubscriptionNodes([node('jp-new')]);

    // 不替换：内核仍按旧配置运行，避免当前线路被误判离线/中断
    expect(c.nodes.map((n) => n.tag), ['hk-old']);
    expect(c.current!.tag, 'hk-old');
  });

  test('连接建立过程中（connecting）不动列表，避免与 connect 竞态', () async {
    final c = ConnectionController.instance;
    c.status = ConnStatus.connecting;
    c.nodes = [node('pick-me')];
    c.current = node('pick-me');

    await c.applySubscriptionNodes([node('other')]);

    expect(c.nodes.map((n) => n.tag), ['pick-me']);
  });

  test('空列表不覆盖（避免清空用户可用线路）', () async {
    final c = ConnectionController.instance;
    c.nodes = [node('a')];

    await c.applySubscriptionNodes([]);

    expect(c.nodes.map((n) => n.tag), ['a']);
  });

  test('订阅刷新后保留已测延迟（快捷国家/延迟徽标不因刷新消失）', () async {
    final c = ConnectionController.instance;
    c.nodes = [node('hk-1', latencyMs: 88), node('hk-2')];

    // 模拟 30 分钟定时/回前台静默刷新：返回重新解析的全新对象（无延迟）
    await c.applySubscriptionNodes([node('hk-1'), node('hk-2'), node('jp-9')]);

    final hk1 = c.nodes.firstWhere((n) => n.tag == 'hk-1');
    final hk2 = c.nodes.firstWhere((n) => n.tag == 'hk-2');
    final jp9 = c.nodes.firstWhere((n) => n.tag == 'jp-9');
    expect(hk1.latencyMs, 88); // 已测延迟被保留
    expect(hk2.latencyMs, -1); // 本来就未测 → 保持未测
    expect(jp9.latencyMs, -1); // 新节点未测
  });

  test('下拉刷新（loadNodes）同样保留已测延迟', () async {
    final c = ConnectionController.instance;
    c.nodes = [node('us-1', latencyMs: 120)];

    await c.loadNodes([node('us-1'), node('us-2')]);

    expect(c.nodes.firstWhere((n) => n.tag == 'us-1').latencyMs, 120);
    expect(c.nodes.firstWhere((n) => n.tag == 'us-2').latencyMs, -1);
  });

  test('节点自带新测速结果时不被旧延迟覆盖', () async {
    final c = ConnectionController.instance;
    c.nodes = [node('a', latencyMs: 300)]; // 旧延迟 300ms

    // 新列表同一 tag 已携带刚测的新值 45ms → 以新值为准
    await c.applySubscriptionNodes([node('a', latencyMs: 45)]);

    expect(c.nodes.firstWhere((n) => n.tag == 'a').latencyMs, 45);
  });
}
