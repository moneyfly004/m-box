import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';

import '../api/api_client.dart';
import '../api/server_pool.dart';
import '../api/endpoints.dart';
import '../models/models.dart';
import 'app_log.dart';
import 'settings_store.dart';
import 'subscribe_url_failover.dart';
import 'subscription_cache.dart';

/// 订阅拿不到节点的**可区分原因**。
///
/// 为什么需要：历史上「更新订阅没有节点」在客户端是**全静默**的 —— 到期、
/// 未开通、订阅被停用、后端没给订阅地址、后端返回故障页，全都只返回空列表，
/// 用户看到的只有「没有可用节点」，既不知道原因也不知道下一步该做什么。
/// 这里把原因分类出来，UI 才能给出**能真正解决问题**的动作（续费 / 设备管理 /
/// 重新登录 / 重试）。
enum SubscribeIssue {
  /// 本机设备被移除（后端 403「已被移除并踢下线」）→ 重新登录以重新绑定本机
  deviceKicked,

  /// 套餐已到期 → 去续费
  expired,

  /// 尚未开通套餐 → 去开通
  noSubscription,

  /// 订阅被管理员停用 / 状态异常 → 联系客服
  subscriptionDisabled,

  /// 账号被禁用 → 联系客服
  accountDisabled,

  /// 设备数量已达上限 → 设备管理（删掉不再使用的设备）
  deviceFull,

  /// 有套餐但后端没下发订阅地址（异常）→ 重新登录 / 重试
  noSubscribeUrl,

  /// 登录态失效（401 / 令牌过期 / 未授权）→ 重新登录
  ///
  /// 为什么单列一类：旧实现把所有认不出的错误都归到 [network]，于是
  /// 「登录已过期」也被显示成「网络服务端异常，暂时拿不到最新订阅」——
  /// 用户反复重试、重装、换网络都没用（唯一出路是重新登录），客诉不断。
  authRequired,

  /// 网络 / 后端异常 → 重试
  network,

  /// 后端返回的不是订阅内容（故障页 / HTML / 跳登录）→ 已保留上次线路，可重试
  badContent,
}

/// 订阅服务：拉取订阅信息 → 获取 Clash YAML → 解析节点列表
///
/// 数据流（对应「运行拉取订阅并覆盖旧配置」要求）：
/// - 每次成功从网络拉取订阅 → 覆盖写入本地磁盘缓存（[SubscriptionCache]）
///   与内存缓存；
/// - 网络失败 → 回退读取本安装/本版本的有效本地缓存，保证登录后拿不到
///   节点时至少能看到最近一次成功拉到的线路（离线兜底，绝不静默空白）；
/// - 登出/切号 → [clearCache] 同时清内存与磁盘缓存，杜绝旧账号节点残留。
class SubscriptionService {
  SubscriptionService._();
  static final SubscriptionService instance = SubscriptionService._();

  List<ProxyNode> _cache = [];
  DateTime _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const _cacheTtl = Duration(minutes: 30);

  /// 最近一次成功拉取订阅的时间（首页「节点更新于 xx:xx」展示用）
  DateTime? get lastUpdatedAt {
    final t = _cacheTime;
    return t.millisecondsSinceEpoch <= 0 ? null : t;
  }

  /// 清缓存/登出代次：拉取在途期间登出 → 结果作废，禁止把旧账号数据写回
  /// 内存或磁盘缓存（防止登出竞态让旧缓存"复活"到下一个账号）
  int _epoch = 0;

  /// 拉取请求序号（见 [_pullAndCache]）：只允许最后一次发出的请求写缓存，
  /// 防止「准入状态变化前发出的旧请求」晚到后把老配置写回去。
  int _reqSeq = 0;

  /// 登出/切号时清空节点缓存（内存 + 磁盘），避免旧账号节点残留到新账号
  void clearCache() {
    _lastIssue = null;
    _deviceRejected = false;
    _epoch++;
    _cache = [];
    _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(SubscriptionCache.instance.clear());
  }

  /// 冷启动即时展示用：只读本地磁盘缓存并解析出节点，**不发任何网络请求**、
  /// 不改内存缓存/时间戳/代次。首页冷启动先用它秒显上次的线路（避免弱网下
  /// 干等 fetchInfo → 首页转圈/空白），随后由 fetchNodes(force:true) 后台
  /// 刷新覆盖。返回空列表表示无有效缓存（无缓存 / 版本过期 / 换号失效，
  /// 失效判定与删除由 SubscriptionCache.readLatest 内部完成）。
  ///
  /// 注意：这里读到的缓存**不经过账号门禁判定**（到期/禁用），因此仅用于
  /// UI 即时展示；真正能否连接仍由 AccountService 门禁 + fetchNodes 决定，
  /// 受限账号的 applySubscriptionNodes([]) 会清空展示，不会放行旧线路。
  Future<List<ProxyNode>> loadCachedNodes() async {
    try {
      final cached = await SubscriptionCache.instance.readLatest();
      if (cached == null || cached.raw.isEmpty) return const [];
      return await compute(_parseInIsolate, cached.raw);
    } catch (_) {
      return const [];
    }
  }

  /// 最近一次拉取「为什么没有节点」（成功拉到时清空）。UI 据此弹可操作提示。
  SubscribeIssue? get lastIssue => _lastIssue;
  SubscribeIssue? _lastIssue;

  /// 后端是否**真的拒绝**了本设备（而不是"设备数达到上限"这种信息层提示）。
  ///
  /// 判定依据是订阅响应本身：受限状态下面板只会下发 4 个"消息节点"
  /// （📢 官网 / ❌ 原因 / 💡 解决 / 💬 客服，server 均为 baidu.com:1234），
  /// 其中 ❌ 原因 写明原因。只有**拿到这种拒绝载荷**才拒绝连接：
  ///   - 上限 5 台时，第 1~5 台（含范围内的第 5 台）拿到的是真实节点 →
  ///     deviceRejected=false → 照常连接，只在界面上提示"已达上限，可升级"；
  ///   - 第 6 台拿到拒绝载荷（原因=设备数量超限）→ deviceRejected=true →
  ///     拒绝连接并引导升级设备/删除闲置设备。
  /// 与 [classifyFromInfo] 的区别：后者只看"当前设备数≥上限"这个数字，
  /// 范围内的第 N 台同样满足该条件，因此**不能**用它作为连接门禁。
  /// 后端**不再**拒绝本机时清掉粘滞标记。
  ///
  /// 场景（用户实测）：上限 1 台时第 2 台被拒 → deviceRejected=true、界面显示
  /// "升级/删除设备"；管理员随后把上限改成 500，若不清这个标记，客户端会一直
  /// 停在"被拒绝"状态（无法更新订阅、无法连接），看起来像被拉黑。
  /// 判定依据用**后端下发的数字**（current_devices < device_limit 即已放宽），
  /// 不用本地时间/本地计算。
  Future<void> clearRejectionIfInRange(SubscriptionInfo info) async {
    if (!_deviceRejected) return;
    final limit = info.deviceLimit;
    final current = info.currentDevices;
    final inRange = limit > 0 && current < limit;
    if (!inRange) return;
    _deviceRejected = false;
    _lastIssue = null;
    // 本类不是 ChangeNotifier；调用方（AccountService.refresh）随后会 notifyListeners，
    // UI 会按最新的 deviceRejected 重绘。
  }

  bool get deviceRejected => _deviceRejected;
  bool _deviceRejected = false;

  /// 原因分类：订阅信息 → 原因（null = 信息层面正常）。
  /// 与 [AccountService.classify] 的优先级保持一致（停用 > 到期 > 设备满 > 未开通），
  /// 避免同一个用户在两处被判成不同状态。
  static SubscribeIssue? classifyFromInfo(SubscriptionInfo s) {
    final subActive =
        s.isActive && (s.status.isEmpty || s.status.toLowerCase() == 'active');
    if (!subActive) return SubscribeIssue.subscriptionDisabled;
    if (s.isExpired) return SubscribeIssue.expired;
    if (s.deviceLimit > 0 && s.currentDevices >= s.deviceLimit) {
      return SubscribeIssue.deviceFull;
    }
    if (s.subscribeUrl.isEmpty) {
      // 有套餐（有到期时间/剩余天数）却没给订阅地址 = 后端异常；
      // 真·没套餐才是「未开通」
      return (s.remainingDays > 0 || s.expireTime != null)
          ? SubscribeIssue.noSubscribeUrl
          : SubscribeIssue.noSubscription;
    }
    return null;
  }

  /// 原因分类：错误文案 → 原因。
  static SubscribeIssue classifyFromError(String msg) {
    if (isKickedMessage(msg)) return SubscribeIssue.deviceKicked;
    if (_isDisableMessage(msg)) return SubscribeIssue.accountDisabled;
    final m = msg.toLowerCase();
    // 登录态失效：401 / 令牌过期 / 未授权 / 后端明确要求重新登录
    // （踢下线判定在上面已先行命中，不会被这里抢走）
    if (msg.contains('登录已过期') ||
        msg.contains('登录已失效') ||
        msg.contains('未授权') ||
        msg.contains('请重新登录') ||
        msg.contains('请登录') ||
        m.contains('unauthorized') ||
        m.contains('invalid token') ||
        m.contains('token expired') ||
        m.contains('token is expired')) {
      return SubscribeIssue.authRequired;
    }
    // 面板的下发文案有两种写法：「设备数量已达上限」与
    // 「设备数量超过限制(当前X/限制Y)」—— 两种都要认出来，否则会掉到 network
    if (msg.contains('设备') &&
        (msg.contains('上限') ||
            msg.contains('已达') ||
            msg.contains('超过限制') ||
            msg.contains('超限'))) {
      return SubscribeIssue.deviceFull;
    }
    if (m.contains('device limit') || m.contains('too many devices')) {
      return SubscribeIssue.deviceFull;
    }
    return SubscribeIssue.network;
  }

  /// 占位/消息节点判定：面板在下发信息节点与拒绝载荷时都用
  /// `{server: baidu.com, port: 1234, type: ss}` 这种"假节点"承载文案，
  /// 它们**不能**被连接（点了必然失败），只用于展示。
  static bool isMessageNode(ProxyNode n) =>
      n.server.trim().toLowerCase() == 'baidu.com' && n.port == 1234;

  /// 识别后端「拒绝载荷」：受限状态（设备超限/到期/失效/禁用…）时面板只下发
  /// 消息节点，其中 `❌ 原因: xxx` 写明原因。返回原因文案；不是拒绝载荷则 null。
  ///
  /// 入参是**订阅原文**而不是解析结果：解析器会把 server=baidu.com 的消息节点
  /// 过滤掉（用户点不到假节点，这是对的），解析完再看就什么都不剩了，
  /// 必须在原文里认这个标记。正常响应里没有 `❌ 原因:`。
  static final RegExp _rejectionReasonRe = RegExp(r'❌ 原因:([^"\r\n,}]*)');

  static String? rejectionReasonFromRaw(String raw) {
    final m = _rejectionReasonRe.firstMatch(raw);
    if (m == null) return null;
    final reason = (m.group(1) ?? '').trim();
    return reason.isEmpty ? '订阅不可用' : reason;
  }

  /// 拒绝原因 → 问题分类（连接门禁与提示文案共用）。
  static SubscribeIssue issueFromRejectionReason(String reason) {
    if (reason.contains('设备')) return SubscribeIssue.deviceFull;
    if (reason.contains('过期')) return SubscribeIssue.expired;
    if (reason.contains('失效') ||
        reason.contains('禁用') ||
        reason.contains('账户')) {
      return SubscribeIssue.subscriptionDisabled;
    }
    if (reason.contains('地址') || reason.contains('不存在')) {
      return SubscribeIssue.noSubscribeUrl;
    }
    return SubscribeIssue.badContent;
  }

  /// 可连接节点：拒绝载荷里那 4 个承载文案的"假节点"必须剔除，
  /// 否则用户会点到 server=baidu.com 的占位条目，连接必然失败。
  /// 正常载荷（reason == null）原样返回，不改变既有行为。
  static List<ProxyNode> connectableNodes(
          List<ProxyNode> nodes, String? rejectionReason) =>
      rejectionReason == null
          ? nodes
          : nodes.where((n) => !isMessageNode(n)).toList();

  @visibleForTesting
  set deviceRejected(bool v) => _deviceRejected = v;

  /// 订阅原文是否**看起来像**一份订阅（节点链接 / Clash YAML / JSON / base64）。
  ///
  /// 用途：区分两种「解析出 0 个节点」——
  ///   1) 后端**故意**下发的占位内容（到期/禁用场景）→ 必须覆盖本地旧配置；
  ///   2) 后端返回了故障页 / HTML 错误页 / 跳登录页 → **绝不能**据此清空用户的
  ///      线路（一次后端抖动就把用户的节点全抹掉，用户只会看到「没有节点」）。
  /// 订阅原文是否**看起来像**一份订阅（Clash YAML / base64 节点列表 / 明文节点链接 / 带订阅字段的 JSON）。
  ///
  /// 判据必须**结构化**。旧实现是「以 `{`/`[` 开头即算」「正文含 `://` 即算」——
  /// 而网关/WAF/运营商的 HTML 拦截页几乎都带 `https://…`，于是那份错误页被当成
  /// 「合法但空的订阅」：清空内存线路、**覆盖磁盘离线兜底缓存**，还把 `_lastIssue`
  /// 置空（首页一句提示都没有）→ 客户下次断网冷启动真的一片空白。
  static bool looksLikeSubscription(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false; // 空正文单独按「空订阅」处理，不算异常
    final lower = t.toLowerCase();
    // ① Clash 形态：必须是**行首的段名**（HTML/注释里出现的同名文字不算）
    if (RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(t) ||
        RegExp(r'^\s*proxy-providers\s*:', multiLine: true).hasMatch(t) ||
        lower.contains('"proxies"')) {
      return true;
    }
    // ② 明文节点链接：要求**行首**是已知协议（HTML 里的 href 不会在行首成段）
    if (_linkLineRe.hasMatch(t)) return true;
    // ③ base64 订阅：解出来必须含节点链接或 proxies: 段才算
    final compact = t.replaceAll(RegExp(r'\s'), '');
    if (compact.length > 24 &&
        RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(compact)) {
      try {
        final dec = utf8.decode(base64.decode(base64.normalize(compact)),
            allowMalformed: true);
        return _linkLineRe.hasMatch(dec) || dec.contains('proxies:');
      } catch (_) {}
    }
    // ④ 其余（JSON 信封、HTML 故障页、跳登录页…）一律不算订阅 —— 宁可当成
    //    「内容异常」保留用户已有线路，也不要拿错误页去覆盖它。
    return false;
  }

  /// 「行首是已知节点协议」的判据（多行；大小写不敏感）
  static final RegExp _linkLineRe = RegExp(
    r'^(vmess|vless|trojan|ss|ssr|socks|socks5|hysteria|hysteria2|hy2|tuic|anytls|wireguard)://',
    multiLine: true,
    caseSensitive: false,
  );

  /// 服务端给的**一句话**（JSON message 或短文本），而不是网关/WAF 的整页 HTML。
  /// 破坏性动作（断连 / 清缓存 / 拉黑）只允许在这句话上触发：旧实现在任意响应体
  /// 上做关键词匹配，一张恰好含 "removed" 的拦截页就能把客户正在用的连接断开。
  static bool _isServerSentence(String msg) {
    final s = msg.trim();
    if (s.isEmpty || s.length > 160) return false;
    if (s.startsWith('<') ||
        s.contains('<html') ||
        s.contains('<!DOCTYPE') ||
        s.contains('<body') ||
        s.contains('</')) {
      return false;
    }
    return true;
  }

  /// 获取订阅信息（XBoard 兼容 /user/subscribe）
  Future<SubscriptionInfo> fetchInfo() async {
    final data = await ApiClient.instance.get(Endpoints.userSubscribe);
    if (data is! Map) {
      return SubscriptionInfo(
        subscribeUrl: '',
        deviceLimit: 0,
        currentDevices: 0,
        remainingDays: 0,
        isExpired: true,
        isActive: false,
        status: '',
      );
    }
    return SubscriptionInfo.fromJson(Map<String, dynamic>.from(data));
  }

  /// 获取并解析节点列表（带 30 分钟内存缓存，force 强制刷新）。
  ///
  /// 账号可用性前置判定（重点修复「到期/禁用后仍加载旧配置」）：
  /// - 账号受限（到期 / 订阅被停用 / 账号被禁用）→ **先于任何缓存**清空
  ///   内存与磁盘缓存并返回空列表：更新订阅加载的是「失效状态」，绝不加载
  ///   到期前拉到并存下来的老配置，也绝不回退本地磁盘缓存；
  /// - 账号正常：force 刷新 → 成功覆盖内存与磁盘缓存；网络/后端失败 →
  ///   回退本地缓存（仅当缓存属于当前安装且版本匹配），保证「运行即拉新
  ///   订阅覆盖旧配置」，断网时也不至于登录后一片空白。
  /// 订阅同步中（含拉取 + 解析）。UI 用它显示「正在同步订阅…」：
  /// 刚登录 / 刚刷新时这是**过程**，不该被展示成错误。
  /// 放在这里而不是各调用点 —— fetchNodes 是所有订阅拉取的唯一收口。
  final ValueNotifier<bool> syncing = ValueNotifier<bool>(false);
  int _syncingDepth = 0;

  void _enterSync() {
    _syncingDepth++;
    syncing.value = true;
  }

  void _exitSync() {
    _syncingDepth--;
    if (_syncingDepth <= 0) {
      _syncingDepth = 0;
      syncing.value = false;
    }
  }

  Future<List<ProxyNode>> fetchNodes({bool force = false}) async {
    final epoch = _epoch;
    _enterSync();
    try {
      final info = await fetchInfo();
      _lastIssue = classifyFromInfo(info);
      if (info.subscribeUrl.isEmpty) return [];
      if (!info.hasSubscription) {
        // 到期 / 订阅被停用 / 状态异常：清空缓存，加载「失效」而非老配置
        _dropAllCaches();
        return [];
      }
      // 账号正常且内存缓存仍在 30 分钟 TTL 内 → 直接返回缓存
      // （判定放在缓存命中之前：禁止用「到期前的缓存」跳过到期判定）
      // 被后端拒绝 / 账号受限时**不吃节点缓存**：这类状态最需要"后台一改就跟着变"
      // （例如上限从 1 改成 500 后要立刻能重新拉到真实节点），
      // 30 分钟缓存会让用户以为"永远恢复不了"。
      final deviceLimited = _deviceRejected ||
          (info.deviceLimit > 0 && info.currentDevices >= info.deviceLimit);
      if (!force &&
          !deviceLimited &&
          _cache.isNotEmpty &&
          DateTime.now().difference(_cacheTime) < _cacheTtl) {
        return List.of(_cache);
      }
      return await _pullAndCache(info, epoch);
    } catch (e) {
      final msg = ApiClient.errorMsg(e);
      _lastIssue = classifyFromError(msg);
      // 账号被禁用：后端业务接口统一 403「账户已被禁用…」→ 视为受限，
      // 清空缓存返回空，避免把禁用误当网络错误后回退到老配置
      if (_lastIssue == SubscribeIssue.accountDisabled) {
        _dropAllCaches();
        return [];
      }
      // 设备被踢下线：后端对「被删除设备的订阅请求」返回 403
      // 「此设备已被移除并踢下线…」→ 清空本地订阅缓存（该设备不能再
      // 使用任何旧配置），断开与提示由调用方（UI / 调度器）处理
      if (_lastIssue == SubscribeIssue.deviceKicked) {
        _dropAllCaches();
      }
      // 其余失败（断网/超时/服务端异常）：缓存新鲜（TTL 内）时回退内存缓存，
      // 保证离线不丢已拉到的线路；缓存过期则按原错误抛出由调用方提示
      if (!force &&
          _cache.isNotEmpty &&
          DateTime.now().difference(_cacheTime) < _cacheTtl) {
        return List.of(_cache);
      }
      rethrow;
    } finally {
      _exitSync();
    }
  }

  /// 错误文案是否命中「设备被踢下线」（后端删除设备后的订阅 403 提示）。
  /// 供 UI/调度器识别后断开连接、清空节点并提示用户。
  static bool isKickedMessage(String msg) =>
      _isServerSentence(msg) &&
      (msg.contains('已被移除') ||
       msg.contains('踢下线') ||
       msg.toLowerCase().contains('removed') ||
       msg.toLowerCase().contains('kicked'));

  /// 拉取订阅原文 → 后台解析 → 校验 epoch/请求序号后覆盖内存与磁盘缓存
  Future<List<ProxyNode>> _pullAndCache(
      SubscriptionInfo info, int epoch) async {
    // 请求序号：同一账号下可能并发拉取（手动刷新 + 定时刷新 + 回前台 + 购买后
    // 刷新）。没有序号时「谁最后返回谁说了算」——一个在准入状态变化前发出的旧
    // 请求，可能在「到期/禁用后已返回占位节点」的新请求之后落地，把老配置写回去，
    // 使过期用户重新拿到可用线路。序号让**过期的在途结果一律作废**。
    final seq = ++_reqSeq;
    // 订阅地址轮换：主地址打不开（域名被墙/线路不通）时自动改试备用地址。
    // 顺序 = 上次成功的地址 → 主地址 → 备用地址（后端 subscribe_urls 下发）；
    // 全部失败才回退本地缓存；实际使用的地址会写进磁盘缓存，下次优先使用。
    final cachedLatest = await SubscriptionCache.instance.readLatest();
    final preferred = (cachedLatest != null &&
            SubscribeUrlFailover.tokenOf(cachedLatest.subscribeUrl) ==
                SubscribeUrlFailover.tokenOf(info.subscribeUrl))
        ? cachedLatest.subscribeUrl
        : null;
    // **当前服务器线路优先**（用户在设置里换过线路时尤其重要）：
    // 把后端下发的订阅地址改写到当前线路的域名（token 不变，同一份订阅），
    // 让它排在最前。否则换线路后仍会先试「上次成功的旧域名地址」——
    // 而用户换线路通常正是因为旧域名在其网络打不开，结果就是"换了线路还是拉取失败"。
    final pinned = _pinToActiveLine(info.subscribeUrl);

    String raw;
    var usedSubscribeUrl = info.subscribeUrl;
    try {
      final fetched = await SubscribeUrlFailover.fetchFirst(
        primary: info.subscribeUrl,
        backups: info.subscribeUrls,
        preferred: preferred,
        pinned: pinned,
        // 谁快用谁：用客户端域名实测结果排序（国内各地 ISP 差别大，实测优先）。
        // priorityOfHost 里已包含"刚失败的域名排到最后"的冷却惩罚（③）。
        hostPriority: (u) =>
            ServerPool.instance.priorityOfHost(Uri.tryParse(u)?.host ?? ''),
        fetch: _fetchSubscribeUrl,
        // 连上了但返回的不是订阅内容（机房拦截页/运营商提示页常是 200 + HTML）
        // → 视为该地址失败，继续换下一个，避免用户拿到解析不出节点的"空订阅"
        looksUsable: looksLikeSubscription,
        // 线路诊断（⑦）：哪个域名、什么原因失败 —— 写运行日志，日志中心可见
        onAttemptFailed: _noteLineFailure,
      );
      raw = fetched.raw;
      usedSubscribeUrl = fetched.url;
    } catch (e) {
      // 所有地址都失败 → 回退本地缓存（同一份订阅即可，域名不同也算）
      //
      // 但**拒绝载荷不能当内容回退**：面板在「超限/到期/禁用」时下发的是
      // 4 个消息节点（❌ 原因…）。这种内容一旦被当成"可用缓存"回退，用户就会
      // 永久停在"设备数量超限/无法拉取订阅"——即使后台早已把上限调好。
      // 用户实测（账号 henry11）：能访问 API 域名，但拉节点的订阅域名在其网络
      // 不可达 → 全部地址失败 → 静默回退到旧的拒绝载荷 → 一直显示超限，
      // 而服务端根本收不到任何拉取请求（日志里 0 次）。
      final cachedIsRejection = cachedLatest != null &&
          rejectionReasonFromRaw(cachedLatest.raw) != null;
      if (cachedLatest == null ||
          cachedIsRejection ||
          SubscribeUrlFailover.tokenOf(cachedLatest.subscribeUrl) !=
              SubscribeUrlFailover.tokenOf(info.subscribeUrl)) {
        // 明确暴露"订阅地址都打不开"，而不是静默给旧内容：
        // UI 据此提示，首页限制状态自动重试会把恢复做掉
        _lastIssue = SubscribeIssue.network;
        rethrow;
      }
      raw = cachedLatest.raw;
      usedSubscribeUrl = cachedLatest.subscribeUrl;
    }
    // 订阅地址轮换兜底：续费/换套餐/后台重建订阅后 subscribe_url 可能变化，
    // 旧地址会 403/404 —— 这里重新问一次订阅信息，拿到新地址就再试一次，
    // 避免用户「续了费还是拿不到节点」（必须重新登录才能恢复的体验）
    try {
      if (raw.trim().isEmpty) {
        final fresh = await fetchInfo();
        if (fresh.subscribeUrl.isNotEmpty &&
            fresh.subscribeUrl != info.subscribeUrl) {
          final again = await SubscribeUrlFailover.fetchFirst(
            primary: fresh.subscribeUrl,
            backups: fresh.subscribeUrls,
            // 续费/重建订阅后的新地址同样要按当前线路改写域名
            pinned: _pinToActiveLine(fresh.subscribeUrl),
            fetch: _fetchSubscribeUrl,
            looksUsable: looksLikeSubscription,
            onAttemptFailed: _noteLineFailure,
          );
          raw = again.raw;
          usedSubscribeUrl = again.url;
        }
      }
    } catch (_) {}
    // 大订阅解析放到后台 isolate，避免阻塞 UI 线程
    final nodes = await compute(_parseInIsolate, raw);
    if (nodes.isEmpty && raw.trim().isNotEmpty && !looksLikeSubscription(raw)) {
      // 后端返回的不是订阅内容（故障页/HTML/跳登录）→ 别拿它清空用户线路
      _lastIssue = SubscribeIssue.badContent;
      return List.of(_cache);
    }
    // 拉取期间发生登出/清缓存（epoch 变化）或已有更新的请求发出 → 结果作废：
    // **返回空而不是旧节点**。旧实现返回 nodes，会让「已过期/已禁用账号的
    // 在途旧请求」把可用线路重新注入连接器，绕过准入闸门。
    if (epoch != _epoch || seq != _reqSeq) return const [];
    // 后端「拒绝载荷」处理：面板在受限状态下只下发消息节点（❌ 原因 写明缘由）。
    // 这一步把「真·被拒绝」与「设备数已达上限但本机仍在范围内」彻底分开：
    //   - 有 ❌ 原因 → 确实拒绝：过滤掉不可连接的假节点（留给 UI 展示原因），
    //     记录 deviceRejected，只有这种情况才允许连接门禁拦人；
    //   - 无 ❌ 原因 → 正常响应（含范围内的第 N 台）→ deviceRejected 清零。
    final reason = rejectionReasonFromRaw(raw);
    if (reason != null) {
      final real = connectableNodes(nodes, reason);
      _deviceRejected = true;
      _lastIssue = issueFromRejectionReason(reason);
      _cache = real;
      _cacheTime = DateTime.now();
      // 拒绝载荷**不写磁盘缓存**：它只是"此刻被拒"的快照，写进去以后一旦
      // 订阅域名不可达，回退分支就会把它当成可用内容（见上面的 cachedIsRejection
      // 判定）。内存里保留（本次会话展示原因），磁盘不落。
      if (rejectionReasonFromRaw(raw) == null) {
        await SubscriptionCache.instance
            .write(subscribeUrl: usedSubscribeUrl, raw: raw);
      }
      return real;
    }
    _deviceRejected = false;
    // 注意：这里**不因「解析结果为空」而跳过覆盖**。订阅是准入闸门的执行者：
    // 到期/被禁用/未开通套餐时后端返回占位（虚假）节点，必须覆盖掉本地老配置，
    // 否则老用户能继续用缓存里的可用线路。每次成功拉取都要覆盖内存与磁盘缓存。
    _cache = nodes;
    _cacheTime = DateTime.now();
    // 串行写完磁盘缓存再返回：保证「登出删除磁盘缓存」发生在成功写入之后，
    // 杜绝删完又被异步写回旧数据的竞态。
    // 这里存**实际取到内容的那个地址**（可能是轮换后的备用域名）：下次拉取
    // 会优先用它，避免每次都先撞一遍打不开的主域名。
    await SubscriptionCache.instance
        .write(subscribeUrl: usedSubscribeUrl, raw: raw);
    _lastIssue = null;
    return nodes;
  }

  /// 判定错误文案是否命中「禁用/封禁」（账号不可用类，需与
  /// [AccountService] 判定口径一致；放这里避免循环依赖）
  static bool _isDisableMessage(String msg) {
    if (!_isServerSentence(msg)) return false;
    final m = msg.toLowerCase();
    return msg.contains('禁用') ||
        msg.contains('禁止') ||
        m.contains('disabled') ||
        m.contains('banned');
  }

  /// 账号受限：清空内存与磁盘缓存（磁盘删除尽力而为，不阻塞主流程）
  void _dropAllCaches() {
    // 递增代次：作废所有在途拉取 —— 受限清缓存后，任何尚未完成的旧请求
    // （旧 epoch）都不能再把数据写回内存/磁盘缓存（防"清完又复活"）
    _epoch++;
    _cache = [];
    _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(SubscriptionCache.instance.clear());
  }

  /// 拉订阅正文的统一入口：**成功/失败都记到线路池**（③ 冷却 + ⑦ 诊断）。
  ///
  /// 成功 → 立即解除该域名的失败冷却（下次优先用它）；
  /// 失败 → 进入冷却（10 分钟内降级为兜底项，避免每次刷新都白等一次超时）。
  static Future<String> _fetchSubscribeUrl(String url) async {
    try {
      final raw =
          await ApiClient.instance.fetchText(url, ua: await _subscriptionUa());
      ServerPool.instance.noteDomainSuccess(url);
      // ② 若"用户选的线路"没用上（自动兜底到别的域名），置位一次性提示
      ServerPool.instance.noteEffectiveLine(url);
      AppLog.log('LINE',
          '订阅拉取成功：${Uri.tryParse(url)?.host ?? url}（${raw.length} 字节）');
      return raw;
    } catch (e) {
      // 具体原因由 onAttemptFailed（_noteLineFailure）分类记录，这里只补异常文本
      AppLog.log('LINE', '订阅拉取异常：${Uri.tryParse(url)?.host ?? url} → $e');
      rethrow;
    }
  }

  /// 单次尝试失败 → 域名冷却 + 运行日志（客服可见：哪个域名、什么原因）
  static void _noteLineFailure(String url, String reason) {
    final host = Uri.tryParse(url)?.host ?? url;
    ServerPool.instance.noteDomainFailure(url, kind: reason);
    AppLog.log('LINE', '订阅地址不可用 [$reason]：$host');
  }

  /// 把订阅地址改写到**当前生效的服务器线路**域名（同 token，同一份订阅）。
  ///
  /// 返回空串表示无需/无法改写（已是当前线路、地址不合法、拿不到线路地址）。
  /// 只有地址里带 token 时才改写：没有 token 的地址（自建面板的固定路径）换域名
  /// 未必存在，保持原样交给轮换逻辑处理。
  static String _pinToActiveLine(String subscribeUrl) {
    if (SubscribeUrlFailover.tokenOf(subscribeUrl).isEmpty) return '';
    try {
      return ServerPool.instance.rewriteToActiveLine(subscribeUrl);
    } catch (_) {
      return '';
    }
  }

  /// 拉取订阅原文（单地址，失败回退同一份订阅的本地缓存）。
  ///
  /// 主流程已改为 [SubscribeUrlFailover.fetchFirst] 的多地址轮换（见 [_pullAndCache]）；
  /// 本方法是"只取一个地址、不做轮换"的变体，供分享/导出与测试使用。
  Future<String> fetchRawWithCacheFallback(String subscribeUrl) async {
    try {
      return await ApiClient.instance
          .fetchText(subscribeUrl, ua: await _subscriptionUa());
    } catch (e) {
      final cached = await SubscriptionCache.instance.readLatest();
      if (cached == null ||
          SubscribeUrlFailover.tokenOf(cached.subscribeUrl) !=
              SubscribeUrlFailover.tokenOf(subscribeUrl)) {
        rethrow;
      }
      return cached.raw;
    }
  }

  /// 订阅自定义 UA（设置为空时返回 null → 用默认 MoneyFly/<版本>）。
  /// 部分机场按 UA 返回不同客户端格式，用户需要能自救。
  static Future<String?> _subscriptionUa() async {
    try {
      final s = await SettingsStore.instance.load();
      final ua = (s['subscribeUserAgent']?.toString() ?? '').trim();
      return ua.isEmpty ? null : ua;
    } catch (_) {
      return null;
    }
  }

  /// 面板展示性伪节点过滤（📢官网 / ⏰到期 / 📱设备 / 💬客服 等，server 为 baidu.com 占位）。
  /// 口径收敛到 [isPanelPseudoNode]：测速侧必须用同一判据跳过这些占位项
  /// （否则会被当成「超快节点」或在内核里 404，两种测速方式结果互相矛盾）。
  static bool _isPanelPseudoNode(ProxyNode n) => n.isPanelPseudo;

  /// isolate 入口（compute 要求顶层/静态函数）
  static List<ProxyNode> _parseInIsolate(String raw) => parseClashYaml(raw);

  /// base64 里需要忽略的「噪声字符」：空白（换行 / CR / 制表 / 空格）、
  /// 零宽空格与 BOM。订阅面板导出时经常折行、末尾带 `\n`。
  static final RegExp _b64Noise = RegExp(r'[\s\u200b\ufeff]+');

  /// 宽松 base64 解码（返回 null 表示确实解不出来）。
  ///
  /// Dart 的 `base64.normalize` 遇到**任何**非 base64 字符会直接抛
  /// `FormatException`（它只负责把 URL-safe 字母表归一化，不剥离空白）。
  /// 而机场订阅几乎都是「一整行 base64 + 结尾换行」，长串还会按 76 字符
  /// 折行。旧实现拿**未清洗**的原文调用 normalize，异常又被 `catch (_) {}`
  /// 吞掉 → text 退回 base64 原文 → 逐行 `_parseLink` 全部落空 →
  /// **整份订阅静默解析成 0 个节点**（用户看到「没有节点 / 测不了速」，
  /// 日志里却没有任何报错）。
  ///
  /// 这里先清洗空白、归一化 URL-safe 字母表、补齐缺失的 `=` 填充，
  /// 兼容「无填充」「折行」「带 BOM」等真实面板产物。
  static String? _b64DecodeLoose(String raw) {
    var s = raw.replaceAll(_b64Noise, '');
    if (s.isEmpty) return null;
    s = s.replaceAll('-', '+').replaceAll('_', '/');
    final rem = s.length % 4;
    if (rem == 1) return null; // 长度不可能合法，别浪费时间
    if (rem > 0) s = s.padRight(s.length + (4 - rem), '=');
    try {
      return utf8.decode(base64.decode(s));
    } catch (_) {
      try {
        // 少量面板会混入非法字节（如 GBK 注释），别因此丢掉全部节点
        return utf8.decode(base64.decode(s), allowMalformed: true);
      } catch (_) {
        return null;
      }
    }
  }

  /// 解析 Clash YAML 中的 proxies
  static List<ProxyNode> parseClashYaml(String raw) {
    if (raw.trim().isEmpty) return [];
    dynamic doc;
    try {
      doc = loadYaml(raw);
    } catch (_) {
      return parseBase64Nodes(raw);
    }
    if (doc is! Map) {
      // loadYaml 对「base64 原文 / 明文 vmess:// 链接列表 / 其它非映射文本」
      // 不抛异常而是返回一个 String 标量 —— 以前直接 return []，最常见的
      // 两种 v2ray 订阅形态(base64 串、链接列表)会被静默丢成空列表。
      // 这里交给 base64/链接解析兜底，解析不到自然返回空。
      final nodes = parseBase64Nodes(raw);
      if (nodes.isNotEmpty) return nodes;
      // 还有面板把**整份 Clash YAML** base64 后再下发，这里补一层解码。
      final decoded = _b64DecodeLoose(raw);
      if (decoded != null && decoded.contains('proxies:')) {
        try {
          final inner = loadYaml(decoded);
          if (inner is Map && inner['proxies'] is List) {
            return _nodesFromYamlMap(inner);
          }
        } catch (_) {}
      }
      return nodes;
    }
    return _nodesFromYamlMap(doc);
  }

  static List<ProxyNode> _nodesFromYamlMap(Map<dynamic, dynamic> doc) {
    final proxies = doc['proxies'];
    if (proxies is! List) return [];
    return proxies
        .whereType<Map>()
        .map((e) => ProxyNode.fromClashMap(Map<String, dynamic>.from(e)))
        .where((n) => n.server.isNotEmpty && n.port > 0)
        .where((n) => !_isPanelPseudoNode(n))
        .toList();
  }

  /// 兼容 base64 / 明文链接列表：vmess / vless / trojan / ss / socks5 /
  /// hysteria2（含 `hy2://` 简写）/ tuic / anytls 等，统一转成 mihomo 认识的
  /// Clash map。
  static List<ProxyNode> parseBase64Nodes(String raw) {
    String text = raw;
    final decoded = _b64DecodeLoose(raw);
    if (decoded != null && decoded.contains('://')) text = decoded;
    final nodes = <ProxyNode>[];
    for (final line in text.split('\n')) {
      final s = line.trim();
      if (s.isEmpty) continue;
      final n = _parseLink(s);
      if (n != null) nodes.add(n);
    }
    return nodes;
  }

  static ProxyNode? _parseLink(String s) {
    if (s.startsWith('vmess://')) return _parseVmess(s);
    if (s.startsWith('vless://')) return _parseVless(s);
    if (s.startsWith('trojan://')) return _parseTrojan(s);
    if (s.startsWith('ss://')) return _parseSs(s);
    if (s.startsWith('ssr://')) return _parseSsr(s);
    if (s.startsWith('socks://') || s.startsWith('socks5://')) return _parseSocks(s);
    // `hy2://` 是 sing-box / v2rayN 生态通用的 hysteria2 简写，参数与
    // hysteria2:// 完全一致。旧实现只认长写法 → 整份订阅里所有 hy2 节点被
    // 静默丢弃（本次 zefly 订阅 69 节点中 17 个 hy2 全丢）。
    if (s.startsWith('hysteria2://') || s.startsWith('hy2://')) {
      return _parseHysteria2(s);
    }
    if (s.startsWith('hysteria://')) return _parseHysteria(s);
    if (s.startsWith('tuic://')) return _parseTuic(s);
    if (s.startsWith('anytls://')) return _parseAnyTls(s);
    if (s.startsWith('wireguard://')) return _parseWireguard(s);
    return null;
  }

  /// host:port → (host, port)；IPv6（[::1]:443）与非法端口返回 null
  static (String, int)? _hostPort(String s) {
    final colon = s.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(s.substring(colon + 1));
    if (port == null || port <= 0) return null;
    return (s.substring(0, colon), port);
  }

  /// query 字符串 → 已解码的键值对（URL 解码 key/value）
  static Map<String, String> _queryParams(String q) {
    final params = <String, String>{};
    for (final kv in q.split('&')) {
      if (kv.isEmpty) continue;
      final i = kv.indexOf('=');
      final k = i >= 0 ? kv.substring(0, i) : kv;
      final v = i >= 0 ? kv.substring(i + 1) : '';
      params[Uri.decodeQueryComponent(k)] = Uri.decodeQueryComponent(v);
    }
    return params;
  }

  /// 安全的 URL 解码：非法百分号编码（如裸中文 tag）回退原串，不丢节点
  static String _safeDecode(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  /// base64url 解码（SSR 各字段用 base64url、无 padding）；非 base64 原样返回
  static String _b64UrlDecode(String s) {
    if (s.isEmpty) return '';
    return _b64DecodeLoose(s) ?? s;
  }

  static String? _uriTag(String uri) {
    final hash = uri.indexOf('#');
    return hash >= 0 ? _safeDecode(uri.substring(hash + 1)) : null;
  }

  /// 解析 `scheme://cred@host:port?query#tag`（不含 ss/socks 的 base64 userinfo 特例）
  static ({String cred, String host, int port, Map<String, String> q})?
      _parseUserinfoUri(String scheme, String uri) {
    // 按 URI 自己声明的协议长度切前缀，**不能**按传入的 scheme 长度切：
    // `hy2://` 与 `hysteria2://` 指向同一个解析器，用后者长度(12)去切前者的
    // 链接(6)会多切 6 个字符 —— UUID 密码被静默截成半截，节点永远连不上。
    final sep = uri.indexOf('://');
    final without = uri.substring(sep >= 0 ? sep + 3 : '$scheme://'.length);
    final hash = without.indexOf('#');
    final body = hash >= 0 ? without.substring(0, hash) : without;
    final at = body.indexOf('@');
    if (at < 0) return null;
    final cred = body.substring(0, at);
    final rest = body.substring(at + 1);
    final qm = rest.indexOf('?');
    final hostPort = qm >= 0 ? rest.substring(0, qm) : rest;
    final hp = _hostPort(hostPort);
    if (hp == null) return null;
    final q = qm >= 0 ? _queryParams(rest.substring(qm + 1)) : <String, String>{};
    return (cred: cred, host: hp.$1, port: hp.$2, q: q);
  }

  static ProxyNode? _parseVmess(String uri) {
    try {
      final b64 = uri.substring('vmess://'.length).split('#').first;
      final decoded = _b64DecodeLoose(b64);
      if (decoded == null) return null;
      final m = jsonDecode(decoded) as Map<String, dynamic>;
      final tag = _uriTag(uri) ?? m['ps']?.toString() ?? 'vmess';
      final server = m['add']?.toString() ?? '';
      final port = int.tryParse(m['port']?.toString() ?? '') ?? 0;
      final uuid = m['id']?.toString() ?? '';
      final tls = m['tls']?.toString() == 'tls';
      final net = m['net']?.toString() ?? 'tcp';
      final sni = m['sni']?.toString();
      // 转成 mihomo 标准 vmess map：避免 vmess JSON 的 `type`(加密) 与
      // mihomo 的 `type`(协议) 冲突导致内核把节点当成 type=none 而加载失败
      final raw = <String, dynamic>{
        'name': tag,
        'type': 'vmess',
        'server': server,
        'port': port,
        'uuid': uuid,
        'alterId': int.tryParse(m['aid']?.toString() ?? '') ?? 0,
        'cipher': m['scy']?.toString() ?? 'auto',
      };
      if (tls) {
        raw['tls'] = true;
        if (sni != null && sni.isNotEmpty) raw['servername'] = sni;
        if (m['alpn']?.toString().isNotEmpty == true) {
          raw['alpn'] = m['alpn']!.toString().split(',');
        }
        if (m['fp']?.toString().isNotEmpty == true) raw['client-fingerprint'] = m['fp'];
      }
      if (net != 'tcp') raw['network'] = net;
      if (net == 'ws') {
        final wsOpts = <String, dynamic>{
          if (m['path']?.toString().isNotEmpty == true) 'path': m['path'],
        };
        if (m['host']?.toString().isNotEmpty == true) {
          wsOpts['headers'] = {'Host': m['host']};
        }
        if (wsOpts.isNotEmpty) raw['ws-opts'] = wsOpts;
      } else if (net == 'grpc') {
        raw['grpc-opts'] = {'grpc-service-name': m['path']?.toString() ?? ''};
      } else if (net == 'h2' || net == 'httpupgrade') {
        final opts = <String, dynamic>{
          if (m['path']?.toString().isNotEmpty == true) 'path': m['path'],
          if (m['host']?.toString().isNotEmpty == true) 'host': [m['host']],
        };
        raw[net == 'h2' ? 'h2-opts' : 'ws-opts'] = opts;
      }
      return ProxyNode(
        tag: tag,
        type: 'vmess',
        server: server,
        port: port,
        uuid: uuid,
        cipher: raw['cipher']?.toString(),
        tls: tls,
        sni: sni,
        network: net,
        wsPath: m['path']?.toString(),
        host: m['host']?.toString(),
        raw: raw,
      );
    } catch (_) {
      return null;
    }
  }

  static ProxyNode? _parseVless(String uri) {
    final p = _parseUserinfoUri('vless', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'vless';
    final security = p.q['security'] ?? '';
    final tls = security == 'tls' || security == 'reality' || p.q['tls'] == '1';
    final net = p.q['type'] ?? 'tcp';
    final sni = p.q['sni'] ?? p.q['peer'] ?? p.q['host'];
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'vless',
      'server': p.host,
      'port': p.port,
      'uuid': p.cred,
    };
    if (tls) {
      raw['tls'] = true;
      if (sni != null && sni.isNotEmpty) raw['servername'] = sni;
      if ((p.q['fp'] ?? '').isNotEmpty) raw['client-fingerprint'] = p.q['fp'];
    }
    if (security == 'reality') {
      final pbk = p.q['pbk'];
      final sid = p.q['sid'];
      if (pbk != null && pbk.isNotEmpty) {
        raw['reality-opts'] = {
          'public-key': pbk,
          if (sid != null && sid.isNotEmpty) 'short-id': sid,
        };
      }
    }
    if (net != 'tcp') raw['network'] = net;
    if (net == 'ws') {
      final wsOpts = <String, dynamic>{
        if ((p.q['path'] ?? '').isNotEmpty) 'path': p.q['path'],
      };
      if ((p.q['host'] ?? '').isNotEmpty) wsOpts['headers'] = {'Host': p.q['host']};
      if (wsOpts.isNotEmpty) raw['ws-opts'] = wsOpts;
    } else if (net == 'grpc') {
      raw['grpc-opts'] = {'grpc-service-name': p.q['serviceName'] ?? ''};
    }
    if ((p.q['flow'] ?? '').isNotEmpty) raw['flow'] = p.q['flow'];
    if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1') {
      raw['skip-cert-verify'] = true;
    }
    return ProxyNode(
      tag: tag,
      type: 'vless',
      server: p.host,
      port: p.port,
      uuid: p.cred,
      tls: tls,
      sni: sni,
      network: net,
      wsPath: p.q['path'],
      host: p.q['host'],
      flow: p.q['flow'],
      raw: raw,
    );
  }

  static ProxyNode? _parseTrojan(String uri) {
    final p = _parseUserinfoUri('trojan', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'trojan';
    final sni = p.q['sni'] ?? p.q['peer'];
    final net = p.q['type'] ?? 'tcp';
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'trojan',
      'server': p.host,
      'port': p.port,
      'password': p.cred,
    };
    if (sni != null && sni.isNotEmpty) raw['sni'] = sni;
    if ((p.q['alpn'] ?? '').isNotEmpty) raw['alpn'] = p.q['alpn']!.split(',');
    if ((p.q['fp'] ?? '').isNotEmpty) raw['client-fingerprint'] = p.q['fp'];
    if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1') {
      raw['skip-cert-verify'] = true;
    }
    if (net != 'tcp') raw['network'] = net;
    if (net == 'ws') {
      final wsOpts = <String, dynamic>{
        if ((p.q['path'] ?? '').isNotEmpty) 'path': p.q['path'],
      };
      if ((p.q['host'] ?? '').isNotEmpty) wsOpts['headers'] = {'Host': p.q['host']};
      if (wsOpts.isNotEmpty) raw['ws-opts'] = wsOpts;
    } else if (net == 'grpc') {
      raw['grpc-opts'] = {'grpc-service-name': p.q['serviceName'] ?? ''};
    }
    return ProxyNode(
      tag: tag,
      type: 'trojan',
      server: p.host,
      port: p.port,
      password: p.cred,
      tls: true,
      sni: sni,
      network: net,
      wsPath: p.q['path'],
      host: p.q['host'],
      raw: raw,
    );
  }

  /// 解析 Shadowsocks 链接，兼容两种主流格式：
  /// - SIP002：`ss://base64(method:password)@host:port#tag`（userinfo 是 base64）
  /// - legacy：`ss://base64(method:password@host:port)#tag`（整串 base64）
  static ProxyNode? _parseSs(String uri) {
    try {
      final withoutScheme = uri.substring('ss://'.length);
      final hash = withoutScheme.indexOf('#');
      final tag = hash >= 0 ? _safeDecode(withoutScheme.substring(hash + 1)) : 'ss';
      var body = hash >= 0 ? withoutScheme.substring(0, hash) : withoutScheme;
      // legacy：整串 base64，无明文 @ → 先整体解出 method:password@host:port
      if (!body.contains('@')) {
        body = _b64DecodeLoose(body) ?? body;
      }
      final at = body.indexOf('@');
      if (at < 0) return null;
      final credPart = body.substring(0, at);
      final hp = _hostPort(body.substring(at + 1).split('?').first);
      if (hp == null) return null;
      // SIP002 的 userinfo 是 base64(method:password)；legacy 已是明文
      var cred = credPart;
      if (!cred.contains(':')) {
        cred = _b64DecodeLoose(cred) ?? cred;
      }
      final sep = cred.indexOf(':');
      final method = sep > 0 ? cred.substring(0, sep) : cred;
      final password = sep >= 0 ? cred.substring(sep + 1) : '';
      return ProxyNode(
        tag: tag,
        type: 'ss',
        server: hp.$1,
        port: hp.$2,
        cipher: method,
        password: password,
        raw: {
          'name': tag,
          'type': 'ss',
          'server': hp.$1,
          'port': hp.$2,
          'cipher': method,
          'password': password,
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// socks5：`socks://base64(user:pass)@host:port#tag`（userinfo 可选、可 base64）
  static ProxyNode? _parseSocks(String uri) {
    try {
      final scheme = uri.startsWith('socks5://') ? 'socks5://' : 'socks://';
      final without = uri.substring(scheme.length);
      final hash = without.indexOf('#');
      final tag = hash >= 0 ? _safeDecode(without.substring(hash + 1)) : 'socks5';
      final body = hash >= 0 ? without.substring(0, hash) : without;
      final at = body.indexOf('@');
      String? username;
      String? password;
      String host;
      int port;
      if (at >= 0) {
        var cred = body.substring(0, at);
        if (cred.isNotEmpty) {
          if (!cred.contains(':')) {
            cred = _b64DecodeLoose(cred) ?? cred;
          }
          final sep = cred.indexOf(':');
          username = sep > 0 ? cred.substring(0, sep) : cred;
          password = sep >= 0 ? cred.substring(sep + 1) : '';
        }
        final hp = _hostPort(body.substring(at + 1).split('?').first);
        if (hp == null) return null;
        host = hp.$1;
        port = hp.$2;
      } else {
        final hp = _hostPort(body.split('?').first);
        if (hp == null) return null;
        host = hp.$1;
        port = hp.$2;
      }
      return ProxyNode(
        tag: tag,
        type: 'socks5',
        server: host,
        port: port,
        password: password,
        raw: {
          'name': tag,
          'type': 'socks5',
          'server': host,
          'port': port,
          if (username != null && username.isNotEmpty) 'username': username,
          if (password != null && password.isNotEmpty) 'password': password,
        },
      );
    } catch (_) {
      return null;
    }
  }

  static ProxyNode? _parseHysteria2(String uri) {
    final p = _parseUserinfoUri('hysteria2', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'hysteria2';
    final sni = p.q['sni'];
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'hysteria2',
      'server': p.host,
      'port': p.port,
      'password': p.cred,
      if (sni != null && sni.isNotEmpty) 'sni': sni,
      if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1')
        'skip-cert-verify': true,
    };
    return ProxyNode(
      tag: tag,
      type: 'hysteria2',
      server: p.host,
      port: p.port,
      password: p.cred,
      sni: sni,
      raw: raw,
    );
  }

  static ProxyNode? _parseTuic(String uri) {
    final p = _parseUserinfoUri('tuic', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'tuic';
    // tuic://uuid:password@host:port（: 常被百分号编码为 %3A）
    final cred = _safeDecode(p.cred);
    final sep = cred.indexOf(':');
    final uuid = sep > 0 ? cred.substring(0, sep) : cred;
    final password = sep >= 0 ? cred.substring(sep + 1) : '';
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'tuic',
      'server': p.host,
      'port': p.port,
      'uuid': uuid,
      'password': password,
      if ((p.q['sni'] ?? '').isNotEmpty) 'sni': p.q['sni'],
      if ((p.q['alpn'] ?? '').isNotEmpty) 'alpn': p.q['alpn']!.split(','),
      if ((p.q['congestion_control'] ?? p.q['congestion-controller'] ?? '').isNotEmpty)
        'congestion-controller': p.q['congestion_control'] ?? p.q['congestion-controller'],
      if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1')
        'skip-cert-verify': true,
    };
    return ProxyNode(
      tag: tag,
      type: 'tuic',
      server: p.host,
      port: p.port,
      uuid: uuid,
      password: password,
      sni: p.q['sni'],
      raw: raw,
    );
  }

  static ProxyNode? _parseAnyTls(String uri) {
    final p = _parseUserinfoUri('anytls', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'anytls';
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'anytls',
      'server': p.host,
      'port': p.port,
      'password': p.cred,
      if ((p.q['sni'] ?? '').isNotEmpty) 'sni': p.q['sni'],
      if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1')
        'skip-cert-verify': true,
    };
    return ProxyNode(
      tag: tag,
      type: 'anytls',
      server: p.host,
      port: p.port,
      password: p.cred,
      sni: p.q['sni'],
      raw: raw,
    );
  }

  /// 解析 ShadowsocksR：`ssr://base64(server:port:protocol:method:obfs:password/?obfsparam=...&remarks=...)`
  /// 其中 password/obfsparam/protoparam/remarks/group 均为 base64url。
  static ProxyNode? _parseSsr(String uri) {
    try {
      final decoded = _b64UrlDecode(uri.substring('ssr://'.length));
      final qm = decoded.indexOf('?');
      final main = qm >= 0 ? decoded.substring(0, qm) : decoded;
      final qs = qm >= 0 ? decoded.substring(qm + 1) : '';
      final p = main.split(':');
      if (p.length < 6) return null;
      final server = p[0];
      final port = int.tryParse(p[1]) ?? 0;
      final protocol = p[2];
      final method = p[3];
      final obfs = p[4];
      final password = _b64UrlDecode(p[5].split('/').first);
      final params = <String, String>{};
      for (final kv in qs.split('&')) {
        if (kv.isEmpty) continue;
        final i = kv.indexOf('=');
        final k = i >= 0 ? kv.substring(0, i) : kv;
        final v = i >= 0 ? kv.substring(i + 1) : '';
        params[k] = _b64UrlDecode(v);
      }
      final tag = params['remarks']?.isNotEmpty == true ? params['remarks']! : 'ssr';
      final raw = <String, dynamic>{
        'name': tag,
        'type': 'ssr',
        'server': server,
        'port': port,
        'cipher': method,
        'password': password,
        'protocol': protocol,
        'obfs': obfs,
        if (params['obfsparam']?.isNotEmpty == true) 'obfs-param': params['obfsparam'],
        if (params['protoparam']?.isNotEmpty == true)
          'protocol-param': params['protoparam'],
      };
      return ProxyNode(
        tag: tag,
        type: 'ssr',
        server: server,
        port: port,
        cipher: method,
        password: password,
        raw: raw,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 Hysteria v1：`hysteria://host:port/?auth=...&peer=...&obfs=xplus#tag`
  /// （v1 无 userinfo，密码在 auth 参数里，与 hysteria2 不同）
  static ProxyNode? _parseHysteria(String uri) {
    try {
      final without = uri.substring('hysteria://'.length);
      final hash = without.indexOf('#');
      final tag = hash >= 0 ? _safeDecode(without.substring(hash + 1)) : 'hysteria';
      final body = hash >= 0 ? without.substring(0, hash) : without;
      final qm = body.indexOf('?');
      final hostPort = qm >= 0 ? body.substring(0, qm) : body;
      final hp = _hostPort(hostPort);
      if (hp == null) return null;
      final q = qm >= 0 ? _queryParams(body.substring(qm + 1)) : <String, String>{};
      final auth = q['auth'] ?? '';
      final sni = q['peer'] ?? q['sni'];
      final raw = <String, dynamic>{
        'name': tag,
        'type': 'hysteria',
        'server': hp.$1,
        'port': hp.$2,
        if (auth.isNotEmpty) 'auth_str': auth,
        if (sni != null && sni.isNotEmpty) 'sni': sni,
        if ((q['upmbps'] ?? '').isNotEmpty) 'up': int.tryParse(q['upmbps']!) ?? 0,
        if ((q['downmbps'] ?? '').isNotEmpty)
          'down': int.tryParse(q['downmbps']!) ?? 0,
        if ((q['alpn'] ?? '').isNotEmpty) 'alpn': q['alpn']!.split(','),
        if ((q['obfs'] ?? '').isNotEmpty) 'obfs': q['obfs'],
        if ((q['obfsParam'] ?? q['obfs-param'] ?? '').isNotEmpty)
          'obfs-param': q['obfsParam'] ?? q['obfs-param'],
        if (q['insecure'] == '1') 'skip-cert-verify': true,
      };
      return ProxyNode(
        tag: tag,
        type: 'hysteria',
        server: hp.$1,
        port: hp.$2,
        password: auth,
        sni: sni,
        raw: raw,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 WireGuard：`wireguard://base64(ini_conf)#tag`
  /// （链接里直接是 base64 的 .conf 内容，解析成 mihomo wireguard map）
  static ProxyNode? _parseWireguard(String uri) {
    try {
      final conf = _b64UrlDecode(uri.substring('wireguard://'.length).split('#').first);
      final tag = _uriTag(uri) ?? 'wireguard';
      final kv = <String, String>{};
      for (final line in conf.split('\n')) {
        final l = line.trim();
        if (l.isEmpty || l.startsWith('[')) continue;
        final i = l.indexOf('=');
        if (i < 0) continue;
        kv[l.substring(0, i).trim().toLowerCase()] = l.substring(i + 1).trim();
      }
      final endpoint = kv['endpoint'];
      if (endpoint == null) return null;
      final hp = _hostPort(endpoint);
      if (hp == null) return null;
      final raw = <String, dynamic>{
        'name': tag,
        'type': 'wireguard',
        'server': hp.$1,
        'port': hp.$2,
        'udp': true,
        if (kv['privatekey'] != null) 'private-key': kv['privatekey'],
        if (kv['publickey'] != null) 'public-key': kv['publickey'],
        if (kv['address'] != null) 'ip': kv['address']!.split(',').first.trim(),
        if (kv['presharedkey'] != null) 'preshared-key': kv['presharedkey'],
      };
      return ProxyNode(
        tag: tag,
        type: 'wireguard',
        server: hp.$1,
        port: hp.$2,
        raw: raw,
      );
    } catch (_) {
      return null;
    }
  }
}
