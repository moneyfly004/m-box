import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/mihomo_config.dart';
import 'package:moneyfly/core/models/models.dart';

/// 智能模式路由回归（客户实测 2026-10-18）：
/// 「linkedin.com / tiktok.com / chatgpt.com / gemini.google.com 这类必须走代理的
///  站点，在智能模式下打不开」。
///
/// 两个真实原因：
///   ① 这些站点被国内 DNS 解析出污染 IP（常落在 CN 段）→ GEOIP,CN 命中 → DIRECT；
///      或字节系 CDN 域名被 geolocation-cn 收录 → GEOSITE,cn 命中 → DIRECT。
///   ② TUN 场景内核只拿到 IP，没有域名嗅探就无法按域名判路由。
///
/// 修法：内置「必须走代理」名单（规则置顶）+ 打开 sniffer。
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

Map<String, dynamic> _build({List<String> forceProxyDomains = const []}) =>
    MihomoConfigBuilder.build(
      nodes: [_node('节点A')],
      selectedTag: '节点A',
      smartMode: true,
      dns: '223.5.5.5',
      tunMode: 'auto',
      geoReady: true,
      forceProxyDomains: forceProxyDomains,
    );

void main() {
  group('必须走代理的站点在智能模式下一定命中代理', () {
    test('chatgpt / gemini / linkedin / tiktok 都有 DOMAIN-SUFFIX → select 规则', () {
      final rules = (_build()['rules'] as List).cast<String>();
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
        expect(rules, contains('DOMAIN-SUFFIX,$d,select'),
            reason: '$d 必须显式走代理（否则可能被 GEOIP/GEOSITE 判成直连）');
      }
    });

    test('强制代理规则排在 GEOSITE/GEOIP 之前（否则会被判成直连）', () {
      final rules = (_build()['rules'] as List).cast<String>();
      final firstProxy = rules.indexWhere((r) => r.endsWith(',select'));
      final firstDirect = rules.indexWhere(
          (r) => r.contains('GEOSITE,cn') || r.contains('RULE-SET,cn') || r.contains('GEOIP,CN'));
      expect(firstProxy, greaterThanOrEqualTo(0));
      expect(firstDirect, greaterThan(firstProxy),
          reason: '强制代理必须排在 GEOSITE/GEOIP 之前，否则会被判成直连');
    });

    test('用户「直连名单」优先级最高（显式不要走代理时，连强制代理也不拦）', () {
      final rules = (MihomoConfigBuilder.build(
        nodes: [_node('A')],
        selectedTag: 'A',
        smartMode: true,
        dns: '223.5.5.5',
        tunMode: 'auto',
        geoReady: true,
        bypassDomains: ['chatgpt.com'],
      )['rules'] as List)
          .cast<String>();
      expect(rules.first, 'DOMAIN-SUFFIX,chatgpt.com,DIRECT');
    });

    test('用户追加的域名同样生效，且去重/去协议/大小写归一', () {
      final rules = (_build(forceProxyDomains: [
        'MySite.example.com',
        'https://another.example.org/path',
        '  mysite.example.com  ',
      ])['rules'] as List)
          .cast<String>();
      expect(rules, contains('DOMAIN-SUFFIX,mysite.example.com,select'));
      expect(rules, contains('DOMAIN-SUFFIX,another.example.org,select'));
      // 只出现一次（大小写/空白归一后去重）
      expect(rules.where((r) => r == 'DOMAIN-SUFFIX,mysite.example.com,select').length, 1);
    });

    test('仍然保留兜底：未列出的域名走 MATCH,select（代理）', () {
      final rules = (_build()['rules'] as List).cast<String>();
      expect(rules.last, 'MATCH,select');
    });
  });

  group('域名嗅探（sniffer）已开启', () {
    test('TUN 模式下打开 sniffer，纯 IP 目标按域名回判路由', () {
      final sniffer = _build()['sniffer'] as Map;
      expect(sniffer['enable'], isTrue);
      expect(sniffer['parse-pure-ip'], isTrue,
          reason: 'TUN 场景必须能从纯 IP 包嗅探出域名，否则 GEOIP 误判无解');
      expect((sniffer['sniff'] as Map)['TLS'], isNotNull);
    });
  });
}
