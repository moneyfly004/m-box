import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/services/subscription_service.dart';

void main() {
  test('ss:// SIP002：base64(method:password)@host:port 正确解析 cipher/password', () {
    // 形态取自真实面板导出的 SIP002（aes-128-gcm）；主机/密码一律用文档地址占位，
    // 严禁把真实节点写进仓库（公开仓库 = 凭据泄露，见 test/no_test_node_data_test.dart）
    const ss =
        'ss://YWVzLTEyOC1nY206ZXhhbXBsZS1wYXNz@198.51.100.40:9910'
        '#example-tag';
    final nodes = SubscriptionService.parseBase64Nodes(ss);
    expect(nodes, hasLength(1));
    final n = nodes.first;
    expect(n.type, 'ss');
    expect(n.server, '198.51.100.40');
    expect(n.port, 9910);
    expect(n.cipher, 'aes-128-gcm');
    expect(n.password, 'example-pass');
    // raw 里也要有 cipher/password，供 mihomo 配置生成直接取用
    expect(n.raw['cipher'], 'aes-128-gcm');
    expect(n.raw['password'], 'example-pass');
  });

  test('ss:// legacy：整串 base64(method:password@host:port) 也能解析', () {
    final b64 = base64Encode(utf8.encode('aes-256-gcm:pwd123@1.2.3.4:8388'));
    // 标签按 URI 规范需百分号编码（真实订阅均如此）
    final nodes =
        SubscriptionService.parseBase64Nodes('ss://$b64#%E6%B5%8B%E8%AF%95');
    expect(nodes, hasLength(1));
    expect(nodes.first.tag, '测试');
    expect(nodes.first.cipher, 'aes-256-gcm');
    expect(nodes.first.password, 'pwd123');
    expect(nodes.first.server, '1.2.3.4');
    expect(nodes.first.port, 8388);
  });

  test('base64 包裹的 ss:// 列表（整文件形态）经 parseClashYaml 全部解析', () {
    const line =
        'ss://YWVzLTEyOC1nY206ZXhhbXBsZS1wYXNz@198.51.100.40:9910#A';
    final blob = base64Encode(utf8.encode('$line\n$line\n'));
    final nodes = SubscriptionService.parseClashYaml(blob);
    expect(nodes, hasLength(2));
    expect(nodes.every((n) => n.cipher == 'aes-128-gcm'), isTrue);
  });
}
