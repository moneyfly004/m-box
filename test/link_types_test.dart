@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/singbox_config.dart';
import 'package:mbox/core/services/subscription_service.dart';

/// 定位本地 sing-box 内核（真实内核校验用）：
/// MBOX_SINGBOX → 仓库自带 .core_dl → build/sing-box → PATH。
String? _findSingBox() {
  final injected = Platform.environment['MBOX_SINGBOX'];
  if (injected != null &&
      injected.isNotEmpty &&
      File(injected).existsSync()) {
    return injected;
  }
  final exe = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  // 仓库自带的开发内核（tool/fetch_singbox.sh 落地位置，按当前平台优先）
  final dirs = <Directory>[
    Directory('${Directory.current.path}/.core_dl'),
    Directory('${Directory.current.path}/sing-box-bin'),
    Directory('${Directory.current.path}/build/sing-box'),
  ];
  final candidates = <String>[];
  for (final d in dirs) {
    if (!d.existsSync()) continue;
    candidates.add('${d.path}/$exe');
    for (final sub in d.listSync().whereType<Directory>()) {
      candidates.add('${sub.path}/$exe');
    }
  }
  candidates.sort((a, b) {
    final am = a.contains(Platform.operatingSystem) ? 0 : 1;
    final bm = b.contains(Platform.operatingSystem) ? 0 : 1;
    return am != bm ? am - bm : a.compareTo(b);
  });
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  try {
    final r = Process.runSync('which', [exe],
        environment: {'PATH': Platform.environment['PATH'] ?? ''});
    final out = '${r.stdout}'.trim();
    if (r.exitCode == 0 && out.isNotEmpty && File(out).existsSync()) return out;
  } catch (_) {}
  return null;
}

/// 单节点配置 → 非「结构型」outbound（selector/direct/block 之外的节点出站）
List<Map<String, dynamic>> _nodeOutbounds(Map<String, dynamic> cfg) =>
    (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .where((o) => !const {'selector', 'direct', 'block'}.contains(o['type']))
        .toList();

void main() {
  ProxyNode one(String link) =>
      SubscriptionService.parseBase64Nodes(link).single;

  test('socks5:// base64(user:pass)@host:port', () {
    final n = one(
        'socks://ZXhhbXBsZS11c2VyOmV4YW1wbGUtcGFzcw@node-a.example.com:8001#%E5%B7%B4%E8%A5%BF');
    expect(n.type, 'socks5');
    expect(n.server, 'node-a.example.com');
    expect(n.port, 8001);
    expect(n.raw['username'], 'example-user');
    expect(n.raw['password'], 'example-pass');
  });

  test('vless:// TCP TLS Vision（uuid + flow + fingerprint）', () {
    final n = one(
        'vless://11111111-1111-4111-8111-111111111111@node-b.example.com:10031?encryption=none&flow=xtls-rprx-vision&security=tls&sni=node-b.example.com&fp=chrome&type=tcp#V');
    expect(n.type, 'vless');
    expect(n.uuid, '11111111-1111-4111-8111-111111111111');
    expect(n.raw['tls'], true);
    expect(n.raw['servername'], 'node-b.example.com');
    expect(n.raw['flow'], 'xtls-rprx-vision');
    expect(n.raw['client-fingerprint'], 'chrome');
  });

  test('vless:// WS（network + ws-opts）', () {
    final n = one(
        'vless://11111111-1111-4111-8111-111111111111@node-b.example.com:41827?security=tls&sni=node-b.example.com&type=ws&host=node-b.example.com&path=%2Ffgmiws#V');
    expect(n.raw['network'], 'ws');
    expect((n.raw['ws-opts'] as Map)['path'], '/fgmiws');
    expect(((n.raw['ws-opts'] as Map)['headers'] as Map)['Host'], 'node-b.example.com');
  });

  test('vless:// Reality Vision（reality-opts）', () {
    final n = one(
        'vless://11111111-1111-4111-8111-111111111111@node-b.example.com:12698?security=reality&sni=node-b.example.com&pbk=EXAMPLE_pbk_0000000000000000000000000000&sid=6ba85179e30d4fc2&type=tcp#VR');
    final ro = n.raw['reality-opts'] as Map;
    expect(ro['public-key'], 'EXAMPLE_pbk_0000000000000000000000000000');
    expect(ro['short-id'], '6ba85179e30d4fc2');
  });

  test('vless:// Reality gRPC（grpc-opts）', () {
    final n = one(
        'vless://11111111-1111-4111-8111-111111111111@node-b.example.com:20564?security=reality&sni=sni.example.com&pbk=EXAMPLE_pbk_0000000000000000000000000000&sid=6ba85179e30d4fc2&type=grpc&serviceName=grpc#VG');
    expect(n.raw['network'], 'grpc');
    expect((n.raw['grpc-opts'] as Map)['grpc-service-name'], 'grpc');
  });

  test('trojan://（password + sni + alpn）', () {
    final n = one(
        'trojan://11111111-1111-4111-8111-111111111111@node-b.example.com:29688?security=tls&sni=node-b.example.com&alpn=http%2F1.1&type=tcp#T');
    expect(n.type, 'trojan');
    expect(n.password, '11111111-1111-4111-8111-111111111111');
    expect(n.raw['sni'], 'node-b.example.com');
    expect(n.raw['alpn'], ['http/1.1']);
  });

  test('hysteria2://（password + sni）', () {
    final n = one(
        'hysteria2://11111111-1111-4111-8111-111111111111@node-b.example.com:40542?sni=node-b.example.com&insecure=0#H2');
    expect(n.type, 'hysteria2');
    expect(n.password, '11111111-1111-4111-8111-111111111111');
    expect(n.raw['sni'], 'node-b.example.com');
  });

  test('tuic://（uuid + password + alpn + congestion）', () {
    final n = one(
        'tuic://11111111-1111-4111-8111-111111111111%3A11111111-1111-4111-8111-111111111111@node-b.example.com:37667?sni=node-b.example.com&alpn=h3&congestion_control=cubic#TU');
    expect(n.type, 'tuic');
    expect(n.uuid, '11111111-1111-4111-8111-111111111111');
    expect(n.password, '11111111-1111-4111-8111-111111111111');
    expect(n.raw['alpn'], ['h3']);
    expect(n.raw['congestion-controller'], 'cubic');
  });

  test('anytls://（password + sni）', () {
    final n = one(
        'anytls://11111111-1111-4111-8111-111111111111@node-b.example.com:19160?security=tls&sni=node-b.example.com&type=tcp#A');
    expect(n.type, 'anytls');
    expect(n.password, '11111111-1111-4111-8111-111111111111');
    expect(n.raw['sni'], 'node-b.example.com');
  });

  test('vmess:// 生成标准 map（不再有 type=none 冲突）', () {
    const vm = 'vmess://ewogICJ2IjogIjIiLAogICJwcyI6ICJ0IiwKICAiYWRkIjogIm5vZGUtYi5leGFtcGxlLmNvbSIsCiAgInBvcnQiOiAiMTgyODkiLAogICJpZCI6ICIxMTExMTExMSIsCiAgImFpZCI6ICIwIiwKICAic2N5IjogImF1dG8iLAogICJuZXQiOiAid3MiLAogICJ0eXBlIjogIm5vbmUiLAogICJob3N0IjogIm5vZGUtYi5leGFtcGxlLmNvbSIsCiAgInBhdGgiOiAiL3pmb3UiLAogICJ0bHMiOiAidGxzIiwKICAic25pIjogIm5vZGUtYi5leGFtcGxlLmNvbSIKfQ==';
    final n = one(vm);
    expect(n.type, 'vmess');
    expect(n.raw['type'], 'vmess'); // 关键：不是 none
    expect(n.raw['server'], 'node-b.example.com');
    expect(n.raw['uuid'], '11111111');
    expect(n.raw['network'], 'ws');
    expect((n.raw['ws-opts'] as Map)['path'], '/zfou');
  });

  test('ssr://（base64url 主体 + obfsparam/remarks）', () {
    final n = one(
        'ssr://bm9kZS1jLmV4YW1wbGUuY29tOjgzMDI6b3JpZ2luOmNoYWNoYTIwLWlldGY6aHR0cF9zaW1wbGU6Y0dGemMzZGsvP29iZnNwYXJhbT1iMkptY3k1bGVHRnRjR3hsTG1OdmJRJnByb3RvcGFyYW09JnJlbWFya3M9NXJXTDZLLVY2SXFDNTRLNSZncm91cD01NlM2NUw2TA');
    expect(n.type, 'ssr');
    expect(n.tag, '测试节点');
    expect(n.server, 'node-c.example.com');
    expect(n.port, 8302);
    expect(n.cipher, 'chacha20-ietf');
    expect(n.password, 'passwd');
    expect(n.raw['protocol'], 'origin');
    expect(n.raw['obfs'], 'http_simple');
    expect(n.raw['obfs-param'], 'obfs.example.com');
  });

  test('hysteria:// v1（auth 在 query，无 userinfo）', () {
    final n = one(
        'hysteria://1.2.3.4:443?auth=pwd123&peer=example.com&insecure=1&upmbps=10&downmbps=50&obfs=xplus&obfsParam=obfspwd#H1');
    expect(n.type, 'hysteria');
    expect(n.password, 'pwd123');
    expect(n.raw['sni'], 'example.com');
    expect(n.raw['obfs'], 'xplus');
    expect(n.raw['obfs-param'], 'obfspwd');
    expect(n.raw['up'], 10);
    expect(n.raw['down'], 50);
  });

  test('wireguard://（base64 .conf）', () {
    final conf = base64Encode(utf8.encode(
        '[Interface]\nPrivateKey = pk\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = pubk\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n'));
    final n = one('wireguard://$conf#WG');
    expect(n.type, 'wireguard');
    expect(n.server, '1.2.3.4');
    expect(n.port, 51820);
    expect(n.raw['private-key'], 'pk');
    expect(n.raw['public-key'], 'pubk');
    expect(n.raw['ip'], '10.0.0.2/32');
  });

  test('所有类型都能生成 sing-box outbound（不崩溃、type 正确）', () {
    const links = [
      'socks://ZXhhbXBsZS11c2VyOmV4YW1wbGUtcGFzcw@node-a.example.com:8001#s1',
      'vless://11111111-1111-4111-8111-111111111111@h:10031?security=tls&sni=h#v1',
      'trojan://pwd@h:29688?security=tls&sni=h#t1',
      'hysteria2://pwd@h:40542?sni=h#h1',
      'tuic://11111111-1111-4111-8111-111111111111%3A11111111-1111-4111-8111-111111111111@h:37667?alpn=h3#tu1',
      'anytls://pwd@h:19160?security=tls&sni=h#a1',
    ];
    final nodes = [
      for (final l in links) SubscriptionService.parseBase64Nodes(l).single,
    ];
    final cfg = SingBoxConfigBuilder.build(
        nodes: nodes,
        selectedTag: nodes.first.tag,
        smartMode: true,
        geoReady: false);
    final outbounds = _nodeOutbounds(cfg);
    // Clash 协议名 → sing-box outbound type（socks5 → socks，其余同名）
    expect(outbounds.map((o) => o['type']).toList(),
        ['socks', 'vless', 'trojan', 'hysteria2', 'tuic', 'anytls']);
    // 每个节点都真的成了 outbound（不是被静默丢掉）
    expect(outbounds.map((o) => o['tag']).toList(),
        ['s1', 'v1', 't1', 'h1', 'tu1', 'a1']);
    // select 选择器包含全部节点 + direct
    final selector = (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['type'] == 'selector');
    expect(selector['outbounds'], containsAll(['s1', 'v1', 't1', 'h1', 'tu1', 'a1', 'direct']));
    // 产物是合法 JSON（写盘用 encode），且元数据键被剥离
    final decoded = jsonDecode(SingBoxConfigBuilder.encode(cfg)) as Map;
    expect((decoded['outbounds'] as List).length, outbounds.length + 3); // +selector+direct+block
    expect(decoded.keys.where((k) => '$k'.startsWith('_')), isEmpty);
  });

  test('hysteria v1 节点被跳过（sing-box 只有 hysteria2，没有 v1）', () {
    // 解析层照旧识别 hysteria v1（历史订阅里存在，不能抛错），
    // 但生成层必须跳过它：sing-box 1.x 没有 hysteria v1 outbound。
    final v1 = one(
        'hysteria://1.2.3.4:443?auth=pwd123&peer=example.com&upmbps=10&downmbps=50#H1');
    final h2 = one(
        'hysteria2://pwd@1.2.3.4:40542?sni=example.com#H2');
    expect(v1.type, 'hysteria');
    final cfg = SingBoxConfigBuilder.build(
        nodes: [v1, h2], selectedTag: h2.tag, smartMode: true, geoReady: false);
    final outbounds = _nodeOutbounds(cfg);
    expect(outbounds.map((o) => o['tag']).toList(), ['H2'],
        reason: 'hysteria v1 必须被跳过（否则内核不认识这个 outbound）');
    expect(outbounds.any((o) => o['type'] == 'hysteria'), isFalse);
    // select 组里也不能残留它的 tag（否则 UI 能选到、内核却连不上）
    final selector = (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['type'] == 'selector');
    expect(selector['outbounds'], isNot(contains('H1')));
  });

  // 真实内核校验（有本地 sing-box 时执行）
  final singbox = _findSingBox();
  final skip = singbox == null
      ? '未提供本地 sing-box 内核（MBOX_SINGBOX / 仓库 .core_dl / PATH）'
      : null;

  test('真实 sing-box check 校验多协议配置', skip: skip, () {
    final links = [
      'socks://ZXhhbXBsZS11c2VyOmV4YW1wbGUtcGFzcw@1.2.3.4:8001#s1',
      'ss://YWVzLTEyOC1nY206cGFzcw@1.2.3.4:8443#ss1',
      'vless://11111111-1111-4111-8111-111111111111@1.2.3.4:10031?security=tls&sni=example.com&type=tcp#v1',
      'trojan://pwd@1.2.3.4:29688?security=tls&sni=example.com#t1',
      'hysteria2://pwd@1.2.3.4:40542?sni=example.com#h1',
      'tuic://11111111-1111-4111-8111-111111111111%3A11111111-1111-4111-8111-111111111111@1.2.3.4:37667?alpn=h3#tu1',
      'anytls://pwd@1.2.3.4:19160?security=tls&sni=example.com#a1',
      // sing-box 不支持 hysteria v1：它被跳过，不该出现在配置里
      'hysteria://1.2.3.4:443?auth=pwd123&peer=example.com&upmbps=10&downmbps=50#h1v1',
    ];
    final nodes = [
      for (final l in links) SubscriptionService.parseBase64Nodes(l).single,
    ];
    final cfg = SingBoxConfigBuilder.build(
        nodes: nodes,
        selectedTag: nodes.first.tag,
        smartMode: true,
        geoReady: false);
    final outbounds = _nodeOutbounds(cfg);
    expect(outbounds.map((o) => o['type']).toList(),
        ['socks', 'shadowsocks', 'vless', 'trojan', 'hysteria2', 'tuic', 'anytls'],
        reason: 'hysteria v1 已被跳过，其余 7 种协议都要有 outbound');
    final tmp = Directory.systemTemp.createTempSync('mf_multi_check');
    try {
      File('${tmp.path}/config.json')
          .writeAsStringSync(SingBoxConfigBuilder.encode(cfg));
      final r = Process.runSync(singbox!, ['check', '-c', '${tmp.path}/config.json']);
      expect(r.exitCode, 0,
          reason: 'sing-box 必须接受多协议配置: ${r.stdout}\n${r.stderr}');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('ssr 节点被跳过（sing-box 1.6 起移除 ShadowsocksR 出站）', () {
    // 解析层照旧识别 ssr（历史订阅里大量存在，不能抛错），
    // 但生成层必须跳过：sing-box 1.14 见到 shadowsocksr outbound 会
    // `initialize outbound: ShadowsocksR is deprecated and removed` 拒绝**整份配置**。
    final ssr = one(
        'ssr://bm9kZS1jLmV4YW1wbGUuY29tOjgzMDI6b3JpZ2luOmNoYWNoYTIwLWlldGY6aHR0cF9zaW1wbGU6Y0dGemMzZGsvP29iZnNwYXJhbT1iMkptY3k1bGVHRnRjR3hsTG1OdmJRJnByb3RvcGFyYW09JnJlbWFya3M9NXJXTDZLLVY2SXFDNTRLNSZncm91cD01NlM2NUw2TA');
    expect(ssr.type, 'ssr'); // 解析层仍然认得
    expect(ssr.cipher, 'chacha20-ietf');
    final cfg = SingBoxConfigBuilder.build(
        nodes: [ssr], selectedTag: ssr.tag, smartMode: true, geoReady: false);
    final outbounds = _nodeOutbounds(cfg);
    expect(outbounds, isEmpty, reason: 'ssr 必须被跳过，不能生成内核拒绝的 shadowsocksr');
    expect(outbounds.any((o) => o['type'] == 'shadowsocksr'), isFalse);
    // select 组里也不能残留它的 tag（否则 UI 能选到、内核却起不来）
    final selector = (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['type'] == 'selector');
    expect(selector['outbounds'], ['direct']);
  });

  test('真实 sing-box check 校验 wireguard 映射（endpoint 形态）', skip: skip, () {
    // sing-box 1.11+：wireguard 是**顶层 endpoint**（endpoints[]），字段为
    // address / private_key / peers[{address, port, public_key, allowed_ips}]；
    // 写成普通 outbound（或带顶层 server/server_port）会让内核直接 FATAL。
    final wgConf = base64Encode(utf8.encode(
        '[Interface]\nPrivateKey = WZKDPOtKaVbPxSh8LWj5dsUzNk67OgOGPFFZ6EyLPok=\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = WjkI3yw1nhgeRwH7guNCAoFBrDlrg7BhQgtAGAmd+K4=\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n'));
    final wg = one('wireguard://$wgConf#wg1');
    final cfg = SingBoxConfigBuilder.build(
        nodes: [wg], selectedTag: wg.tag, smartMode: true, geoReady: false);

    // 结构：wireguard 只能出现在 endpoints，不能混进出站
    expect(_nodeOutbounds(cfg), isEmpty, reason: 'wireguard 不能作为 outbound');
    final eps = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
    final wgEp = eps.single;
    expect(wgEp['type'], 'wireguard');
    expect(wgEp['private_key'], 'WZKDPOtKaVbPxSh8LWj5dsUzNk67OgOGPFFZ6EyLPok=');
    final peers = (wgEp['peers'] as List).cast<Map>();
    expect(peers.single['address'], '1.2.3.4', reason: 'peer 地址字段名是 address');
    expect(peers.single['port'], 51820);
    expect(peers.single['public_key'], 'WjkI3yw1nhgeRwH7guNCAoFBrDlrg7BhQgtAGAmd+K4=');
    expect(peers.single['allowed_ips'], contains('0.0.0.0/0'));
    // 本地地址来自 wireguard:// 的 ip= 参数（raw['ip']）
    expect(wgEp['address'], ['10.0.0.2/32']);
    expect(wgEp.containsKey('server'), isFalse);
    expect(wgEp.containsKey('server_port'), isFalse);
    // select 组仍可指向 endpoint 的 tag
    final selector = (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['type'] == 'selector');
    expect(selector['outbounds'], contains('wg1'));

    // 内核侧：真实 sing-box check 必须通过
    final tmp = Directory.systemTemp.createTempSync('mf_wg');
    try {
      File('${tmp.path}/config.json')
          .writeAsStringSync(SingBoxConfigBuilder.encode(cfg));
      final r = Process.runSync(singbox!, ['check', '-c', '${tmp.path}/config.json']);
      final msg = '${r.stdout}${r.stderr}';
      expect(r.exitCode, 0, reason: 'sing-box 校验失败: $msg');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
