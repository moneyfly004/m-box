import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/singbox_config.dart';
import 'package:moneyfly/core/models/models.dart';

/// 智能模式路由回归（客户实测 2026-10-18）：
/// 「linkedin.com / tiktok.com / chatgpt.com / gemini.google.com 这类必须走代理的
///  站点，在智能模式下打不开」。
///
/// 两个真实原因：
///   ① 这些站点被国内 DNS 解析出污染 IP（常落在 CN 段）→ geoip-cn 规则集命中 → DIRECT；
///      或字节系 CDN 域名被 geosite-cn 规则集收录 → DIRECT。
///   ② TUN 场景内核只拿到 IP，没有域名嗅探就无法按域名判路由。
///
/// 修法（内核换成 sing-box 1.14.4 后的等价实现）：
///   - 「必须走代理」名单写成 `route.rules` 里一条 domain_suffix → select 规则，
///     并**排在 geosite-cn / geoip-cn 规则集规则之前**（mihomo 版同样置顶）；
///   - 打开嗅探：`route.rules` 第一条 `{action: 'sniff'}`（替代 mihomo 的 sniffer 段），
///     放在 geoip-cn 规则之前，纯 IP 包嗅出域名后才判路由。
ProxyNode _node(String tag) => ProxyNode(
      tag: tag,
      type: 'ss',
      server: '203.0.113.10',
      port: 8388,
      cipher: 'aes-128-gcm',
      password: 'pw',
      countryCode: 'US',
      raw: const {},
    );

/// 规则集目录（只为断言「规则里引用了 .srs」；本组用例不启动内核，目录不必存在）
const _ruleSetDir = '/tmp/moneyfly-e2e-rules';

Map<String, dynamic> _build({
  List<String> forceProxyDomains = const [],
  List<String> bypassDomains = const [],
}) =>
    SingBoxConfigBuilder.build(
      nodes: [_node('节点A')],
      selectedTag: '节点A',
      smartMode: true,
      dns: '223.5.5.5',
      tunMode: 'auto',
      geoReady: true,
      ruleSetDir: _ruleSetDir,
      forceProxyDomains: forceProxyDomains,
      bypassDomains: bypassDomains,
    );

List<Map<String, dynamic>> _rules(Map<String, dynamic> cfg) =>
    ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

/// 「必须走代理」规则：Rule 模式下 domain_suffix → select（不存在返回 null）
Map<String, dynamic>? _forceProxyRule(Map<String, dynamic> cfg) =>
    _forceProxyRuleIn(_rules(cfg));

Map<String, dynamic>? _forceProxyRuleIn(List<Map<String, dynamic>> rules) {
  for (final r in rules) {
    if (r['outbound'] == 'select' && r['domain_suffix'] is List) return r;
  }
  return null;
}

/// 「必须走代理」规则的下标（必须在同一份 rules 实例里定位：
/// Map 的 == 是引用相等，跨实例 indexOf 永远返回 -1）
int _forceProxyIndex(List<Map<String, dynamic>> rules) =>
    rules.indexOf(_forceProxyRuleIn(rules)!);

/// 第一条引用 .srs 规则集（geosite-cn / geoip-cn）的规则下标，无则 -1
int _firstRuleSetIndex(List<Map<String, dynamic>> rules) {
  for (var i = 0; i < rules.length; i++) {
    final ref = rules[i]['rule_set'];
    if (ref is List && ref.isNotEmpty) return i;
  }
  return -1;
}

void main() {
  group('必须走代理的站点在智能模式下一定命中代理', () {
    test('chatgpt / gemini / linkedin / tiktok 都有 domain_suffix → select 规则', () {
      final cfg = _build();
      final rule = _forceProxyRule(cfg);
      expect(rule, isNotNull, reason: '智能模式必须有一条「必须走代理」的域名规则');
      // 只在 Rule（智能）模式生效：Global 模式由 catch-all 规则全走代理
      expect(rule!['clash_mode'], 'Rule');
      final suffixes = (rule['domain_suffix'] as List).cast<String>();
      for (final d in [
        'chatgpt.com',
        'openai.com',
        'gemini.google.com',
        'generativelanguage.googleapis.com',
        'linkedin.com',
        'tiktok.com',
        'tiktokv.com',
        'tiktokcdn.com',
        'claude.ai',
        'x.com',
        'youtube.com',
      ]) {
        expect(suffixes, contains(d),
            reason: '$d 必须显式走代理（否则可能被 geoip-cn / geosite-cn 判成直连）');
      }
    });

    test('强制代理规则排在 geosite/geoip 规则集之前（否则会被判成直连）', () {
      final rules = _rules(_build());
      final proxyIndex = _forceProxyIndex(rules);
      final firstRuleSet = _firstRuleSetIndex(rules);
      expect(proxyIndex, greaterThanOrEqualTo(0));
      expect(firstRuleSet, greaterThanOrEqualTo(0),
          reason: 'geoReady=true 时必须声明 geosite-cn / geoip-cn 规则集规则');
      expect(firstRuleSet, greaterThan(proxyIndex),
          reason: '强制代理必须排在 geosite-cn / geoip-cn 之前，否则会被判成直连');
    });

    test('用户「直连名单」优先级最高（显式不要走代理时，连强制代理也不拦）', () {
      final rules = _rules(_build(bypassDomains: ['chatgpt.com']));
      // Rule 模式的第一条规则就是用户直连名单
      final firstRuleMode = rules.firstWhere((r) => r['clash_mode'] == 'Rule');
      expect(firstRuleMode['outbound'], 'direct');
      expect(firstRuleMode['domain_suffix'], ['chatgpt.com']);
      // 且排在「必须走代理」与规则集之前
      final bypassIndex = rules.indexOf(firstRuleMode);
      expect(bypassIndex, lessThan(_forceProxyIndex(rules)));
      expect(bypassIndex, lessThan(_firstRuleSetIndex(rules)));
    });

    test('用户追加的域名同样生效，且去重/去协议/大小写归一', () {
      final cfg = _build(forceProxyDomains: [
        'MySite.example.com',
        'https://another.example.org/path',
        '  mysite.example.com  ',
      ]);
      final suffixes = (_forceProxyRule(cfg)!['domain_suffix'] as List).cast<String>();
      expect(suffixes, contains('mysite.example.com'));
      expect(suffixes, contains('another.example.org'));
      // 只出现一次（大小写/空白归一后去重）
      expect(suffixes.where((d) => d == 'mysite.example.com').length, 1);
      // 整份配置里也只出现一次，不会在别的规则里重复出现
      final encoded = SingBoxConfigBuilder.encode(cfg);
      expect('mysite.example.com'.allMatches(encoded).length, 1);
    });

    test('仍然保留兜底：未列出的域名走 select（代理）', () {
      final cfg = _build();
      // sing-box 没有 mihomo 的 MATCH 兜底规则，兜底是 route.final
      expect((cfg['route'] as Map)['final'], 'select',
          reason: '兜底必须是代理（select），不能是 direct');
      final rules = _rules(cfg);
      expect(rules.last['outbound'], 'direct'); // 最后一条是 geoip-cn 直连，不是兜底
      final encoded = SingBoxConfigBuilder.encode(cfg);
      expect(encoded, isNot(contains('MATCH,')));
      expect(encoded, isNot(contains('GEOSITE,')));
      expect(encoded, isNot(contains('GEOIP,')));
    });
  });

  group('域名嗅探（sniff）已开启', () {
    test('TUN 模式下打开 sniff 且排在规则集之前，纯 IP 目标按域名回判路由', () {
      final cfg = _build();
      final rules = _rules(cfg);
      expect(rules.first, {'action': 'sniff'},
          reason: 'sniff 必须是第一条路由动作：TUN 场景只拿到 IP 包，'
              '不从 TLS/HTTP ClientHello 嗅出域名就没法按域名判路由');
      final sniffIndex = rules.indexOf(rules.first);
      final firstRuleSet = _firstRuleSetIndex(rules);
      expect(firstRuleSet, greaterThan(sniffIndex),
          reason: '嗅探必须发生在 geoip-cn/geosite-cn 判定之前，否则污染 IP 先被判直连');
      // 内核 DNS 劫持：TUN 里的 53 端口流量交给内置 DNS（fake-ip 才会生效）
      // （contains 对 Map 用 == 判等，这里必须显式用 equals 做深比较）
      expect(rules, contains(equals({'protocol': 'dns', 'action': 'hijack-dns'})));
      // mihomo 的 sniffer 段已被 route 规则取代，不应再出现在产物里
      expect(cfg.containsKey('sniffer'), isFalse);
    });
  });
}
