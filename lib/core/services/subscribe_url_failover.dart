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

import 'dart:async';

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

  /// 候选顺序：**当前线路改写的地址** → 上次成功的（若与主地址同属一份订阅）
  /// → 主地址 → 备用地址（去重）。
  static List<String> candidates({
    required String primary,
    Iterable<String> backups = const [],
    String? preferred,
    /// 按「用户在设置里选的服务器线路」改写过的订阅地址（只换域名，token 不变）。
    ///
    /// 必须排在 `preferred` **之前**：用户在设置里换线路后，订阅必须立即以新线路的
    /// 域名拉取；旧实现把「上次成功的旧域名地址」排第一，于是换线路后仍然先撞旧域名
    /// （旧域名往往正是打不开的那个）→ 要么等一次超时才换、要么直接报「拉取失败」。
    String? pinned,
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
    // pinned 只在「与主地址同一份订阅」时采用：避免拿别的账号的 token 去请求
    final pinnedToken = tokenOf(pinned ?? '');
    if (pinnedToken.isNotEmpty && pinnedToken == primaryToken) {
      add(pinned);
    }
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
  /// [pinned] 是「按当前服务器线路改写过域名」的订阅地址（见 [candidates]），
  /// 排在最前，保证换线路后立即以新域名拉取。
  /// [looksUsable] 用于识别"连上了但不是订阅"（拦截页/HTML）；为空则只要请求成功就算可用。
  /// [onSuccess] 在成功时回调实际使用的地址（调用方据此记忆/落盘）。
  /// [onAttemptFailed] 每次尝试失败都回调（地址 + 原因分类），供线路诊断（⑦）使用。
  /// 全部失败抛出最后一次异常；候选为空时抛 [StateError]。
  static Future<({String url, String raw})> fetchFirst({
    required String primary,
    Iterable<String> backups = const [],
    String? preferred,
    String? pinned,
    int Function(String url)? hostPriority,
    required SubscribeFetch fetch,
    bool Function(String raw)? looksUsable,
    void Function(String url)? onSuccess,
    void Function(String url, String reason)? onAttemptFailed,
    // 上限必须覆盖「面板下发的全部域名 + 上次记住的那个」：
    // 线上 `/user/subscribe` 会下发 5~8 个订阅域名（dy.moneyfly.top /
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
    /// **首个候选**（当前线路）的单独尝试上限：比常规连接超时（12s）短得多。
    ///
    /// 被墙的域名几乎都是"连接超时"，等满 12s 才换下一个是"点更新订阅像卡住"的
    /// 主因。5s 足够判定"这条线路现在打不开"，随即进入下面的并行竞速。
    Duration firstAttemptTimeout = const Duration(seconds: 5),
    /// 首个候选失败后**同时竞速**的候选数量（happy eyeballs）。
    ///
    /// 串行等待的代价是"每个不可达域名都要赔一次超时"；并行竞速后最坏等待约为
    /// 「首尝试超时 + 一个连接超时」，而不是「2 个连接超时」。代价是可能对同一份
    /// 订阅多发一个请求（GET，无害；面板的拉取计数会略增），因此宽度限制为 2。
    int raceWidth = 2,
  }) async {
    final list = candidates(
        primary: primary,
        backups: backups,
        preferred: preferred,
        pinned: pinned,
        hostPriority: hostPriority);
    if (list.isEmpty) {
      throw StateError('没有可用的订阅地址');
    }

    var attempts = 0;
    Object? lastError;
    final deadline = DateTime.now().add(overallBudget);

    /// 一次尝试：成功返回结果，失败返回 null 并回调失败原因
    Future<({String url, String raw})?> tryOnce(String url,
        {Duration? timeout}) async {
      attempts++;
      try {
        final Future<String> f = fetch(url);
        final raw = timeout == null ? await f : await f.timeout(timeout);
        if (raw.trim().isEmpty) {
          onAttemptFailed?.call(url, 'empty');
          lastError = StateError('订阅地址返回空内容: $url');
          return null;
        }
        final usable = looksUsable;
        if (usable != null && !usable(raw)) {
          onAttemptFailed?.call(url, 'content');
          lastError = StateError('订阅地址返回的不是订阅内容: $url');
          return null;
        }
        onSuccess?.call(url);
        return (url: url, raw: raw);
      } catch (e) {
        onAttemptFailed?.call(url, _classify(e));
        lastError = e;
        return null;
      }
    }

    /// 并行竞速：谁先拿到可用内容用谁；全部失败返回 null
    Future<({String url, String raw})?> race(List<String> urls) {
      final completer = Completer<({String url, String raw})?>();
      var pending = urls.length;
      for (final u in urls) {
        unawaited(tryOnce(u).then((r) {
          if (r != null) {
            if (!completer.isCompleted) completer.complete(r);
          } else if (--pending == 0) {
            if (!completer.isCompleted) completer.complete(null);
          }
        }));
      }
      return completer.future;
    }

    // ① 首个候选（当前线路 / 用户选的线路）单独先试，用更短的超时
    var idx = 0;
    final first = await tryOnce(list[idx], timeout: firstAttemptTimeout);
    if (first != null) return first;
    idx++;

    // ② 首尝试失败 → 接下来 raceWidth 个候选并行竞速
    while (idx < list.length && attempts < maxAttempts) {
      final batch = <String>[];
      for (var i = 0; i < raceWidth && idx + i < list.length; i++) {
        if (attempts + batch.length >= maxAttempts) break;
        batch.add(list[idx + i]);
      }
      if (batch.isEmpty) break;
      idx += batch.length;
      final won = batch.length == 1
          ? await tryOnce(batch.first)
          : await race(batch);
      if (won != null) return won;
      // 至少要试 2 个（单次超时可能是这个域名慢/被墙），之后按整体预算收敛
      if (attempts >= 2 && DateTime.now().isAfter(deadline)) break;
    }

    throw lastError ?? StateError('订阅地址全部不可用');
  }

  /// 失败原因分类（供线路诊断展示，客服一眼看出是"连不上"还是"返回的不是订阅"）
  static String _classify(Object e) {
    final s = e.toString().toLowerCase();
    if (e is TimeoutException || s.contains('timeout')) return 'timeout';
    if (s.contains('socket') || s.contains('connection')) return 'connect';
    if (s.contains('handshake') || s.contains('certificate')) return 'tls';
    if (s.contains('host') || s.contains('dns') || s.contains('name')) return 'dns';
    return 'error';
  }
}
