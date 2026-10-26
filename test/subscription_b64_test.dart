@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/singbox_config.dart';
import 'package:moneyfly/core/services/subscription_service.dart';

/// 订阅解析回归测试。
///
/// 这一组用例来自一次真实故障：用户反馈「订阅里的节点一个都测不了速」，
/// 排查发现整份订阅被解析成 **0 个节点**，且没有任何报错。三个独立缺陷：
///
/// 1. Dart 的 `base64.normalize` 遇到任何非 base64 字符（含换行/空格）
///    **直接抛 FormatException**（它只做 URL-safe 字母表归一化，不剥离空白），
///    而机场订阅响应体几乎都在末尾带 `\n`、长串还会按 76 字符折行 ——
///    异常被 `catch (_) {}` 吞掉后，代码拿 base64 原文逐行当链接解析，
///    全部落空 → 0 节点。
/// 2. `hy2://` 是 hysteria2 的通用简写，旧实现只认 `hysteria2://`，
///    整份订阅里的 hy2 节点被静默丢弃。
/// 3. 复用 hysteria2 解析器时按 `'hysteria2://'.length`(12) 切前缀去切
///    `hy2://` 的链接(6)，多切 6 个字符 → UUID 密码被截断，节点永远连不上。
void main() {
  // 节点字段一律用文档占位值（RFC 5737 198.51.100.0/24 + 假 UUID + 随机公钥）。
  // 这里曾是**真实机场订阅**的原文，公开仓库等于泄露凭据；
  // 回归防线见 test/no_test_node_data_test.dart —— 别再改回真实节点。
  //
  // pbk 为什么是「一串真随机数」而不是 EXAMPLE：内核**会校验** reality 公钥
  // 是否为合法 X25519 点，纯文本占位符会让「配置能被内核加载」那条用例直接失败
  // （invalid REALITY public key）。所以这里用一次性生成的公钥：格式合法、
  // 能让内核加载通过，但**不对应任何真实节点**（私钥已丢弃）。
  const kFakeRealityPbk = 'HQ_-6oB8xn2u6GDOAerqTuysOQFAvpA1FpiXG5H-ySI';
  const hy2 =
      'hy2://11111111-2222-3333-4444-777777777777@198.51.100.10:35000'
      '?sni=www.apple.com&insecure=0#%E6%96%B0%E5%8A%A0%E5%9D%A1-1';
  const vlessReality =
      'vless://11111111-2222-3333-4444-555555555555@198.51.100.20:443'
      '?security=reality&pbk=$kFakeRealityPbk&sid=00000000&fp=ios'
      '&flow=xtls-rprx-vision&type=tcp&sni=www.apple.com#%E7%BE%8E%E5%9B%BD-1';
  const vlessWs =
      'vless://11111111-2222-3333-4444-666666666666@node-d.example.com:443'
      '?security=tls&type=ws&path=%2Fws&host=cdn.example.com&sni=cdn.example.com'
      '#%E6%97%A5%E6%9C%AC-1';

  // 同一份订阅里 hy2:// 与 hysteria2:// 混用（面板很常见）：两种写法都必须认
  const hy2Long = 'hysteria2://11111111-2222-3333-4444-777777777777'
      '@198.51.100.30:60000?sni=www.apple.com&insecure=0#%E6%96%B0%E5%8A%A0%E5%9D%A1-2';
  final plain = [hy2, hy2Long, vlessReality, vlessWs].join('\n');
  String b64(String s) => base64.encode(utf8.encode(s));

  test('base64 订阅体末尾带换行时必须解出全部节点（核心回归）', () {
    // 机场响应体真实形态：一整行 base64 + 结尾换行
    final body = '${b64(plain)}\n';
    final nodes = SubscriptionService.parseBase64Nodes(body);
    expect(nodes.length, 4, reason: '末尾换行曾导致整份订阅解析成 0 节点');
    expect(nodes.where((n) => n.type == 'hysteria2').length, 2,
        reason: 'hy2:// 与 hysteria2:// 两种写法都要接受');
    expect(nodes.where((n) => n.type == 'vless').length, 2);
    // 走完整入口同样要正确（parseClashYaml 对非 YAML 文本回退到链接解析）
    expect(SubscriptionService.parseClashYaml(body).length, 4);
  });

  test('base64 折行 / 无填充 / CRLF 都要能解', () {
    final long = b64(plain);
    final wrapped = StringBuffer();
    for (var i = 0; i < long.length; i += 76) {
      wrapped.writeln(long.substring(i, (i + 76).clamp(0, long.length)));
    }
    expect(SubscriptionService.parseBase64Nodes(wrapped.toString()).length, 4,
        reason: '76 字符折行是面板导出常态');
    expect(SubscriptionService.parseBase64Nodes(long.replaceAll('=', '')).length,
        4, reason: '部分面板去掉 = 填充');
    expect(
        SubscriptionService.parseBase64Nodes('${b64(plain)}\r\n\r\n'.trim())
            .length,
        4);
    // 首尾空白 + BOM
    expect(SubscriptionService.parseBase64Nodes('\uFEFF ${b64(plain)} \n').length,
        4);
  });

  test('hy2:// 简写按 hysteria2 解析，且密码不被截断', () {
    final n = SubscriptionService.parseBase64Nodes(hy2).single;
    expect(n.type, 'hysteria2');
    expect(n.server, '198.51.100.10');
    expect(n.port, 35000);
    // 截断 bug 会得到 '11-2222-3333-4444-777777777777'（少了前 6 个字符）
    expect(n.raw['password'], '11111111-2222-3333-4444-777777777777');
    expect(n.password, '11111111-2222-3333-4444-777777777777');
    expect(n.sni, 'www.apple.com');
  });

  test('hy2:// 与 hysteria2:// 得到完全一致的节点', () {
    final short = SubscriptionService.parseBase64Nodes(hy2).single;
    final long = SubscriptionService.parseBase64Nodes(
            hy2.replaceFirst('hy2://', 'hysteria2://'))
        .single;
    expect(short.raw, long.raw);
  });

  test('vless reality 的 pbk/sid/flow 映射到内核字段', () {
    final n = SubscriptionService.parseBase64Nodes(vlessReality).single;
    expect(n.raw['tls'], true);
    expect(n.raw['reality-opts']['public-key'],
        kFakeRealityPbk);
    expect(n.raw['reality-opts']['short-id'], '00000000');
    expect(n.raw['client-fingerprint'], 'ios');
    expect(n.raw['flow'], 'xtls-rprx-vision');
  });

  test('base64(Clash YAML) 也要能解析', () {
    final yaml = 'proxies:\n'
        '  - {name: A, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p}\n'
        '  - {name: B, type: vless, server: 5.6.7.8, port: 443, uuid: u, tls: true}\n';
    expect(SubscriptionService.parseClashYaml('${b64(yaml)}\n').length, 2);
  });

  test('UDP+TLS 协议默认放宽证书校验，可关闭，且不影响 TCP 协议', () {
    final nodes = SubscriptionService.parseBase64Nodes(b64(plain));
    Map<String, dynamic> cfgFor({required bool relax}) =>
        SingBoxConfigBuilder.build(
          nodes: nodes,
          selectedTag: nodes.first.tag,
          smartMode: true,
          tunMode: 'off',
          clashApiSecret: 't',
          geoReady: false,
          udpSkipCertVerify: relax,
        );
    // sing-box 的节点出站都在 outbounds 里（selector/direct/block 之外）
    List<Map<String, dynamic>> outboundsOf(Map<String, dynamic> cfg, String type) =>
        (cfg['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .where((o) => o['type'] == type)
            .toList();
    // sing-box 把 mihomo 的 skip-cert-verify 映射到 tls.insecure
    bool insecure(Map<String, dynamic> outbound) {
      final tls = outbound['tls'];
      return tls is Map && tls['insecure'] == true;
    }

    final on = cfgFor(relax: true);
    final hy2All = outboundsOf(on, 'hysteria2');
    expect(hy2All, hasLength(2));
    expect(hy2All.every(insecure), isTrue,
        reason: 'hy2:// 与 hysteria2:// 都要放宽（伪装 SNI 证书不可能匹配）');
    expect(hy2All.map((o) => o['server']).toSet(),
        {'198.51.100.10', '198.51.100.30'});
    expect(outboundsOf(on, 'vless').every((o) => !insecure(o)), isTrue,
        reason: 'TCP+TLS 协议证书校验照旧，不得被顺手放宽');

    final off = cfgFor(relax: false);
    expect(outboundsOf(off, 'hysteria2').every((o) => !insecure(o)), isTrue);
  });

  test('生成的配置能被内核加载（有本地内核时）', () {
    final singbox = _findSingBox();
    if (singbox == null) {
      markTestSkipped(
          '未提供本地 sing-box 内核（MONEYFLY_SINGBOX / 仓库 .core_dl / PATH）');
      return;
    }
    final nodes = SubscriptionService.parseBase64Nodes('${b64(plain)}\n');
    final cfg = SingBoxConfigBuilder.build(
      nodes: nodes,
      selectedTag: nodes.first.tag,
      smartMode: true,
      tunMode: 'off',
      localPort: 27899,
      clashApiPort: 29099,
      clashApiSecret: 'secret',
      geoReady: false,
    );
    // 4 个节点各自有了 outbound（selector/direct/block 之外）
    final nodeOutbounds = (cfg['outbounds'] as List)
        .cast<Map<String, dynamic>>()
        .where((o) => !const {'selector', 'direct', 'block'}.contains(o['type']))
        .toList();
    expect(nodeOutbounds, hasLength(4));
    final tmp = Directory.systemTemp.createTempSync('mf_b64_');
    try {
      // sing-box 只认 JSON，且必须用 -c 显式指定（不会「静默用默认配置」）
      final configPath = '${tmp.path}/config.json';
      File(configPath).writeAsStringSync(SingBoxConfigBuilder.encode(cfg));
      // `check` = 解析 + 校验 + 初始化 router/outbound，等价于 mihomo -t
      final r = Process.runSync(singbox, ['check', '-c', configPath]);
      expect(r.exitCode, 0,
          reason: '内核必须接受配置: ${r.stdout}\n${r.stderr}');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}

/// 定位本地 sing-box 内核（MONEYFLY_SINGBOX / 旧变量 MONEYFLY_MIHOMO /
/// 仓库自带 .core_dl / build/sing-box / PATH）。
String? _findSingBox() {
  for (final key in ['MONEYFLY_SINGBOX', 'MONEYFLY_MIHOMO']) {
    final v = Platform.environment[key];
    if (v != null && v.isNotEmpty && File(v).existsSync()) return v;
  }
  final exe = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  final candidates = <String>[];
  for (final dir in [
    '${Directory.current.path}/.core_dl',
    '${Directory.current.path}/sing-box-bin',
    '${Directory.current.path}/build/sing-box',
  ]) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    candidates.add('$dir/$exe');
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
