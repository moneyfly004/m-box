// TUN 配置生成（sing-box 版）：局域网在路由层排除。
//
// 背景：bypassLan 原本只在**规则层**给局域网写 DIRECT 规则，TUN 的 auto_route
// 仍然把局域网包先抓进虚拟网卡再靠规则绕回。对 NAS / 网络打印机 / mDNS、SSDP
// 局域网发现 / 局域网联机，多绕一跳会变慢甚至找不到设备。这里断言路由层排除
// （sing-box 的 `route_exclude_address`）与 bypassLan 语义一致，且不会被移动端
// （auto_route=false）误加。
//
// 与 mihomo 版的结构对照：`cfg['tun']` → `cfg['inbounds']` 里 `type=='tun'` 的项；
// mihomo 的 `route-exclude-address`/`dns-hijack`/`recvmsgx` 分别变成 sing-box 的
// `route_exclude_address` / 路由层 `{'protocol':'dns','action':'hijack-dns'}` 规则 /
// 不存在（sing-box 没有该字段）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/singbox_config.dart';

ProxyNode _node() => ProxyNode(
      tag: '测试节点',
      type: 'vless',
      server: '127.0.0.1',
      port: 9,
      uuid: '00000000-0000-0000-0000-000000000000',
      countryCode: 'HK',
      raw: const {},
    );

Map<String, dynamic> _build({
  String tunMode = 'off',
  bool bypassLan = true,
  bool tunAutoRoute = false,
  bool tunFdInjected = false,
  bool useMrsRuleSet = false,
  String? ruleSetDir,
  bool geoReady = true,
  String? clashApiSecret,
}) =>
    SingBoxConfigBuilder.build(
      nodes: [_node()],
      selectedTag: '测试节点',
      smartMode: true,
      tunMode: tunMode,
      bypassLan: bypassLan,
      tunAutoRoute: tunAutoRoute,
      tunFdInjected: tunFdInjected,
      useMrsRuleSet: useMrsRuleSet,
      ruleSetDir: ruleSetDir,
      geoReady: geoReady,
      clashApiSecret: clashApiSecret,
    );

/// `cfg['tun']` 的 sing-box 版：inbounds 里 type=='tun' 的入站
Map<String, dynamic>? _tun(Map<String, dynamic> cfg) {
  for (final ib in (cfg['inbounds'] as List).cast<Map<String, dynamic>>()) {
    if (ib['type'] == 'tun') return ib;
  }
  return null;
}

List<Map<String, dynamic>> _rules(Map<String, dynamic> cfg) =>
    ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _ruleSets(Map<String, dynamic> cfg) {
  final rs = (cfg['route'] as Map)['rule_set'];
  if (rs is! List) return const [];
  return rs.cast<Map<String, dynamic>>();
}

const _lanExcludes = [
  '127.0.0.0/8',
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '169.254.0.0/16',
  '224.0.0.0/4',
];

void main() {
  group('TUN 段生成', () {
    test('关闭时完全没有 tun 入站', () {
      final cfg = _build(tunMode: 'off');
      expect(_tun(cfg), isNull);
      expect((cfg['inbounds'] as List).cast<Map>().map((i) => i['type']),
          ['mixed']);
    });

    test('桌面 TUN（auto-route=true）+ bypassLan → 路由层排除局域网', () {
      final cfg = _build(tunMode: 'auto', tunAutoRoute: true);
      final tun = _tun(cfg)!;
      expect(tun['auto_route'], isTrue);
      expect(tun['address'], ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
      expect(tun['strict_route'], false);
      final excludes = (tun['route_exclude_address'] as List).cast<String>();
      expect(excludes, _lanExcludes);
      // 内核自己选出口网卡：TUN 开 auto_route 时必备（否则直连出站没网卡可用）
      expect((cfg['route'] as Map)['auto_detect_interface'], isTrue);
    });

    test('bypassLan=false（用户明确要局域网走代理）→ 不排除', () {
      final tun = _tun(_build(
          tunMode: 'force', bypassLan: false, tunAutoRoute: true))!;
      expect(tun.containsKey('route_exclude_address'), isFalse);
      expect(tun['auto_route'], isTrue);
    });

    test('移动端（auto-route=false，路由由系统下发）→ 不写排除项', () {
      final cfg = _build(tunMode: 'auto', tunAutoRoute: false);
      final tun = _tun(cfg)!;
      expect(tun.containsKey('route_exclude_address'), isFalse,
          reason: '移动端路由由 VpnService 全量下发，内核不碰路由表');
      // 但 DNS 劫持仍然要有（移动端 TUN 也要接管解析）：sing-box 把它放在路由层，
      // TUN 入站本身没有 dns_hijack / dns-hijack 键
      expect(_rules(cfg),
          anyElement(equals({'protocol': 'dns', 'action': 'hijack-dns'})));
      expect(tun.containsKey('dns_hijack'), isFalse);
      expect(tun.containsKey('dns-hijack'), isFalse);
    });

    test('force 模式与 auto 模式生成同构的 tun 段（差别在是否设系统代理）', () {
      final a = _tun(_build(tunMode: 'auto', tunAutoRoute: true))!;
      final f = _tun(_build(tunMode: 'force', tunAutoRoute: true))!;
      expect(f['auto_route'], a['auto_route']);
      expect(f['address'], a['address']);
      expect(f['mtu'], a['mtu']);
      expect(f['stack'], a['stack']);
      expect(f['route_exclude_address'], a['route_exclude_address']);
      // 差别：force 只走 TUN，不再监听系统代理端口；auto 两者并存
      final autoTypes =
          (_build(tunMode: 'auto', tunAutoRoute: true)['inbounds'] as List)
              .cast<Map>()
              .map((i) => i['type'])
              .toList();
      final forceTypes =
          (_build(tunMode: 'force', tunAutoRoute: true)['inbounds'] as List)
              .cast<Map>()
              .map((i) => i['type'])
              .toList();
      expect(autoTypes, ['mixed', 'tun']);
      expect(forceTypes, ['tun']);
    });
  });

  group('fd 注入（iOS socketpair 桥）的 MTU 对齐', () {
    // 真机根因（mihomo 时代）：iOS 16.4+ 的 NEPacketTunnelFlow 不再暴露 utun fd，
    // 客户端只能用 socketpair 自己造一个。mihomo 在 Darwin 上默认 recvmsgx=true，
    // 建 TUN 时会对 fd 做 utun 专属 setsockopt 直接失败；sing-box 没有 recvmsgx
    // 这个字段，Darwin 专属开关已不存在，这里只保留「MTU 与扩展下发的 1500 对齐」。
    test('fd 注入时 MTU 与扩展下发的 1500 对齐，且不含 mihomo 遗留的 recvmsgx', () {
      final cfg = _build(tunMode: 'auto', tunFdInjected: true);
      final tun = _tun(cfg)!;
      expect(tun['mtu'], 1500,
          reason: '不写 MTU 内核按默认 9000 生成报文，超过隧道 MTU 的包会被丢弃');
      expect(tun.containsKey('recvmsgx'), isFalse,
          reason: 'sing-box 没有 recvmsgx 字段，写了会被内核拒绝（unknown field）');
      // 声明的地址也要与 fd 注入形态一致（内核不自己建接口，只按声明配栈）
      expect(tun['address'], ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
      expect(tun['auto_route'], false);
    });

    test('非 fd 注入（Android / 桌面）用内核默认 MTU 9000', () {
      final cfg = _build(tunMode: 'auto', tunFdInjected: false);
      final tun = _tun(cfg)!;
      expect(tun['mtu'], 9000);
      expect(tun.containsKey('recvmsgx'), isFalse);
    });
  });

  // iOS 专用内存问题（mihomo 时代）：GEOSITE,cn 会用 succinct 匹配器把 11 万条域名
  // 建成内存索引，启动期一次申请约 74MB 堆，iOS 扩展内存上限只有几十 MB 会被系统
  // 杀掉。sing-box 1.12 起彻底移除了 legacy GEOSITE/GEOIP，国内分流一律走
  // **binary rule-set(.srs)**（zstd 直查、堆占用小），useMrsRuleSet 开关因此失去
  // 意义：产物恒定是 .srs，唯一变量是 ruleSetDir（绝对路径 or 内核 homeDir 相对路径）。
  group('国内直连规则集（.srs 取代 .mrs / GEOSITE）', () {
    test('目录为空串：用内核 homeDir 相对文件名，并声明 local/binary 规则集', () {
      final cfg = _build(tunMode: 'auto', tunFdInjected: true, ruleSetDir: '');
      // 规则引用规则集，且不再有任何 GEO/RULE-SET 文本规则
      expect(
          _rules(cfg),
          anyElement(equals(
              {'clash_mode': 'Rule', 'rule_set': ['geosite-cn'], 'outbound': 'direct'})));
      expect(
          _rules(cfg),
          anyElement(equals(
              {'clash_mode': 'Rule', 'rule_set': ['geoip-cn'], 'outbound': 'direct'})));
      expect(
          _rules(cfg).any((r) =>
              r.values.any((v) => v is String && v.contains('GEOSITE'))),
          isFalse);
      final rs = _ruleSets(cfg);
      expect(rs.map((r) => r['tag']).toList(), ['geosite-cn', 'geoip-cn']);
      expect(rs.map((r) => r['type']).toSet(), {'local'});
      expect(rs.map((r) => r['format']).toSet(), {'binary'});
      // 相对路径：扩展把 *.srs 放到自己的 homeDir，内核按 homeDir 解析
      expect(rs[0]['path'], 'geosite-cn.srs');
      expect(rs[1]['path'], 'geoip-cn.srs');
    });

    test('绝对目录：path 拼成 <dir>/<name>.srs', () {
      final cfg = _build(tunMode: 'auto', ruleSetDir: '/var/mf/rules');
      final rs = _ruleSets(cfg);
      expect(rs[0]['path'], '/var/mf/rules/geosite-cn.srs');
      expect(rs[1]['path'], '/var/mf/rules/geoip-cn.srs');
    });

    test('useMrsRuleSet 不再影响产物（.srs 恒定），默认不引用规则集', () {
      // 旧开关 true/false 生成的配置必须逐字节一致：sing-box 只有 .srs 一套
      // （固定 secret，否则每次 build 的随机 secret 会让两份配置天然不同）
      final on = _build(
          tunMode: 'auto',
          useMrsRuleSet: true,
          ruleSetDir: '/r',
          clashApiSecret: 'fixed-secret');
      final off = _build(
          tunMode: 'auto',
          useMrsRuleSet: false,
          ruleSetDir: '/r',
          clashApiSecret: 'fixed-secret');
      expect(jsonEncode(on), jsonEncode(off));
      expect(_ruleSets(on), isNotEmpty);

      // 没给 ruleSetDir（缺省 null）：不声明、也不引用规则集（离线 .srs 可能不存在）
      final plain = _build(tunMode: 'auto');
      expect((plain['route'] as Map).containsKey('rule_set'), isFalse);
      expect(_rules(plain).any((r) => r.containsKey('rule_set')), isFalse);
    });

    test('geoReady=false（离线数据缺失）时不写规则集，也不写国内直连规则', () {
      final cfg = _build(
          tunMode: 'auto', tunFdInjected: true, ruleSetDir: '/var/mf/rules',
          geoReady: false);
      expect((cfg['route'] as Map).containsKey('rule_set'), isFalse);
      expect(_rules(cfg).any((r) => r.containsKey('rule_set')), isFalse);
      expect(_rules(cfg).any((r) => r['outbound'] == 'direct' &&
          (r['clash_mode'] as String?) == 'Rule' &&
          r.containsKey('ip_cidr')), isTrue,
          reason: '规则集缺失也要保留回环/局域网直连与兜底 final=select');
      expect((cfg['route'] as Map)['final'], 'select');
    });
  });
}
