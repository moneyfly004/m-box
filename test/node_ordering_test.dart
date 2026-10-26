// 回归：节点列表按「距中国远近 + 热门置顶」排序（三端共用 ProxyNode.compareForList）。
// 用户要求：香港→日本→新加坡→美国 置顶，其余按距中国远近。
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';

ProxyNode _n(String code, {int latency = 100, bool online = true, String? tag}) =>
    ProxyNode(
      tag: tag ?? '$code-node',
      type: 'vless',
      server: '1.1.1.1',
      port: 443,
      countryCode: code,
      raw: const {},
    )
      ..latencyMs = latency
      ..online = online;

void main() {
  test('国家权重：热门顺序 HK<JP<SG<US，且都在近邻/远端之前', () {
    expect(ProxyNode.countryRank('HK'), 0);
    expect(ProxyNode.countryRank('JP'), 1);
    expect(ProxyNode.countryRank('SG'), 2);
    expect(ProxyNode.countryRank('US'), 3);
    // 热门四国排在东亚近邻(TW/KR)之前
    expect(ProxyNode.countryRank('US') < ProxyNode.countryRank('TW'), isTrue);
    // 近邻排在欧洲之前
    expect(ProxyNode.countryRank('KR') < ProxyNode.countryRank('DE'), isTrue);
    // 欧洲排在南美之前
    expect(ProxyNode.countryRank('DE') < ProxyNode.countryRank('BR'), isTrue);
    // 未知国家码排最后
    expect(ProxyNode.countryRank('XX') >= 998, isTrue);
    expect(ProxyNode.countryRank(null), 999);
  });

  test('列表排序：热门国家置顶，顺序 港→日→新→美', () {
    final nodes = [_n('US'), _n('DE'), _n('SG'), _n('JP'), _n('HK'), _n('BR')];
    nodes.sort(ProxyNode.compareForList);
    final codes = nodes.map((n) => n.countryCode).toList();
    expect(codes.take(4).toList(), ['HK', 'JP', 'SG', 'US']);
    // 德国(欧洲)在巴西(南美)之前
    expect(codes.indexOf('DE') < codes.indexOf('BR'), isTrue);
  });

  test('同一国家内：在线优先、延迟升序', () {
    final nodes = [
      _n('HK', latency: 200, tag: 'HK-慢'),
      _n('HK', latency: -1, online: false, tag: 'HK-离线'),
      _n('HK', latency: 50, tag: 'HK-快'),
    ];
    nodes.sort(ProxyNode.compareForList);
    expect(nodes.map((n) => n.tag).toList(), ['HK-快', 'HK-慢', 'HK-离线']);
  });

  test('近邻按距中国远近：TW/KR 在东南亚之前，东南亚在南亚之前', () {
    expect(ProxyNode.countryRank('TW') < ProxyNode.countryRank('VN'), isTrue);
    expect(ProxyNode.countryRank('KR') < ProxyNode.countryRank('TH'), isTrue);
    expect(ProxyNode.countryRank('VN') < ProxyNode.countryRank('IN'), isTrue);
  });
}
