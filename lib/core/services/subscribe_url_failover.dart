/// 订阅地址轮换：主订阅地址打不开时，按顺序尝试其它域名，拿到同一份订阅。
///
/// 为什么需要（2026-09-23）：官网/主订阅域名在部分地区被屏蔽，用户「更新不了订阅」。
/// 后端现在会在 `/user/subscribe` 里下发 `subscribe_urls`（主域名 + 备用域名，
/// token 相同、配置完全一致），本类负责按合适顺序逐个尝试：
///
///   1. **上次成功的地址优先** —— 上次能用的域名大概率现在也能用，避免每次都先撞墙；
///   2. 其次主地址，再依次尝试备用地址；
///   3. 成功即回调 [onSuccess]，由调用方记住（磁盘缓存里会记录实际使用的地址）；
///   4. 全部失败时**如实抛出最后一个异常**，不掩盖错误、不返回空内容。
///
/// 命中「返回了内容但不是订阅」（机房拦截页/运营商提示页常返回 200 + HTML）
/// 时也视为该地址失败，继续换下一个 —— 否则用户会拿到一份解析不出节点的"空订阅"。
library;

/// 拉取订阅原文的函数签名（注入以便测试）
typedef SubscribeFetch = Future<String> Function(String url);

class SubscribeUrlFailover {
  SubscribeUrlFailover._();

  /// 从订阅地址里取 token：用于判断两个不同域名的地址是否是**同一份订阅**。
  /// 取不到 token 时返回空串（调用方应按"不确定"处理，不做同源判断）。
  static String tokenOf(String url) {
    if (url.isEmpty) return '';
    final m = RegExp(r'[?&]token=([^&#]+)').firstMatch(url);
    return m?.group(1) ?? '';
  }

  /// 候选顺序：上次成功的（若与主地址同属一份订阅）→ 主地址 → 备用地址（去重）。
  static List<String> candidates({
    required String primary,
    Iterable<String> backups = const [],
    String? preferred,
    /// 可选的「主机快慢」判据（越小越快，来自客户端域名实测）。
    /// 传入时：候选按快慢排序（上次成功的仍排最前）—— 国内各地 ISP 差别大，
    /// 「哪个快用哪个」必须由实测决定，不能写死主地址优先。
    int Function(String url)? hostPriority,
  }) {
    final out = <String>[];
    void add(String? u) {
      final v = (u ?? '').trim();
      if (v.isEmpty || out.contains(v)) return;
      out.add(v);
    }

    final primaryToken = tokenOf(primary);
    final preferredToken = tokenOf(preferred ?? '');
    // preferred 只在「与主地址同一份订阅」时采用：避免续费/重建订阅后
    // 拿着旧 token 的地址反复失败（旧地址会 403/404）
    if (preferredToken.isNotEmpty && preferredToken == primaryToken) {
      add(preferred);
    }
    final rest = <String>[primary];
    for (final b in backups) {
      final t = tokenOf(b);
      // 备用地址必须与主地址同 token；不同 token 的一律跳过（可能是别的订阅/别的账号）
      if (t.isNotEmpty && primaryToken.isNotEmpty && t != primaryToken) continue;
      rest.add(b);
    }
    if (hostPriority != null) {
      // 稳定排序：快的在前（实测结果），相同则保持面板给的顺序
      final indexed = <({String url, int pri, int idx})>[
        for (var i = 0; i < rest.length; i++)
          (url: rest[i], pri: hostPriority(rest[i]), idx: i),
      ]..sort((a, b) => a.pri != b.pri ? a.pri.compareTo(b.pri) : a.idx.compareTo(b.idx));
      for (final e in indexed) {
        add(e.url);
      }
    } else {
      for (final u in rest) {
        add(u);
      }
    }
    return out;
  }

  /// 依次尝试候选地址，返回第一个成功拿到"像订阅的内容"的结果。
  ///
  /// [looksUsable] 用于识别"连上了但不是订阅"（拦截页/HTML）；为空则只要请求成功就算可用。
  /// [onSuccess] 在成功时回调实际使用的地址（调用方据此记忆/落盘）。
  /// 全部失败抛出最后一次异常；候选为空时抛 [StateError]。
  static Future<({String url, String raw})> fetchFirst({
    required String primary,
    Iterable<String> backups = const [],
    String? preferred,
    int Function(String url)? hostPriority,
    required SubscribeFetch fetch,
    bool Function(String raw)? looksUsable,
    void Function(String url)? onSuccess,
    // 上限必须覆盖「面板下发的全部域名 + 上次记住的那个」：
    // 线上 `/user/subscribe` 会下发 5~6 个订阅域名（dy.moneyfly.top /
    // moneyfly.dpdns.org / sub.moneyfly.dpdns.org / new.moneyfly.dpdns.org /
    // sub.fastora.top / fastora.top）。旧上限 4 时，如果只有最后那个域名能用
    // （前面的都被屏蔽），客户端会**静默放弃**——而需求是「任意一个能拉到就行」。
    //
    // 但候选还会按**实测测速**重排（快的在前），于是"唯一能用的那个"完全可能被
    // 排到上限之外、永远轮不到（客户 henry11：直连 IP 的 ddns 域名在其网络不可达，
    // 只有 Cloudflare 那个能用）→ 上限放宽到 8，并且用"整体时间预算"来兜底：
    // 只要还没超预算就继续往下试，避免被排序+截断卡死，也不会无限拖。
    int maxAttempts = 8,
    Duration overallBudget = const Duration(seconds: 30),
  }) async {
    final list = candidates(
        primary: primary,
        backups: backups,
        preferred: preferred,
        hostPriority: hostPriority);
    if (list.isEmpty) {
      throw StateError('没有可用的订阅地址');
    }
    Object? lastError;
    var attempts = 0;
    final deadline = DateTime.now().add(overallBudget);
    for (final url in list) {
      if (attempts >= maxAttempts) break;
      // 至少试 2 个（单次连接超时 12s，2 次足够排除"只是这个域名慢/被墙"），
      // 之后按整体预算收敛
      if (attempts >= 2 && DateTime.now().isAfter(deadline)) break;
      attempts++;
      try {
        final raw = await fetch(url);
        if (raw.trim().isEmpty) {
          lastError = StateError('订阅地址返回空内容: $url');
          continue;
        }
        if (looksUsable != null && !looksUsable(raw)) {
          lastError = StateError('订阅地址返回的不是订阅内容: $url');
          continue;
        }
        onSuccess?.call(url);
        return (url: url, raw: raw);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('订阅地址全部不可用');
  }
}
