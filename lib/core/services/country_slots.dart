import '../models/models.dart';

/// 首页「快速切换国家」九宫格的内容选择规则（纯函数，便于单测）。
///
/// 用户要求（固定位置、内容可动）：
///   - 一共 **9 个格子**：第 1 格恒为「自动最优」，其余 8 格是**固定格位**；
///   - 8 个格位里放哪些国家不固定：**延迟最低的优先**；
///   - 但**必须有一个美国**（美国线路是刚需）：若美国没进前 8，就顶掉最慢的那一个。
///
/// 这样格子数量、大小、位置永远不变，只有格子里的国旗/名字会随测速结果走。
List<MapEntry<String, ProxyNode>> selectCountrySlots(
  List<MapEntry<String, ProxyNode>> byLatency,
  int max, {
  String pinned = 'US',
}) {
  if (max <= 0 || byLatency.isEmpty) return const [];
  final picked = <MapEntry<String, ProxyNode>>[];
  final used = <String>{};
  for (final e in byLatency) {
    if (picked.length >= max) break;
    if (used.add(e.key)) picked.add(e);
  }
  // 美国必须在：没进前 max 就替换掉当前最后一个（最慢的那个）
  if (pinned.isNotEmpty && !used.contains(pinned)) {
    MapEntry<String, ProxyNode>? us;
    for (final e in byLatency) {
      if (e.key == pinned) {
        us = e;
        break;
      }
    }
    if (us != null) {
      if (picked.length >= max) {
        final dropped = picked.removeLast().key;
        used.remove(dropped);
      }
      if (used.add(us.key)) picked.add(us);
    }
  }
  // 仍然按延迟排序（美国顶进来后也回到它该在的位置）
  picked.sort((a, b) => a.value.latencyMs.compareTo(b.value.latencyMs));
  return picked;
}
