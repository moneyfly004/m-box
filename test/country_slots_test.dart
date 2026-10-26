import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/services/country_slots.dart';

ProxyNode _n(String tag, int ms) => ProxyNode(
      tag: tag,
      type: 'ss',
      server: '198.51.100.10',
      port: 443,
      cipher: 'aes-128-gcm',
      password: 'pw',
      latencyMs: ms,
      online: true,
      raw: const {},
    );

List<MapEntry<String, ProxyNode>> _sorted(Map<String, int> latency) {
  final list = latency.entries.map((e) => MapEntry(e.key, _n(e.key, e.value))).toList()
    ..sort((a, b) => a.value.latencyMs.compareTo(b.value.latencyMs));
  return list;
}

void main() {
  test('按延迟取前 8 个（固定 8 个格位，内容随延迟变）', () {
    final picked = selectCountrySlots(_sorted({
      'HK': 20, 'JP': 30, 'SG': 40, 'TW': 50, 'KR': 60,
      'US': 70, 'DE': 80, 'GB': 90, 'FR': 100, 'CA': 110,
    }), 8);
    expect(picked.map((e) => e.key).toList(),
        ['HK', 'JP', 'SG', 'TW', 'KR', 'US', 'DE', 'GB']);
  });

  test('美国没进前 8 时顶掉最慢的一个（保证有美国格）', () {
    // 美国延迟最高，正常取前 8 会没有美国
    final picked = selectCountrySlots(_sorted({
      'HK': 20, 'JP': 30, 'SG': 40, 'TW': 50, 'KR': 60,
      'DE': 70, 'GB': 80, 'FR': 90, 'CA': 100, 'US': 999,
    }), 8);
    final keys = picked.map((e) => e.key).toList();
    expect(keys, contains('US'), reason: '必须有一个美国格');
    expect(keys, hasLength(8), reason: '格位数量不允许变多');
    expect(keys, isNot(contains('CA')), reason: '被顶掉的是最慢的那个（CA=100）');
    // 顶进来之后仍按延迟排序
    expect(keys.last, 'US');
  });

  test('没有任何美国线路时保持原样（不凭空造格）', () {
    final picked = selectCountrySlots(_sorted({
      'HK': 20, 'JP': 30, 'SG': 40, 'TW': 50, 'KR': 60, 'DE': 70, 'GB': 80, 'FR': 90,
    }), 8);
    expect(picked.map((e) => e.key).toList(),
        ['HK', 'JP', 'SG', 'TW', 'KR', 'DE', 'GB', 'FR']);
  });

  test('已知国家不足 8 个时返回实际数量（其余格位由 UI 占位）', () {
    final picked = selectCountrySlots(_sorted({'HK': 20, 'US': 30}), 8);
    expect(picked.map((e) => e.key).toList(), ['HK', 'US']);
    expect(selectCountrySlots(const [], 8), isEmpty);
    expect(selectCountrySlots(_sorted({'HK': 20}), 0), isEmpty);
  });
}
