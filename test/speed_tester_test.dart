import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/services/speed_tester.dart';

ProxyNode _node(String type) =>
    ProxyNode(tag: 't', type: type, server: '127.0.0.1', port: 1);

void main() {
  test('isUdpOnly 识别 UDP-only 协议', () {
    expect(_node('hysteria').isUdpOnly, isTrue);
    expect(_node('hysteria2').isUdpOnly, isTrue);
    expect(_node('tuic').isUdpOnly, isTrue);
    expect(_node('wireguard').isUdpOnly, isTrue);
    expect(_node('ss').isUdpOnly, isFalse);
    expect(_node('ssr').isUdpOnly, isFalse);
    expect(_node('vless').isUdpOnly, isFalse);
    expect(_node('socks5').isUdpOnly, isFalse);
  });

  test('UDP 协议 testOne 直接返回 -1（不发起无意义的 TCP 连接）', () async {
    final tester = SpeedTester(connectTimeout: const Duration(milliseconds: 100));
    final ms = await tester.testOne(_node('hysteria2'));
    expect(ms, -1);
  });

  test('UDP 协议 testAll 保持 online=true（不误标离线，延迟留待内核实测）', () async {
    final tester = SpeedTester(connectTimeout: const Duration(milliseconds: 100));
    final res = await tester.testAll(
        [_node('hysteria2'), _node('tuic'), _node('wireguard')]);
    expect(res.every((n) => n.online), isTrue);
    expect(res.every((n) => n.latencyMs == -1), isTrue);
  });
}
