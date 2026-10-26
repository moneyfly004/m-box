@Tags(['e2e'])
library;

// sing-box 配置生成器测试：JSON 结构断言 + （有本地内核时）真实内核 check 校验与 Clash API 行为验证。
//
// 与旧内核版的语义对照：
// - `cfg['tun']`              → `cfg['inbounds']` 里 `type=='tun'` 的那一项
// - `cfg['rules']`(List<Str>) → `cfg['route']['rules']`(有序 List<Map>)，用 `clash_mode`
//                               前缀区分「智能模式(Rule)」与「全局模式(Global)」两套规则
// - `cfg['proxies']`          → `cfg['outbounds']` 里 selector/direct/block 之外的项
// - `cfg['mixed-port']`       → mixed 入站的 `listen_port`
// - `external-controller`/`secret`/`mode` → `cfg['experimental']['clash_api']`
// - 旧内核的 `rule-providers`(.mrs) → sing-box 的 `route.rule_set`(.srs)
// - 旧内核内置的 GLOBAL 组 → sing-box 没有，全局模式靠 `clash_mode:'Global'` 规则 +
//   [select] 选择器实现（切节点仍是 PUT /proxies/select）
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/singbox_config.dart';

/// 定位本地 sing-box 二进制（MBOX_SINGBOX 或 .core_dl/ 随包下载的内核）
String? _localSingBox() {
  final env = Platform.environment['MBOX_SINGBOX'];
  if (env != null && env.trim().isNotEmpty && File(env).existsSync()) {
    return File(env).absolute.path;
  }
  for (final p in const [
    '.core_dl/sing-box-1.14.4-darwin-arm64/sing-box',
    '.core_dl/sing-box-1.14.4-darwin-amd64/sing-box',
    'sing-box-bin/sing-box',
    'build/sing-box/sing-box',
  ]) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}

/// 把仓库内置 .srs 规则集复制到临时内核目录。
/// sing-box 的 `rule_set` 用的是**离线二进制规则集**：文件缺失时 `check`/`run`
/// 直接 FATAL（不像旧内核会触发联网下载），所以真实内核用例要么不引用
/// 规则集（ruleSetDir=null），要么先把 assets/rules/*.srs 拷到临时目录。
/// 返回成功复制的文件名（空 = 仓库里没有内置规则集）。
List<String> _seedRuleSets(String dir) {
  final copied = <String>[];
  for (final n in const ['geosite-cn.srs', 'geoip-cn.srs']) {
    try {
      final src = File('${Directory.current.path}/assets/rules/$n');
      if (!src.existsSync()) continue; // 仓库无内置文件时由调用方降级
      src.copySync('$dir/$n');
      copied.add(n);
    } catch (_) {}
  }
  return copied;
}

/// Clash API 的响应不一定带 application/json（dio 会把它降级成 String），
/// 统一转成 Map 再做断言
Map<String, dynamic> _jsonMap(dynamic data) => data is String
    ? jsonDecode(data) as Map<String, dynamic>
    : data as Map<String, dynamic>;

/// 取一个空闲本地端口：真实内核用例不占固定 2080/9090，避免与其它测试互抢
Future<int> _freePort() async {
  final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = sock.port;
  await sock.close();
  return port >= 1024 ? port : _freePort();
}

// ===== sing-box 配置的读取小工具（按真实结构取值，避免走到旧内核的键上）=====

List<Map<String, dynamic>> _inbounds(Map<String, dynamic> cfg) =>
    (cfg['inbounds'] as List).cast<Map<String, dynamic>>();

/// `cfg['tun']` 的 sing-box 版：inbounds 里 type=='tun' 的入站，没有则 null
Map<String, dynamic>? _tunInbound(Map<String, dynamic> cfg) {
  for (final ib in _inbounds(cfg)) {
    if (ib['type'] == 'tun') return ib;
  }
  return null;
}

Map<String, dynamic>? _inboundByType(Map<String, dynamic> cfg, String type) {
  for (final ib in _inbounds(cfg)) {
    if (ib['type'] == type) return ib;
  }
  return null;
}

List<Map<String, dynamic>> _outbounds(Map<String, dynamic> cfg) =>
    (cfg['outbounds'] as List).cast<Map<String, dynamic>>();

/// `cfg['proxies']` 的 sing-box 版：selector/direct/block 之外的真实节点出站
List<Map<String, dynamic>> _nodeOutbounds(Map<String, dynamic> cfg) => _outbounds(cfg)
    .where((o) => !const {'selector', 'direct', 'block'}.contains(o['type']))
    .toList();

Map<String, dynamic> _selectGroup(Map<String, dynamic> cfg) =>
    _outbounds(cfg).firstWhere((o) => o['tag'] == 'select');

List<Map<String, dynamic>> _rules(Map<String, dynamic> cfg) =>
    ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _ruleSets(Map<String, dynamic> cfg) {
  final rs = (cfg['route'] as Map)['rule_set'];
  if (rs is! List) return const [];
  return rs.cast<Map<String, dynamic>>();
}

List<Map<String, dynamic>> _dnsServers(Map<String, dynamic> cfg) =>
    ((cfg['dns'] as Map)['servers'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _dnsRules(Map<String, dynamic> cfg) =>
    ((cfg['dns'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> _clashApi(Map<String, dynamic> cfg) =>
    (cfg['experimental'] as Map)['clash_api'] as Map<String, dynamic>;

const _lanCidrs = [
  '127.0.0.0/8',
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
];

void main() {
  ProxyNode mkNode(String type,
          {String tag = '', Map<String, dynamic> raw = const {}}) =>
      ProxyNode(
        tag: tag.isEmpty ? '$type-1' : tag,
        type: type,
        server: '1.2.3.4',
        port: 443,
        uuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        password: 'pass123',
        cipher: 'aes-128-gcm',
        tls: true,
        sni: 'sni.example.com',
        countryCode: 'HK',
        raw: raw,
      );

  final vlessNode = mkNode('vless');

  test('基础结构: 元数据/localPort/clash_api/mixed 入站/log', () {
    final cfg = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    // 元数据键（encode() 会剥离，仅进程内可见）
    expect(cfg['_tunMode'], 'off');
    expect(cfg['_localPort'], 2080);
    expect(cfg['_clashApiPort'], 9090);
    expect(cfg['_clashApiSecret'], isNotEmpty);
    expect((cfg['log'] as Map)['level'], 'warn');
    expect((cfg['log'] as Map)['timestamp'], isTrue);
    // Clash API：external-controller/secret/default_mode 全在 experimental.clash_api
    final api = _clashApi(cfg);
    expect(api['external_controller'], '127.0.0.1:9090');
    expect(api['secret'], cfg['_clashApiSecret'],
        reason: '元数据里的 secret 必须与配置文件里的一致，否则客户端拿不到控制权');
    expect(api['default_mode'], 'Rule');
    expect(((cfg['experimental'] as Map)['cache_file'] as Map)['enabled'], isFalse,
        reason: '移动端扩展容器空间有限，不把连接/规则状态写盘');
    // 系统代理指向 mixed 入站（sing-box 没有顶层的 mixed-port）
    final mixed = _inboundByType(cfg, 'mixed')!;
    expect(mixed['tag'], 'mixed-in');
    expect(mixed['listen'], '127.0.0.1');
    expect(mixed['listen_port'], 2080);
    expect(_outbounds(cfg), isA<List>());
    // logLevel 参数映射到 sing-box 的五档日志级别
    final quiet = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        logLevel: 'debug');
    expect((quiet['log'] as Map)['level'], 'debug');
  });

  test('encode(): 剥离 `_` 元数据键，产物是可被 jsonDecode 解析的 sing-box JSON', () {
    final cfg = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    final text = SingBoxConfigBuilder.encode(cfg);
    final parsed = jsonDecode(text) as Map<String, dynamic>;
    expect(parsed.keys.where((k) => k.startsWith('_')), isEmpty,
        reason: '元数据键仅供进程内使用，绝不能写进配置文件');
    expect(parsed.keys,
        containsAll(['log', 'dns', 'inbounds', 'outbounds', 'route', 'experimental']));
    expect(parsed.containsKey('tun'), isFalse, reason: 'sing-box 的 TUN 是入站，不是顶层段');
    expect(parsed.containsKey('mixed-port'), isFalse);
  });

  test('智能模式: default_mode=Rule + clash_mode=Rule 规则; 全局模式: default_mode=Global', () {
    final smart = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    final global = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: false);
    expect(_clashApi(smart)['default_mode'], 'Rule');
    expect(_clashApi(global)['default_mode'], 'Global');
    expect((smart['route'] as Map)['final'], 'select');
    expect((global['route'] as Map)['final'], 'select');

    final smartRules = _rules(smart);
    // 两套模式的规则同时存在：Clash API PATCH /configs 热切换时不重新生成配置
    expect(smartRules, anyElement(equals({'action': 'sniff'})));
    expect(smartRules,
        anyElement(equals({'protocol': 'dns', 'action': 'hijack-dns'})));
    expect(
        smartRules,
        anyElement(equals(
            {'clash_mode': 'Global', 'ip_cidr': _lanCidrs, 'outbound': 'direct'})));
    expect(smartRules,
        anyElement(equals({'clash_mode': 'Global', 'outbound': 'select'})));
    expect(
        smartRules,
        anyElement(equals(
            {'clash_mode': 'Rule', 'ip_cidr': _lanCidrs, 'outbound': 'direct'})));
    // 全局模式只是把 default_mode 换了，规则集是同构的（差别只在哪一套规则生效）
    expect(_rules(global), smartRules);

    // 全局模式的兜底：局域网/回环直连之后一切走代理（sing-box 没有 GLOBAL 组，
    // 出站仍是 [select]，用户改节点还是 PUT /proxies/select）
    final gi = _rules(global)
        .indexWhere((r) => r['clash_mode'] == 'Global' && r['outbound'] == 'select');
    expect(gi, greaterThan(0));
    expect(_rules(global)
            .indexWhere((r) => r['clash_mode'] == 'Global' && r['outbound'] == 'direct'),
        lessThan(gi),
        reason: '局域网直连必须排在「全局走代理」之前');
  });

  test('geoReady=false 时智能规则降级为全代理（geo 缺失也能起内核）', () {
    // ruleSetDir 给了但 geo 数据不可用：既不写 route.rule_set，也不写引用它的规则
    final cfg = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        geoReady: false,
        ruleSetDir: '/tmp/does-not-matter');
    expect((cfg['route'] as Map).containsKey('rule_set'), isFalse);
    expect(_ruleSets(cfg), isEmpty);
    final rules = _rules(cfg);
    expect(rules.any((r) => r.containsKey('rule_set')), isFalse,
        reason: '规则引用了不存在的规则集，sing-box 会直接启动失败');
    // 降级后仍有：嗅探 / DNS 劫持 / 局域网直连 / 兜底 final=select
    expect(
        rules,
        anyElement(equals(
            {'clash_mode': 'Rule', 'ip_cidr': _lanCidrs, 'outbound': 'direct'})));
    expect((cfg['route'] as Map)['final'], 'select');

    // 对照：geo 可用且给了规则集目录时，国内直连规则必须出现
    final geo = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        ruleSetDir: '/tmp/rules');
    expect(
        _rules(geo),
        anyElement(equals(
            {'clash_mode': 'Rule', 'rule_set': ['geosite-cn'], 'outbound': 'direct'})));
    expect(
        _rules(geo),
        anyElement(equals(
            {'clash_mode': 'Rule', 'rule_set': ['geoip-cn'], 'outbound': 'direct'})));
    expect(_ruleSets(geo).map((r) => r['tag']), ['geosite-cn', 'geoip-cn']);
  });

  test('默认不引用规则集（ruleSetDir 缺省为 null）→ 配置零外部依赖', () {
    final cfg = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect((cfg['route'] as Map).containsKey('rule_set'), isFalse,
        reason: '没给规则集目录时不能凭空引用 .srs（文件不存在内核会拒绝启动）');
    expect(_rules(cfg).any((r) => r.containsKey('rule_set')), isFalse);
  });

  test('select 组: 默认节点排首位 + default 键 + 成员不重复', () {
    final a = mkNode('vless', tag: 'A-node');
    final b = mkNode('ss', tag: 'B-node');
    final cfg = SingBoxConfigBuilder.build(
        nodes: [a, b], selectedTag: 'B-node', smartMode: true);
    final select = _selectGroup(cfg);
    expect(select['type'], 'selector');
    // 选中项放首位 + default：sing-box 重启后线路不丢
    expect((select['outbounds'] as List).first, 'B-node');
    expect(select['default'], 'B-node');
    // 完整成员: 默认节点 + 其余节点 + direct（无重复）
    final members = (select['outbounds'] as List).cast<String>();
    expect(members, ['B-node', 'A-node', 'direct']);
    expect(members.toSet().length, members.length, reason: '成员不得重复');
    // 出站顺序保持订阅顺序（selector 之外的节点出站）
    expect(_nodeOutbounds(cfg).map((o) => o['tag']).toList(), ['A-node', 'B-node']);
    // 选中的 tag 不存在时回落到第一个可用节点，不能生成空的 selector
    final fallback = SingBoxConfigBuilder.build(
        nodes: [a, b], selectedTag: '不存在', smartMode: true);
    expect(_selectGroup(fallback)['default'], 'A-node');
  });

  test('面板伪节点被过滤（server 空 / port 0）', () {
    final fake = ProxyNode(
        tag: '📢官网',
        type: 'vless',
        server: '',
        port: 0,
        countryCode: 'XX',
        raw: const {'name': '📢官网', 'type': 'vless'});
    final cfg = SingBoxConfigBuilder.build(
        nodes: [fake, vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect(_nodeOutbounds(cfg).length, 1);
    expect(_nodeOutbounds(cfg).single['tag'], vlessNode.tag);
    expect((_selectGroup(cfg)['outbounds'] as List), isNot(contains('📢官网')));
  });

  test('sing-box 不支持的协议被跳过（hysteria v1）', () {
    // sing-box 只有 hysteria2：hysteria v1 节点必须从出站里消失，不能生成内核拒绝的类型
    final hy1 = mkNode('hysteria');
    final cfg = SingBoxConfigBuilder.build(
        nodes: [hy1, vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect(_nodeOutbounds(cfg).map((o) => o['type']).toList(), ['vless']);
    expect(_outbounds(cfg).any((o) => o['type'] == 'hysteria'), isFalse);
    expect((_selectGroup(cfg)['outbounds'] as List), ['vless-1', 'direct']);
  });

  test('ssr 节点被跳过（sing-box 1.6 起删除 shadowsocksr 出站，留着会让整份配置被拒）', () {
    // 背景：sing-box ≥1.6 移除了 ssr 出站，若仍生成 type:"shadowsocksr"，
    // 真实内核会 FATAL 拒绝**整份配置**（不是单节点失效）：
    //   initialize outbound[N]: ShadowsocksR is deprecated and removed in sing-box 1.6.0
    // 因此生成器必须跳过它，且不能让它出现在 select 组里。
    final ssr = ProxyNode(
      tag: 'ssr-1',
      type: 'ssr',
      server: '1.2.3.4',
      port: 443,
      password: 'pass123',
      countryCode: 'HK',
      raw: const {
        'cipher': 'aes-128-cfb',
        'obfs': 'http_simple',
        'obfs-param': 'www.bing.com',
        'protocol': 'auth_aes128_md5',
      },
    );
    final cfg = SingBoxConfigBuilder.build(
        nodes: [ssr], selectedTag: ssr.tag, smartMode: true);
    expect(_nodeOutbounds(cfg), isEmpty, reason: 'ssr 不应生成任何出站');
    final selector = _selectGroup(cfg);
    expect((selector['outbounds'] as List), isNot(contains('ssr-1')),
        reason: '被跳过的节点不能出现在 select 组');
    expect(selector.containsKey('default'), isFalse,
        reason: '没有可用节点时不应写 default');
  });

  test('TUN 入站: 桌面 off 不建 TUN, TUN 模式生成声明式入站', () {
    final tun = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        tunMode: 'auto');
    final t = _tunInbound(tun)!;
    expect(t['tag'], 'tun-in');
    expect(t['address'], ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        reason: 'sing-box 1.12+ 只认 address 数组，旧的 inet4_address 已移除');
    expect(t['mtu'], 9000);
    expect(t['auto_route'], false, reason: '移动端路由由 VpnService 全量下发');
    expect(t['strict_route'], false);
    expect(t['stack'], 'gvisor');
    expect(t.containsKey('recvmsgx'), isFalse,
        reason: 'sing-box 没有 recvmsgx 字段（Darwin 的 utun 专属开关已随之消失）');
    // 系统代理模式仍在：mixed 入站与 TUN 入站并存
    expect(_inboundByType(tun, 'mixed')!['listen_port'], 2080);

    final off = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect(_tunInbound(off), isNull);
    expect(_inbounds(off).map((i) => i['type']).toList(), ['mixed']);

    // force 模式：只走 TUN，不再监听系统代理端口
    final force = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        tunMode: 'force');
    expect(_inboundByType(force, 'mixed'), isNull);
    expect(_tunInbound(force), isNotNull);
  });

  test('DNS: TUN 模式启用 fakeip; 桌面无 fakeip 也不监听端口', () {
    final tun = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        tunMode: 'auto');
    final fake = _dnsServers(tun).firstWhere((s) => s['tag'] == 'dns-fakeip');
    expect(fake['type'], 'fakeip');
    expect(fake['inet4_range'], '198.18.0.0/15');
    expect(_dnsRules(tun),
        anyElement(equals({'query_type': ['A', 'AAAA'], 'server': 'dns-fakeip'})));

    final off = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    final dns = off['dns'] as Map;
    expect(_dnsServers(off).map((s) => s['tag']), ['dns-main', 'dns-local']);
    expect(dns.containsKey('enhanced-mode'), isFalse,
        reason: 'sing-box 用 servers 里的 fakeip 项表达，不再有 enhanced-mode');
    expect(dns.containsKey('listen'), isFalse, reason: '桌面 dns 不监听端口');
    expect(dns['final'], 'dns-main');
    expect(dns['strategy'], 'prefer_ipv4');
    expect((off['route'] as Map)['default_domain_resolver'], {'server': 'dns-main'},
        reason: 'sing-box 1.12+ 必须有域名兜底解析器，否则启动报错');
  });

  test('直连名单注入: 域名后缀规则置于智能模式最前(优先级最高)', () {
    final cfg = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        bypassDomains: ['company.com', 'internal.net']);
    final rules = _rules(cfg);
    // 嗅探 → DNS 劫持 → 全局模式两段 → 用户直连名单 → 内置局域网直连
    expect(rules[0], {'action': 'sniff'});
    expect(rules[1], {'protocol': 'dns', 'action': 'hijack-dns'});
    expect(rules[2],
        {'clash_mode': 'Global', 'ip_cidr': _lanCidrs, 'outbound': 'direct'});
    expect(rules[3], {'clash_mode': 'Global', 'outbound': 'select'});
    expect(rules[4],
        {'clash_mode': 'Rule', 'domain_suffix': ['company.com'], 'outbound': 'direct'});
    expect(rules[5],
        {'clash_mode': 'Rule', 'domain_suffix': ['internal.net'], 'outbound': 'direct'});
    // 名单之后才是内置回环/局域网直连
    expect(rules[6],
        {'clash_mode': 'Rule', 'ip_cidr': _lanCidrs, 'outbound': 'direct'});
    // 不传时无名单规则：智能模式第一条网络规则就是内置局域网直连
    final plain = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect(_rules(plain)[4],
        {'clash_mode': 'Rule', 'ip_cidr': _lanCidrs, 'outbound': 'direct'});
    expect(_rules(plain).length, rules.length - 2);
  });

  test('内置「必须走代理」名单排在规则集(国内直连)之前', () {
    final cfg = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        ruleSetDir: '/tmp/rules');
    final rules = _rules(cfg);
    final proxyIdx = rules.indexWhere((r) =>
        r['clash_mode'] == 'Rule' &&
        r['outbound'] == 'select' &&
        r['domain_suffix'] is List);
    final geositeIdx = rules.indexWhere((r) =>
        r['clash_mode'] == 'Rule' &&
        (r['rule_set'] as List?)?.contains('geosite-cn') == true);
    expect(proxyIdx, greaterThan(0));
    expect(geositeIdx, greaterThan(proxyIdx),
        reason: 'chatgpt/linkedin 这类被污染 IP 会命中 geoip-cn，必须先走强制代理名单');
    // 内置名单内容原样下发给内核（避免手写 yaml/json 时漏项）
    expect(rules[proxyIdx]['domain_suffix'], SingBoxConfigBuilder.defaultForceProxyDomains);
    expect(rules[proxyIdx]['domain_suffix'], contains('chatgpt.com'));
    expect(rules[proxyIdx]['domain_suffix'], contains('netflix.com'));
  });

  test('DNS 模式: auto/fake-ip/redir-host', () {
    bool hasFakeIp(Map<String, dynamic> cfg) =>
        _dnsServers(cfg).any((s) => s['type'] == 'fakeip');

    // auto + 桌面(无 TUN)：不启用 fakeip（传统解析）
    final auto = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect(hasFakeIp(auto), isFalse);

    // auto + TUN：fakeip
    final autoTun = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        tunMode: 'auto');
    expect(hasFakeIp(autoTun), isTrue);

    // 显式 fake-ip（桌面也开）
    final fip = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        dnsMode: 'fake-ip');
    expect(hasFakeIp(fip), isTrue);

    // 显式 redir-host（TUN 也关 fakeip）
    final rh = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        tunMode: 'auto',
        dnsMode: 'redir-host');
    expect(hasFakeIp(rh), isFalse);
    expect(_dnsRules(rh).any((r) => r['server'] == 'dns-fakeip'), isFalse);
  });

  test('tunStack 参数生效(TUN 模式 stack 可切换, 非法值回落 gvisor)', () {
    Map<String, dynamic> tunOf(String? stack) =>
        _tunInbound(SingBoxConfigBuilder.build(
            nodes: [vlessNode],
            selectedTag: vlessNode.tag,
            smartMode: true,
            tunMode: 'auto',
            tunStack: stack ?? 'gvisor'))!;

    expect(tunOf(null)['stack'], 'gvisor');
    for (final s in const ['system', 'gvisor', 'mixed']) {
      expect(tunOf(s)['stack'], s);
    }
    expect(tunOf('bogus')['stack'], 'gvisor');
  });

  test('JSON 编码: 特殊字符节点名被正确转义且可被 jsonDecode 解析', () {
    final tricky = ProxyNode(
        tag: '香港#1: 直连 [测试] {VIP}, true',
        type: 'ss',
        server: '1.1.1.1',
        port: 8388,
        password: 'p@ss:word,with#specials',
        cipher: 'aes-256-gcm',
        countryCode: 'HK',
        raw: const {
          'name': '香港#1: 直连 [测试] {VIP}, true',
          'type': 'ss',
          'server': '1.1.1.1',
          'port': 8388,
          'password': 'p@ss:word,with#specials',
          'cipher': 'aes-256-gcm',
        });
    final cfg = SingBoxConfigBuilder.build(
        nodes: [tricky], selectedTag: tricky.tag, smartMode: true);
    final parsed =
        jsonDecode(SingBoxConfigBuilder.encode(cfg)) as Map<String, dynamic>;
    final outbounds = (parsed['outbounds'] as List).cast<Map<String, dynamic>>();
    final node = outbounds.firstWhere((o) => o['tag'] == tricky.tag);
    expect(node['type'], 'shadowsocks');
    expect(node['method'], 'aes-256-gcm');
    expect(node['password'], 'p@ss:word,with#specials');
    expect(node['server'], '1.1.1.1');
    final select = outbounds.firstWhere((o) => o['tag'] == 'select');
    expect((select['outbounds'] as List), contains(tricky.tag));
    expect(select['default'], tricky.tag);
  });

  test('直连名单三类条目: domain_suffix / ip_cidr / domain', () {
    final cfg = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        bypassDomains: [
          'company.com',
          'IP-CIDR:10.20.0.0/16',
          'DOMAIN:portal.example.com',
          '  ip-cidr:  172.16.5.0/24  ', // 前缀大小写不敏感 + 段内空白裁剪
          'IP-CIDR:', // 空值不产出规则
          '',
        ]);
    final rules = _rules(cfg);
    expect(rules[4],
        {'clash_mode': 'Rule', 'domain_suffix': ['company.com'], 'outbound': 'direct'});
    expect(rules[5],
        {'clash_mode': 'Rule', 'ip_cidr': ['10.20.0.0/16'], 'outbound': 'direct'});
    expect(rules[6],
        {'clash_mode': 'Rule', 'domain': ['portal.example.com'], 'outbound': 'direct'});
    expect(rules[7],
        {'clash_mode': 'Rule', 'ip_cidr': ['172.16.5.0/24'], 'outbound': 'direct'});
    // 空/仅前缀条目被跳过：下一条仍是基础回环直连
    expect(rules[8], {'clash_mode': 'Rule', 'ip_cidr': _lanCidrs, 'outbound': 'direct'});
    // 不产出空匹配规则（空 domain_suffix/ip_cidr 会让内核匹配全部流量）
    for (final r in rules) {
      for (final key in const ['domain_suffix', 'ip_cidr', 'domain']) {
        final v = r[key];
        if (v is List) {
          expect(v, isNotEmpty, reason: '$key 不能是空列表: $r');
          expect(v.every((e) => e.toString().trim().isNotEmpty), isTrue,
              reason: '$key 里不能有空串: $r');
        }
      }
    }
    // 四条直连规则仍位于内置局域网直连之前（优先级最高）
    expect(rules.take(9).skip(4).every((r) => r['outbound'] == 'direct'), isTrue);
    expect(rules.take(9).skip(4).every((r) => r['clash_mode'] == 'Rule'), isTrue);
  });

  test('多 nameserver: dnsNameservers 替换单值; 不传时保持旧行为', () {
    List<Map<String, dynamic>> serversOf(Map<String, dynamic> cfg) =>
        _dnsServers(cfg);

    // 不传新参数：仍是单值 dns
    final plain = SingBoxConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect(serversOf(plain).first,
        {'type': 'udp', 'tag': 'dns-main', 'server': '223.5.5.5'});

    // 自定义单值 dns 仍生效（无列表时）
    final single = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        dns: '1.1.1.1');
    expect(serversOf(single).first, {'type': 'udp', 'tag': 'dns-main', 'server': '1.1.1.1'});

    // tls:// 前缀映射成 sing-box 的 tls 型 DNS 服务器
    final doT = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        dns: 'tls://1.1.1.1');
    expect(serversOf(doT).first, {'type': 'tls', 'tag': 'dns-main', 'server': '1.1.1.1'});

    // 传入列表时按顺序替换（tag: dns-main / dns-1 / dns-2 …）
    final multi = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        dns: '1.1.1.1',
        dnsNameservers: ['223.5.5.5', '119.29.29.29', 'https://dns.alidns.com/dns-query']);
    final servers = serversOf(multi);
    expect(servers.map((s) => s['tag']).toList(), ['dns-main', 'dns-1', 'dns-2', 'dns-local']);
    expect(servers[0], {'type': 'udp', 'tag': 'dns-main', 'server': '223.5.5.5'});
    expect(servers[1], {'type': 'udp', 'tag': 'dns-1', 'server': '119.29.29.29'});
    expect(servers[2]['type'], 'https');
    expect(servers[2]['server'], 'dns.alidns.com',
        reason: 'https:// 前缀要拆成 host，内核拿到的是 DNS 服务器地址而不是 URL');
    expect(servers[2]['path'], '/dns-query', reason: 'DoH 自定义路径要保留');
    expect(servers[2]['domain_resolver'], 'dns-local',
        reason: 'sing-box 1.12+ 域名型 DNS 服务器必须带 domain_resolver');
    expect((multi['dns'] as Map)['final'], 'dns-main');
    expect((multi['route'] as Map)['default_domain_resolver'], {'server': 'dns-main'});
  });

  test('fakeIpFilterExtra: 追加到 DNS 内网后缀表, 空值忽略', () {
    // sing-box 没有 fake-ip-filter：内网/本地点名走 dns-local，等价于旧内核的
    // fake-ip-filter，额外名单就是往这张后缀表里追加
    final tun = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        tunMode: 'auto',
        fakeIpFilterExtra: ['*.lan', 'router.local', '  ', '']);
    final suffix = _dnsRules(tun).first['domain_suffix'] as List;
    expect(suffix,
        ['lan', 'local', 'localhost', 'localdomain', 'home.arpa', '*.lan', 'router.local'],
        reason: '空串/纯空白条目必须被丢掉');
    expect(_dnsRules(tun).first['server'], 'dns-local');
    expect(_dnsServers(tun).map((s) => s['type']), contains('fakeip'));

    // 显式 fake-ip（桌面）同样追加
    final fip = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        dnsMode: 'fake-ip',
        fakeIpFilterExtra: ['*.home.arpa']);
    final suffix2 = _dnsRules(fip).first['domain_suffix'] as List;
    expect(suffix2.last, '*.home.arpa');
    expect(_dnsServers(fip).map((s) => s['type']), contains('fakeip'));

    // 未启用 fake-ip 时：不生成 fakeip 服务器、也不生成 A/AAAA → fakeip 的规则，
    // extras 只影响内网解析走本地（这是 sing-box 结构的必然结果，非 fake-ip 专属开关）
    final off = SingBoxConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        fakeIpFilterExtra: ['*.lan']);
    expect(_dnsServers(off).any((s) => s['type'] == 'fakeip'), isFalse);
    expect(_dnsRules(off).any((r) => r['server'] == 'dns-fakeip'), isFalse);
    expect(_dnsRules(off).first['domain_suffix'], contains('*.lan'));
  });

  // ===== 真实内核验证（有本地 sing-box 二进制时执行）=====
  final singbox = _localSingBox();
  final skipMsg = singbox == null
      ? '未找到本地 sing-box 内核（可用 MBOX_SINGBOX 指定）'
      : null;

  /// 覆盖全协议 + 特殊字符名的节点池。
  /// 不含 ssr：sing-box ≥1.6 已删除 shadowsocksr 出站类型（生成器缺陷，见 ssr 用例）。
  List<ProxyNode> allProtocolNodes() => [
        mkNode('vless', raw: {
          'reality-opts': {
            // sing-box 会校验 X25519 公钥格式（旧内核不校验），用真实生成的 key
            'public-key': 'R4V_BnGe4UM6IM6Ls_GlFzr9E1P9h307pB9I1tgwGXA',
            'short-id': '00112233',
          },
          'client-fingerprint': 'chrome',
        }),
        mkNode('vmess', raw: {
          'network': 'ws',
          'ws-opts': {'path': '/p'}
        }),
        mkNode('trojan', tag: '节点#1 [HK]'),
        mkNode('ss'),
        mkNode('hysteria2', raw: {'obfs': 'salamander', 'obfs-password': 'op'}),
        mkNode('tuic', raw: {'congestion-controller': 'bbr'}),
        mkNode('anytls'),
      ];

  test('真实内核 check 校验生成的 JSON 合法（全协议 + TUN + 离线规则集）',
      skip: skipMsg, () {
    final tmp = Directory.systemTemp.createTempSync('mf_singbox_t');
    try {
      final seeded = _seedRuleSets(tmp.path);
      // .srs 不入库（构建期由 tool/fetch_ruleset.sh 下载）：本机缺规则集时跳过
      // 「规则集组合」这一步，无规则集的降级配置由下一个用例覆盖
      if (seeded.length < 2) {
        markTestSkipped('assets/rules/*.srs 缺失（先跑 tool/fetch_ruleset.sh）');
        return;
      }
      final cfg = SingBoxConfigBuilder.build(
        nodes: allProtocolNodes(),
        selectedTag: 'trojan-1',
        smartMode: true,
        tunMode: 'auto',
        tunAutoRoute: true,
        ruleSetDir: tmp.path,
      );
      File('${tmp.path}/config.json')
          .writeAsStringSync(SingBoxConfigBuilder.encode(cfg));
      final r = Process.runSync(
          singbox!, ['check', '-c', '${tmp.path}/config.json'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      debugPrint('sing-box check stdout: ${r.stdout}');
      debugPrint('sing-box check stderr: ${r.stderr}');
      expect(r.exitCode, 0, reason: '配置必须被 sing-box 内核接受: ${r.stderr}');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('真实内核 check: 无规则集的降级配置（ruleSetDir=null）同样合法', skip: skipMsg,
      () {
    final tmp = Directory.systemTemp.createTempSync('mf_singbox_t2');
    try {
      // 离线规则集缺失时的降级产物：不引用 .srs，内核照常能起
      final cfg = SingBoxConfigBuilder.build(
        nodes: allProtocolNodes(),
        selectedTag: 'trojan-1',
        smartMode: true,
        tunMode: 'auto',
        tunAutoRoute: true,
      );
      expect((cfg['route'] as Map).containsKey('rule_set'), isFalse);
      File('${tmp.path}/config.json')
          .writeAsStringSync(SingBoxConfigBuilder.encode(cfg));
      final r = Process.runSync(
          singbox!, ['check', '-c', '${tmp.path}/config.json'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      debugPrint('sing-box check(降级) stderr: ${r.stderr}');
      expect(r.exitCode, 0, reason: '降级配置必须能被内核接受: ${r.stderr}');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ---- iOS 关键回归：规则集相对路径 + 扩展侧绝对化 ----
  //
  // 背景（真机踩过）：iOS 扩展给内核的可能是一份 `path: "geosite-cn.srs"` 的相对
  // 路径配置，而 sing-box 用**进程 CWD** 解析它；NetworkExtension 的 CWD 是 `/`，
  // 于是内核起来就 FATAL，App 只看到「内核启动超时」。
  // 扩展侧（PacketTunnelProvider.absolutizeRuleSetPaths）会把路径换成绝对路径、
  // 并把缺失的规则集连同引用它的规则一起摘掉。这里用真实内核验证这两条：
  //   ① 相对路径原样交给内核 → check 必须失败（证明这一步不能省）；
  //   ② 绝对化之后 → check 必须通过；
  //   ③ 规则集全丢时的降级配置 → check 仍通过（可用性优先）。
  test('真实内核 check: iOS 相对规则集路径必须绝对化（否则内核 FATAL）',
      skip: skipMsg, () {
    final tmp = Directory.systemTemp.createTempSync('mf_ios_rules');
    try {
      final seeded = _seedRuleSets(tmp.path);
      if (seeded.length < 2) {
        markTestSkipped('assets/rules/*.srs 缺失（先跑 tool/fetch_ruleset.sh）');
        return;
      }
      final cfg = SingBoxConfigBuilder.build(
        nodes: allProtocolNodes(),
        selectedTag: 'trojan-1',
        smartMode: true,
        tunMode: 'auto',
        tunAutoRoute: true,
        ruleSetDir: '', // iOS：扩展侧落盘，配置里是裸文件名
      );

      // ① 裸文件名（相对路径）
      final sets = ((cfg['route'] as Map)['rule_set'] as List).cast<Map>();
      expect(sets, isNotEmpty);
      for (final rs in sets) {
        final path = rs['path'] as String;
        expect(path.contains('/'), isFalse, reason: 'iOS 配置应当是裸文件名: $path');
      }
      File('${tmp.path}/config.json')
          .writeAsStringSync(SingBoxConfigBuilder.encode(cfg));
      // ①-a 换个 CWD 跑：相对路径解析不到 → 内核必须报错（真机就是这个状态）
      final wrongCwd = Process.runSync(
          singbox!, ['check', '-c', '${tmp.path}/config.json'],
          workingDirectory: Directory.systemTemp.path,
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      expect(wrongCwd.exitCode, isNot(0),
          reason: 'CWD 不含规则集时相对路径必须失败 —— 这正是 iOS 上'
              '「内核一起来就退出」的原因，扩展侧绝对化不能省');

      // ①-b 在规则集所在目录跑：相对路径能解析，check 通过
      final relCwd = Process.runSync(
          singbox, ['check', '-c', '${tmp.path}/config.json'],
          workingDirectory: tmp.path,
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      expect(relCwd.exitCode, 0,
          reason: '在正确 CWD 下相对路径是可用的: ${relCwd.stderr}');

      // ② 模拟扩展侧绝对化：路径补全成临时目录下的绝对路径
      final absCfg = Map<String, dynamic>.from(cfg);
      final absRoute = Map<String, dynamic>.from(absCfg['route'] as Map);
      absRoute['rule_set'] = [
        for (final rs in sets)
          {
            ...Map<String, dynamic>.from(rs),
            'path': '${tmp.path}/${rs['path']}',
          }
      ];
      absCfg['route'] = absRoute;
      File('${tmp.path}/config.absolute.json')
          .writeAsStringSync(SingBoxConfigBuilder.encode(absCfg));
      final absRun = Process.runSync(
          singbox, ['check', '-c', '${tmp.path}/config.absolute.json'],
          workingDirectory: Directory.systemTemp.path, // 故意不在规则集目录
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      expect(absRun.exitCode, 0,
          reason: '绝对化后的配置必须被内核接受（扩展就是这么做的）: ${absRun.stderr}');

      // ③ 规则集缺失时的降级：摘掉 rule_set 与引用它的规则，内核仍能起
      final degraded = Map<String, dynamic>.from(cfg);
      final degRoute = Map<String, dynamic>.from(degraded['route'] as Map);
      degRoute.remove('rule_set');
      degRoute['rules'] = [
        for (final r in (degRoute['rules'] as List).cast<Map>())
          if (r['rule_set'] == null) Map<String, dynamic>.from(r)
      ];
      degraded['route'] = degRoute;
      File('${tmp.path}/config.degraded.json')
          .writeAsStringSync(SingBoxConfigBuilder.encode(degraded));
      final degRun = Process.runSync(
          singbox, ['check', '-c', '${tmp.path}/config.degraded.json'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      expect(degRun.exitCode, 0,
          reason: '降级配置必须被内核接受（规则集丢了也不能连不上）: ${degRun.stderr}');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('真实内核 Clash API: mode 热切换 + 切节点（无内置 GLOBAL 组）', skip: skipMsg,
      () async {
    final nodes = [mkNode('vless', tag: 'n1'), mkNode('ss', tag: 'n2')];
    final tmp = Directory.systemTemp.createTempSync('mf_singbox_run');
    final dio = Dio();
    Process? proc;
    try {
      // 端口不写死 2080/9090：并行跑测试时固定端口会互相抢
      var ready = false;
      var api = '';
      final kernelLog = <String>[];
      for (var attempt = 0; attempt < 3 && !ready; attempt++) {
        final localPort = await _freePort();
        final apiPort = await _freePort();
        final cfg = SingBoxConfigBuilder.build(
          nodes: nodes,
          selectedTag: 'n1',
          smartMode: true,
          localPort: localPort,
          clashApiPort: apiPort,
        );
        final secret = cfg['_clashApiSecret'] as String;
        File('${tmp.path}/config.json')
            .writeAsStringSync(SingBoxConfigBuilder.encode(cfg));
        dio.options.headers['Authorization'] = 'Bearer $secret';
        proc = await Process.start(
            singbox!, ['run', '-c', '${tmp.path}/config.json'],
            environment: {'PATH': Platform.environment['PATH'] ?? ''});
        proc.stdout.transform(utf8.decoder).listen((_) {});
        proc.stderr.transform(utf8.decoder).listen(kernelLog.add);
        api = 'http://127.0.0.1:$apiPort';
        // 等 /version 就绪
        for (var i = 0; i < 100 && !ready; i++) {
          try {
            final r = await dio.get('$api/version',
                options: Options(validateStatus: (s) => true));
            if (r.statusCode == 200) ready = true;
          } catch (_) {}
          if (!ready) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }
        if (!ready) {
          // 端口被抢时换一对端口重试；其它原因则把内核日志带进失败信息
          proc.kill();
          await proc.exitCode;
          proc = null;
          if (!kernelLog.any((l) => l.contains('address already in use'))) break;
        }
      }
      expect(ready, isTrue,
          reason: '内核 10s 内未就绪；内核日志: ${kernelLog.join(' | ')}');

      final v = await dio.get('$api/version');
      debugPrint('内核版本: ${v.data}');
      expect('${v.data}', contains('sing-box'));

      // sing-box 没有内置 GLOBAL 组：出站选择器就叫 select，默认选中 n1
      final px = await dio.get('$api/proxies');
      final pxMap = _jsonMap(px.data)['proxies'] as Map;
      expect(pxMap.containsKey('select'), isTrue);
      expect((pxMap['select'] as Map)['type'], 'Selector');
      expect((pxMap['select'] as Map)['now'], 'n1');

      // 热切节点: PUT /proxies/select n2 → 204
      final put = await dio.put('$api/proxies/select',
          data: {'name': 'n2'}, options: Options(validateStatus: (s) => true));
      expect(put.statusCode, 204);
      await Future.delayed(const Duration(milliseconds: 200));
      final px2 = await dio.get('$api/proxies');
      expect((_jsonMap(px2.data)['proxies'] as Map)['select']['now'], 'n2');

      // 热切模式: Rule → Global（PATCH /configs）→ 204，GET /configs 跟着变
      final cfgNow = await dio.get('$api/configs');
      expect(_jsonMap(cfgNow.data)['mode'], 'Rule');
      final patch = await dio.patch('$api/configs',
          data: {'mode': 'Global'}, options: Options(validateStatus: (s) => true));
      expect(patch.statusCode, 204);
      await Future.delayed(const Duration(milliseconds: 200));
      final cfgs = await dio.get('$api/configs');
      expect(_jsonMap(cfgs.data)['mode'], 'Global');
      // 全局模式下换线路仍然走 select（没有 GLOBAL 组可供 PUT）
      final putGlobal = await dio.put('$api/proxies/select',
          data: {'name': 'n1'}, options: Options(validateStatus: (s) => true));
      expect(putGlobal.statusCode, 204);
      await Future.delayed(const Duration(milliseconds: 200));
      final px3 = await dio.get('$api/proxies');
      expect((_jsonMap(px3.data)['proxies'] as Map)['select']['now'], 'n1');

      // 切回 Rule
      final patchBack = await dio.patch('$api/configs',
          data: {'mode': 'Rule'}, options: Options(validateStatus: (s) => true));
      expect(patchBack.statusCode, 204);
      await Future.delayed(const Duration(milliseconds: 200));
      final cfgs2 = await dio.get('$api/configs');
      expect(_jsonMap(cfgs2.data)['mode'], 'Rule');

      // secret 生效：不带 Authorization 必须 401，否则本机任意进程都能改代理
      final noAuth = await Dio().get('$api/configs',
          options: Options(validateStatus: (s) => true));
      expect(noAuth.statusCode, 401);
    } finally {
      proc?.kill();
      await proc?.exitCode;
      dio.close(force: true);
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
