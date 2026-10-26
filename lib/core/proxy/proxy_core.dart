import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/models.dart';
import '../services/account_service.dart';
import '../services/app_log.dart';
import '../services/geo_lookup.dart';
import '../services/local_notify.dart';
import '../services/local_paths.dart';
import '../services/settings_store.dart';
import '../services/subscription_service.dart';
import '../services/speed_test_mode.dart';
import '../services/speed_tester.dart';
import 'geo_assets.dart';
import 'port_guard.dart';
import 'speed_probe_kernel.dart';
import 'proxy_core_embedded.dart';
import 'proxy_core_cli.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';
import 'tun_failure.dart';
import '../../l10n/app_strings.dart';
import 'conn_error.dart';
export 'conn_error.dart';

/// 后台 isolate 入口：构建 sing-box JSON 配置。compute 要求顶层/静态函数。
Map<String, dynamic> _buildConfigInIsolate(Map<String, dynamic> args) {
  final proxies = (args['proxies'] as List).cast<Map<String, dynamic>>();
  final nodes = proxies.map((m) => ProxyNode.fromClashMap(m)).toList();
  return SingBoxConfigBuilder.build(
    nodes: nodes,
    selectedTag: args['selectedTag'] as String,
    smartMode: args['smartMode'] as bool,
    dns: args['dns'] as String,
    tunMode: args['tunMode'] as String,
    bypassLan: args['bypassLan'] as bool,
    localPort: (args['localPort'] as num?)?.toInt() ?? 2080,
    clashApiPort: (args['clashApiPort'] as num?)?.toInt() ?? 9090,
    geoReady: args['geoReady'] != false,
    logLevel: args['logLevel']?.toString() ?? 'warning',
    dnsMode: args['dnsMode']?.toString() ?? 'auto',
    tunStack: args['tunStack']?.toString() ?? 'gvisor',
    // 桌面：内核自己建 TUN 接口 + 推路由（无人注入 fd）；Android：路由由
    // VpnService 全量下发，必须 auto-route:false（见 SingBoxConfigBuilder）
    tunAutoRoute: args['tunAutoRoute'] == true,
    // iOS：fd 由 PacketTunnel 扩展注入（socketpair 用户态桥）→ 生成器要关掉
    // Darwin 专属的 recvmsgx，否则内核建 TUN 时 setsockopt 失败、直接起不来
    tunFdInjected: args['tunFdInjected'] == true,
    // 兼容旧入参（sing-box 一律用 .srs 规则集，该开关不再影响产物）
    useMrsRuleSet: args['useMrsRuleSet'] == true,
    // .srs 规则集所在目录（Android/桌面 = 内核工作目录的绝对路径；
    // iOS = 空串，走相对文件名，由 PacketTunnel 扩展的工作目录解析）
    ruleSetDir: args['ruleSetDir']?.toString(),
    udpSkipCertVerify: args['udpSkipCertVerify'] != false,
    bypassDomains: (args['bypassDomains'] as List?)?.cast<String>() ?? const [],
    // 「必须走代理」名单（内置默认在生成器里，这里只传用户追加的）
    forceProxyDomains: (args['forceProxyDomains'] as List?)?.cast<String>() ?? const [],
    dnsNameservers: (args['dnsNameservers'] as List?)?.cast<String>() ?? const [],
    fakeIpFilterExtra: (args['fakeIpFilterExtra'] as List?)?.cast<String>() ?? const [],
  );
}

/// 容错解析端口设置：历史遗留/手工改过的配置可能把端口存成字符串，
/// 直接用 `as num?` 会抛 TypeError（该处不在 try 内，会让连接整体失败）。
int _asPort(dynamic v, int fallback) {
  if (v is num) return v.toInt();
  final p = int.tryParse(v?.toString().trim() ?? '');
  return p ?? fallback;
}

/// 测速后的节点切换策略（见 ConnectionController._applySwitchPolicy）
enum _SwitchPolicy { none, best, auto }

/// 连接状态
enum ConnStatus { disconnected, disconnecting, testing, connecting, connected, reconnecting, error }

/// 速率快照（流量统计 1s 一次，独立于 ConnectionController 的通知）
class SpeedSnapshot {
  const SpeedSnapshot({this.upMbps = 0, this.downMbps = 0});
  final double upMbps;
  final double downMbps;
}

/// 代理核心抽象：各平台实现（macOS/Windows/Linux 走 sing-box CLI 子进程；
/// Android 走原生 VpnService + libbox gomobile 库）
abstract class ProxyCore {
  /// 启动内核并加载配置
  Future<void> start(Map<String, dynamic> config);

  /// 停止内核（断开）
  Future<void> stop();

  /// 热切换模式（智能/全局）——走 Clash API，不断网
  Future<void> switchMode(bool smart);

  /// 热切换节点——走 Clash API 改 selector
  Future<void> switchNode(String tag);

  /// 通过内核测节点延迟(ms)：走 Clash API /proxies/{tag}/delay，用真实协议+
  /// 隧道实测，UDP(hysteria2/tuic)与被墙 TCP 节点都能测准。失败/未运行返回 -1。
  /// [url] 测速探测地址（设置页可改，默认 gstatic 204）。
  Future<int> testNodeDelay(String tag,
      {Duration timeout = const Duration(seconds: 5), String? url});

  /// 热更内核日志级别（debug/info/warning/error）。未连接时为 no-op。
  Future<void> setKernelLogLevel(String level) async {}

  /// 当前是否运行中
  bool get isRunning;

  /// 最近一次错误
  String? get lastError;

  /// 内核异常退出（非主动断开）回调 → 控制器自动重连
  VoidCallback? get onUnexpectedExit;
  set onUnexpectedExit(VoidCallback? cb);

  /// 实时速率回调（MB/s）
  void Function(double upMbps, double downMbps)? get onTraffic;
  set onTraffic(void Function(double upMbps, double downMbps)? cb);

  /// 释放资源
  void dispose();
}

/// 平台内核工厂
class ProxyCoreFactory {
  static ProxyCore create() {
    // Android(VpnService) 与 iOS(NetworkExtension PacketTunnel) 共用同一实现：
    // 内核都是 gomobile 静态库，跑在系统提供的隧道里，由原生拿 tun fd 启动，
    // 控制面统一走 Clash API。原生通道契约同名同参。
    if (Platform.isAndroid || Platform.isIOS) return ProxyCoreEmbedded();
    return ProxyCoreCli();
  }
}

/// 「启动时自动连接」的判定结果。
///
/// 为什么需要返回值：旧实现 `autoConnectIfEnabled()` 返回 void，开关开着却没连
/// 上的每一种原因（没线路 / 账号门禁 / 已在连接）都只能靠状态里的 error 反推，
/// 调用方没法给出**确定**的用户可见结果，也就没人发现「提前 return 让自动连接
/// 整条死掉」这个 bug。现在判定结果是显式契约：每种结果要么已经产生可见反馈
/// （连接状态机/门禁文案），要么由调用方补一句提示。
enum AutoConnectOutcome {
  /// 已真正发起连接（`connect()` 被调用过；成败由连接状态机与首页错误区展示）
  started,

  /// 开关关：尊重用户选择，不做任何连接动作（这里静默 = 正确行为）
  disabled,

  /// 本次启动已经判定过（门闩），不再重复连接
  alreadyTried,

  /// 当前不在断开态（已连接/连接中/重连中）：目标已达成，无需动作
  busy,

  /// 没有可用线路（订阅未到位/为空/拉取失败）：不连，且**不消费门闩** ——
  /// 线路稍后到位（磁盘缓存/重试成功/回前台）时仍要补一次
  noNodes,

  /// 账号门禁（到期/设备满/被禁用/未开通）：不发起建连，
  /// 门禁文案已落到 [ConnectionController.error] 且首页有受限横幅
  blocked,
}

/// 内核「异常退出」后的处置决策（纯逻辑，便于单元测试）
enum CrashRecoveryAction {
  /// 自动拉起内核：与用户偏好无关，客户端自身故障必须自愈
  recover,

  /// 放弃自动恢复，如实报错并把决定权交回用户
  giveUp,
}

/// 内核异常退出处置纯函数（无副作用，可单测）：
/// - 已熔断（10 分钟内反复崩溃）→ giveUp：否则「能启动但几秒后必崩」的内核
///   会陷入 connect→崩→reconnect 的无限循环，每轮都动系统代理与通知；
/// - 用户开了自动重连 → 沿用 reconnectTimes 额度（行为与旧版一致）；
/// - 用户关了自动重连 → **仍然**允许内核崩溃自愈，额度 [maxKernelRecover]。
///   这是关键差异：autoReconnect 管的是「网络/节点原因断开后要不要自动重连」，
///   而内核进程消失是客户端自身故障 —— 停在那里等于让用户「只能直连、
///   App 一声不吭」（2026-09-10 内核 code=1 静默退出后 count=0，一次没重试）。
CrashRecoveryAction decideCrashRecovery({
  required bool autoReconnect,
  required bool burst,
  required int reconnectCount,
  required int maxReconnect,
  required int kernelRecoverCount,
  required int maxKernelRecover,
}) {
  if (burst) return CrashRecoveryAction.giveUp;
  if (reconnectCount >= maxReconnect) return CrashRecoveryAction.giveUp;
  if (autoReconnect) return CrashRecoveryAction.recover;
  return kernelRecoverCount < maxKernelRecover
      ? CrashRecoveryAction.recover
      : CrashRecoveryAction.giveUp;
}


/// 全局连接控制器：状态机 + 自动测速选优 + 断线重连 + 后台测速
class ConnectionController extends ChangeNotifier {
  ConnectionController._() {
    _wireCore();
    // 订阅同步状态变化 → 转发给 UI；开始同步时顺手清掉上一会话残留的错误，
    // 免得刚登录时按钮下方挂着红色错误、让用户以为出错了
    SubscriptionService.instance.syncing.addListener(() {
      if (SubscriptionService.instance.syncing.value) {
        error = null;
        errorKind = ConnErrorKind.none;
      }
      notifyListeners();
    });
  }
  static final ConnectionController instance = ConnectionController._();

  ProxyCore _core = ProxyCoreFactory.create();

  /// 测试缝：替换内核实现（注入记录型内核桩），并重新挂上回调。
  ///
  /// 为什么需要：测试环境没有 sing-box 二进制，`connect()` 必然在内核启动处失败，
  /// 「自动连接到底有没有真的发起」就只剩下「有没有留下 error」这种间接且不唯一
  /// 的副作用可判（error 也可能来自订阅/门禁路径）。注入桩后，
  /// 「connect() 是否推进到了启动内核」变成可直接断言的事实。
  /// 生产代码不得调用。
  @visibleForTesting
  void debugSetCore(ProxyCore core) {
    _core = core;
    _wireCore();
  }

  /// 内核回调接线（构造与测试注入内核后都必须执行）。
  void _wireCore() {
    _core.onUnexpectedExit = onDisconnectedUnexpectedly;
    _core.onTraffic = _onTraffic;
  }

  ConnStatus status = ConnStatus.disconnected;
  List<ProxyNode> nodes = [];
  ProxyNode? current;
  String? error;

  /// 最近一次连接失败的类型（首页错误区按类型给不同引导；非错误态为 none）
  ConnErrorKind errorKind = ConnErrorKind.none;

  /// 测速探测地址（设置页可改；内核 delay 测试用，默认谷歌 204）。
  /// 默认值收敛到 [SettingsStore.defaultTestUrl]：它同时也是「旧 http 默认值」
  /// 迁移的判据（见 SettingsStore.legacyHttpTestUrl），两处必须是同一个常量。
  static const defaultTestUrl = SettingsStore.defaultTestUrl;
  String testUrl = defaultTestUrl;

  /// 当前测速方式（设置页可切；**默认内核测速**，用户可自行切到 TCP 测速）。
  ///
  /// Shadowrocket 的 Ping/Connect 对应关系：
  /// - [SpeedTestMode.kernel]（Connect，默认）：内核真的通过节点发请求，保证可用；
  /// - [SpeedTestMode.tcp]（Ping）：只测 `服务器:端口` TCP 握手，快但会假阳性。
  SpeedTestMode speedTestMode = defaultSpeedTestMode;

  /// **产出当前列表里那些延迟数字的**测速方式 + 时刻。
  ///
  /// 与 [speedTestMode] 分开的原因：用户切换方式后，列表里旧的数字是另一种
  /// 方式测出来的，两者不可比。切换时 [applySettings] 会**清空全部延迟**
  /// 并把这里置空，界面上绝不会把两种方式的数字混着展示
  /// （另：`lastSpeedTestMode` 也用于 UI 显示「本次数字是怎么来的」）。
  SpeedTestMode? lastSpeedTestMode;

  /// 最近一次测速失败的**可展示原因**（内核测速启动失败/平台不支持等）。
  ///
  /// 存在的意义就是「绝不静默失败」：内核测速不可用时宁可明确报错，
  /// 也不悄悄退回 TCP 去给用户一个假延迟。
  String? speedTestError;

  bool smartMode = true;

  /// Android 模式切换中（自动断开重连期间）：UI 显示「正在切换模式…」
  /// 并禁用模式/连接按钮，避免用户误以为没反应再点触发竞态
  bool switchingMode = false;

  bool autoTest = true;
  bool autoReconnect = true;
  String? lastSpeedTestTime;
  /// 用户是否手动切换过模式（智能/全局）。
  /// true 后 applySettings 不再用设置里的 defaultMode 覆盖（首页选择优先）。
  bool _modeUserSet = false;

  /// 用户手动选定的国家码（快速切换国家 / 托盘国家菜单后锁定）。
  /// 非 null 时，后台测速和自动选优只在该国家范围内切换（允许换节点），
  /// 不会跳到其他国家。与 [pinnedTag] 互斥。
  String? lockedCountry;

  /// 用户手动固定的**节点** tag（在节点列表里点某个节点 = 固定它）。
  ///
  /// 非 null 时是「最强约束」：后台测速 / 自动选优 / 慢线回落一律不换节点
  /// （测速只更新延迟数字），断开重连与重启后仍恢复到这个节点。
  /// 只有三种情况会解除：用户点了别的节点、点了「自动选择最优」、
  /// 或该节点在新订阅里消失。
  String? pinnedTag;

  /// 是否已从设置里恢复过一次持久化的选择（避免设置变更时反复覆盖内存态）
  bool _selectionLoaded = false;

  /// 解除「固定节点 / 锁定国家」，回到全局自动选优（首页「自动选择最优」）。
  /// 已连接时立刻测速并切换到全局最优。
  Future<void> unlockSelection() async {
    final hadPin = pinnedTag;
    pinnedTag = null;
    lockedCountry = null;
    // 清除持久化：此后连接不再恢复旧节点/旧国家，走全局自动选优
    unawaited(_clearPersistedSelection());
    if (hadPin != null) {
      AppLog.conn('unpin node ($hadPin) → 全局自动选优');
    }
    notifyListeners();
    if (status == ConnStatus.connected && autoTest) {
      await _autoSpeedTestAndSwitch(_epoch, forceBest: true);
    }
  }

  /// 点「国家」：锁定国家，只在该国范围内自动选最优（允许换节点）。
  /// 与点「节点」（固定节点）互斥 —— 这里会解除节点固定。
  Future<bool> switchCountry(String code) async {
    final cc = code.toUpperCase();
    final candidates = nodes
        .where((n) => (n.countryCode?.toUpperCase() ?? 'XX') == cc)
        .toList();
    if (candidates.isEmpty) return false;
    final best = SpeedTester.selectBest(candidates) ??
        candidates.firstWhere((n) => n.online, orElse: () => candidates.first);
    pinnedTag = null;
    lockedCountry = cc;
    unawaited(_persistCountry(cc, best));
    await _applyNodeSwitch(best);
    return true;
  }

  /// 持久化统一收敛到 SettingsStore.update(全局单写队列),
  /// 不再各自 load→save,避免并发丢字段
  Future<void> _enqueueSettingsWrite(
      void Function(Map<String, dynamic>) mutate) async {
    try {
      await SettingsStore.instance.update(mutate);
    } catch (_) {}
  }

  /// 持久化「用户手动选定的节点」：既是上次使用的节点（lastSelectedTag，兼容
  /// 旧数据），也是**节点固定**（pinTag）。两者一起写，重启后 connect 才能
  /// 既恢复节点又恢复「不自动跳」的语义。
  Future<void> _persistSelection(ProxyNode node) =>
      _enqueueSettingsWrite((s) {
        s['lastSelectedTag'] = node.tag;
        s['pinTag'] = node.tag;
        s.remove('lockCountry');
      });

  /// 持久化「锁定国家」：pinTag 必须一并清掉，否则重启后节点固定会盖过国家锁
  Future<void> _persistCountry(String code, ProxyNode node) =>
      _enqueueSettingsWrite((s) {
        s['lastSelectedTag'] = node.tag;
        s['lockCountry'] = code;
        s.remove('pinTag');
      });

  Future<void> _clearPersistedSelection() =>
      _enqueueSettingsWrite((s) {
        s.remove('lastSelectedTag');
        s.remove('pinTag');
        s.remove('lockCountry');
      });

  /// 连接前恢复用户的选择：固定节点优先 → 锁定国家（该国上次节点或该国最优）
  /// → 上次手动选择的节点。节点已不在订阅里时顺手解除对应的固定/锁定。
  Future<ProxyNode?> _restoreSelection(List<ProxyNode> list) async {
    final pin = pinnedTag;
    if (pin != null && pin.isNotEmpty) {
      for (final n in list) {
        if (n.tag == pin) return n;
      }
      // 固定节点已下架：解除固定，否则会一直连不上或连到不存在的线路
      AppLog.conn('pinned node gone from subscription: $pin → 解除固定');
      pinnedTag = null;
      unawaited(_clearPersistedSelection());
    }
    final cc = lockedCountry;
    if (cc != null && cc.isNotEmpty) {
      final remembered = await _restoreLastSelection(list);
      if (remembered != null &&
          (remembered.countryCode?.toUpperCase() ?? 'XX') == cc) {
        return remembered;
      }
      final candidates = list
          .where((n) => (n.countryCode?.toUpperCase() ?? 'XX') == cc)
          .toList();
      if (candidates.isNotEmpty) {
        return SpeedTester.selectBest(candidates) ?? candidates.first;
      }
      lockedCountry = null;
      unawaited(_clearPersistedSelection());
    }
    return _restoreLastSelection(list);
  }

  /// 从设置恢复上次手动选择的节点（仅当节点仍存在于当前订阅时）
  Future<ProxyNode?> _restoreLastSelection(List<ProxyNode> list) async {
    try {
      final s = await SettingsStore.instance.load();
      final tag = s['lastSelectedTag']?.toString();
      if (tag == null || tag.isEmpty) return null;
      for (final n in list) {
        if (n.tag == tag) return n;
      }
    } catch (_) {}
    return null;
  }

  /// 后台测速中（已连接状态下并行测速；不阻塞连接，仅用于 UI 提示）
  bool speedTesting = false;

  /// 订阅同步中（登录后拉取/刷新订阅）：直接反映 SubscriptionService 的
  /// 拉取状态。UI 用它显示「正在同步订阅…」——同步是过程，不是错误。
  bool get syncingSubscription => SubscriptionService.instance.syncing.value;
  /// 仅测试用：把「订阅同步中」置为真/假，用于验证主页布局不因同步提示位移。
  @visibleForTesting
  void setSyncingForTest(bool v) {
    SubscriptionService.instance.syncing.value = v;
    notifyListeners();
  }


  /// 实时速率（MB/s）——由内核 /traffic 1s 推送。
  /// 用独立 ValueNotifier：每秒更新只通知速率监听者（首页速率卡片），
  /// 不触发整个 ConnectionController 重建（避免首页每秒全量 rebuild）。
  double upSpeedMbps = 0;
  double downSpeedMbps = 0;

  // ---- 速率历史(首页迷你趋势曲线,最近 ~60s,1s 采样)----
  static const historyMax = 60;
  final List<double> upHistory = [];
  final List<double> downHistory = [];

  // ---- 会话统计(首页「已连接时长/本次流量」)----
  DateTime? connectedAt;
  double sessionUpMB = 0; // 本次连接累计上行(MB,1s 采样近似)
  double sessionDownMB = 0;
  String get sessionUptime {
    final t = connectedAt;
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$sec';
  }
  final ValueNotifier<SpeedSnapshot> speedNotifier = ValueNotifier(const SpeedSnapshot());

  /// 真实出口国家码（连接后通过隧道 IP 定位实测，非节点名猜测）
  String? realCountry;
  /// 出口定位重试用尽仍失败：UI 显示「检测失败，点按重试」——
  /// 否则两个定位源都挂时会永远停留在「检测中…」。新一轮检测时清零。
  bool realCountryFailed = false;
  /// 出口定位的代次：每次发起 +1，只有最新一次的结果才允许写入 —— 切国家时
  /// 旧的在途定位（慢/命中缓存）完成后不会再把旧国家覆盖回来。
  int _geoEpoch = 0;

  /// 连接成功后实测出口国家（失败不抛出，不阻塞连接）。
  /// [force] 切换节点/国家后出口已变，强制重查（绕过 GeoLookup 的 TTL 缓存）。
  /// 最多尝试 3 次（间隔 3s）：刚建立的隧道首个外呼可能因链路未就绪而失败，
  /// 短重试显著提高成功率；全部失败置 [realCountryFailed]（UI 可点按重试）。
  Future<void> refreshRealCountry({bool force = false}) async {
    if (status != ConnStatus.connected) return;
    final epoch = ++_geoEpoch; // 本次代次；被后续调用超越即作废
    if (realCountryFailed) {
      realCountryFailed = false;
      notifyListeners(); // 失败态回到「检测中…」（点按重试的即时反馈）
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      if (epoch != _geoEpoch || status != ConnStatus.connected) return;
      String? code;
      try {
        code = await GeoLookupService.instance.lookupViaProxy(force: force);
      } catch (_) {
        code = null; // 定位失败静默，走重试
      }
      // 仅当仍是最新一次请求、且仍连接时才写入：避免旧的慢请求覆盖新国家，
      // 也避免切国家后被 10 分钟缓存的旧值回填
      if (epoch != _geoEpoch || status != ConnStatus.connected) return;
      if (code != null) {
        realCountry = code;
        notifyListeners();
        return;
      }
      if (attempt < 2) await Future.delayed(const Duration(seconds: 3));
    }
    if (epoch == _geoEpoch && status == ConnStatus.connected) {
      realCountryFailed = true;
      // 三次都失败 → 用「内核测速当前节点」做交叉判据，把原因说清楚：
      //  - 节点测速也失败 → 基本可判定当前节点不可用（客户反馈里满屏 TLS 握手
      //    被中断，多半就是这种情况：出口定位三个源全挂 + 节点本身连不出）
      //  - 节点测速正常 → 节点可用，属目标站点/链路侧问题，不该误报成连接故障
      var nodeOk = false;
      if (current != null) {
        try {
          final ms = await _core.testNodeDelay(current!.tag, url: testUrl);
          nodeOk = mfLatencyUsable(ms);
        } catch (_) {}
      }
      final detail = GeoLookupService.instance.lastFailureDetail;
      if (nodeOk) {
        AppLog.log('GEO',
            '出口定位失败但节点测速正常（${current?.tag}）：$detail');
      } else {
        AppLog.error(
            '节点疑似不可用：出口定位与节点测速均失败（${current?.tag}）：$detail');
      }
      notifyListeners();
    }
  }

  /// 从设置项同步连接行为（设置页 / 启动时调用）
  void applySettings(Map<String, dynamic> s) {
    // 首次加载时恢复持久化的「固定节点 / 锁定国家」（之后以内存态为准，
    // 避免设置变更把用户刚做的选择覆盖回去）
    if (!_selectionLoaded) {
      _selectionLoaded = true;
      final pin = s['pinTag']?.toString() ?? '';
      final lock = s['lockCountry']?.toString() ?? '';
      if (pin.isNotEmpty) {
        pinnedTag = pin;
      } else if (lock.isNotEmpty) {
        lockedCountry = lock.toUpperCase();
      }
    }
    if (s['autoTest'] is bool) autoTest = s['autoTest'] as bool;
    if (s['autoReconnect'] is bool) autoReconnect = s['autoReconnect'] as bool;
    final u = s['testUrl']?.toString();
    if (u != null && u.trim().isNotEmpty) testUrl = u.trim();
    // 测速方式：缺 key / 值损坏一律回落内核测速（parseSpeedTestMode 的策略）。
    // 方式**变了**就把列表里旧方式测出的延迟全部清掉 —— 内核测速与 TCP
    // 测速的数字不可比，混在一起展示等于骗用户（例如切到内核测速后，
    // 界面上仍留着 TCP 给假阳性节点的「12ms」）。
    final mode = parseSpeedTestMode(s['speedTestMode']);
    if (mode != speedTestMode) {
      final hadLatency = nodes.any((n) => n.latencyMs >= 0);
      speedTestMode = mode;
      lastSpeedTestMode = null;
      lastSpeedTestTime = null;
      speedTestError = null;
      if (hadLatency) {
        for (final n in nodes) {
          n.latencyMs = -1;
        }
        AppLog.log('SPEED', '测速方式切换为 ${speedTestModeKey(mode)}，已清空旧延迟');
      }
    }
    // 仅在用户未手动切过模式时应用 defaultMode，避免首页选择被设置页静默重置
    if (!_modeUserSet) {
      if (s['defaultMode'] == 'global') {
        smartMode = false;
      } else if (s['defaultMode'] == 'smart') {
        smartMode = true;
      }
    }
    notifyListeners();
  }

  /// 首页自动测速开关（带通知，保证 UI 即时刷新；持久化，重启后保留）
  void setAutoTest(bool v) {
    autoTest = v;
    notifyListeners();
    // 合并持久化：走全局单写队列 update()（在最新值上只改 autoTest 一个键），
    // 不再 load→save 整份快照回写 —— 否则与其它写者并发时会覆盖它们刚写入的
    // 字段（如 lastSelectedTag），正是 SettingsStore 注释警告的丢字段场景。
    unawaited(_enqueueSettingsWrite((s) => s['autoTest'] = v));
  }

  Timer? _reconnectTimer;
  Timer? _bgTestTimer;
  Timer? _wakeLockTimer;
  int _reconnectCount = 0;
  int _epoch = 0;
  /// 「启动时自动连接」每启动一次只尝试一次的门闩（详见 [autoConnectIfEnabled]）。
  /// 置位时机：真正发起 connect() / 开关为关 / 账号门禁 / 已在连接；
  /// 「没有可用线路」会把它退回 false（等线路到位再补一次）。
  /// [resetForLogout] 会复位（换账号后重新给一次机会）。
  bool _autoConnectTried = false;

  /// 自动重连次数上限（来自设置 `reconnectTimes`，1~10，默认 3）。
  /// 旧实现硬编码 3，用户改了设置也不生效。
  int _maxReconnect = 3;

  /// 「连接稳定存活」后才把 [_reconnectCount] 清零的延时器。
  /// 旧实现一连上就清零，导致「能启动但几秒后必崩」的内核（端口/锁冲突、
  /// TUN 失败、被 OOM 或安全软件杀掉）陷入 connect→崩→reconnect 的无限循环，
  /// 每轮都带系统代理 apply/restore 与通知，既费电又制造「关了又自己连上」。
  Timer? _stableResetTimer;
  static const _stableResetAfter = Duration(seconds: 60);

  /// 短时间内异常退出的时间戳（熔断用）：10 分钟内反复崩溃 → 放弃自动重连
  final List<DateTime> _unexpectedExitAt = [];
  static const _exitWindow = Duration(minutes: 10);
  static const _exitBurstLimit = 5;

  /// 内核进程「异常消失」的自愈次数（本轮链条内）。
  ///
  /// 与用户偏好 [autoReconnect] **解耦**：autoReconnect 管的是「网络/节点原因
  /// 断开后要不要自动重连」，而内核进程消失属于客户端自身故障 —— 静默停下
  /// 等于让用户「整机只能直连、App 一声不吭」。实测 2026-09-10 内核 code=1
  /// 静默退出后 `count=0`（一次都没重试），用户一小时后又自己发现。
  int _kernelRecoverCount = 0;

  /// 本轮重连链是否由「内核异常退出」触发。决定续链走自愈额度（不受
  /// autoReconnect 门控）还是走用户的自动重连偏好。
  bool _crashRecoveryChain = false;

  /// 内核崩溃自愈的次数上限（仅在 autoReconnect 关闭时生效；开着时沿用
  /// 用户的 reconnectTimes 与 [_exitBurstLimit] 熔断，行为与旧版一致）。
  static const _maxKernelRecover = 3;

  /// 是否还允许再自动拉起一轮（续链判定，用于 connect 失败后的下一轮）。
  /// 熔断只在崩溃入口判一次（同一个 10 分钟窗口内已经判过），这里传 burst:false
  /// —— 重连失败本身不会让「短时间反复崩溃」的计数增长。
  bool get _autoRetryAllowed =>
      decideCrashRecovery(
        autoReconnect: autoReconnect,
        burst: false,
        reconnectCount: _reconnectCount,
        maxReconnect: _maxReconnect,
        kernelRecoverCount: _kernelRecoverCount,
        maxKernelRecover: _maxKernelRecover,
      ) ==
      CrashRecoveryAction.recover;

  /// 各平台内核工作目录（规则集与 config 同目录，配置里以绝对路径引用）：
  /// - 桌面：CLI workDir（系统临时目录 mbox_core）
  /// - Android/iOS：filesDir/work（MBoxVpnService 同一内核目录）
  Future<String?> _geoWorkDir() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await LocalPaths.supportDir(); // Android = filesDir
      if (support == null) return null;
      return '${support.path}/work';
    }
    return ProxyCoreCli.workDir;
  }

  Future<void> loadNodes(List<ProxyNode> list) async {
    nodes = _carryMeasuredLatency(list, nodes);
    _dropPinIfNodeGone();
    _retargetCurrent();
    notifyListeners();
  }

  /// 列表整体替换后，把 current 重指向同 tag 的新实例（消除陈旧引用：
  /// 否则 current 停留在旧实例，延迟/在线状态与列表长期不一致）；
  /// 当前 tag 已不在新列表 → 清 current，并联动清理已失效的国家锁。
  void _retargetCurrent() {
    final c = current;
    if (c == null) return;
    for (final n in nodes) {
      if (n.tag == c.tag) {
        current = n;
        return;
      }
    }
    current = null;
    _dropLockIfCountryGone();
  }

  /// 固定节点已不在当前列表（订阅下架/换源）→ 解除固定，
  /// 否则会一直尝试连一个不存在的线路（内核里也没有该 outbound）。
  void _dropPinIfNodeGone() {
    final pin = pinnedTag;
    if (pin == null) return;
    if (!nodes.any((n) => n.tag == pin)) {
      pinnedTag = null;
      unawaited(_clearPersistedSelection());
      AppLog.conn('pinned node gone: $pin → 解除固定');
    }
  }

  /// 锁定国家已无任何节点（订阅下架/换源）→ 解除锁，
  /// 避免 UI 显示"锁定 A"但自动选优/回落逻辑已悄悄离开该国。
  void _dropLockIfCountryGone() {
    final lc = lockedCountry;
    if (lc == null) return;
    if (!nodes.any(
        (n) => (n.countryCode?.toUpperCase() ?? 'XX') == lc)) {
      lockedCountry = null;
    }
  }

  /// 新列表节点若本身无测速结果（latencyMs<0），且旧列表存在同 tag 且测过
  /// 延迟（latencyMs>=0），则沿用旧测速值 —— 测速结果保留到下次真正测速，
  /// 不被订阅/配置刷新冲掉。自带测速结果的新节点（内核/纯 TCP 回填）不动。
  List<ProxyNode> _carryMeasuredLatency(
      List<ProxyNode> fresh, List<ProxyNode> prev) {
    if (fresh.isEmpty || prev.isEmpty) return fresh;
    final prevByTag = <String, ProxyNode>{for (final n in prev) n.tag: n};
    for (final n in fresh) {
      if (n.latencyMs >= 0) continue;
      final old = prevByTag[n.tag];
      if (old != null && old.latencyMs >= 0) n.latencyMs = old.latencyMs;
    }
    return fresh;
  }

  /// 订阅定时/启动刷新结果接入（覆盖旧节点配置）。
  ///
  /// 已连接且当前线路不在新订阅列表中时保持现状不替换：内核仍按旧配置运行，
  /// 直接替换会让 UI 丢掉当前线路或被误判离线、打断正在使用的连接；
  /// 连接建立过程中（connecting/testing 等瞬态）也不动列表，避免与 connect()
  /// 读取当前节点竞态；断开状态下则无条件覆盖。
  /// 空列表：账号受限（到期/停用/禁用）时订阅已失效 → 清空展示，绝不显示老
  /// 配置；正常账号的空列表多为解析失败/临时抖动 → 保留可用线路（离线兜底）。
  Future<void> applySubscriptionNodes(List<ProxyNode> fresh) async {
    if (fresh.isEmpty) {
      final acc = AccountService.instance;
      if (acc.loaded && acc.isConnectionBlocked) {
        nodes = [];
        current = null;
        lockedCountry = null; // 受限清空：同时解除失效的国家锁
        notifyListeners();
      }
      return;
    }
    if (status == ConnStatus.connecting ||
        status == ConnStatus.testing ||
        status == ConnStatus.reconnecting ||
        status == ConnStatus.disconnecting) {
      return;
    }
    if (status == ConnStatus.connected &&
        current != null &&
        !fresh.any((n) => n.tag == current!.tag)) {
      return;
    }
    await loadNodes(fresh);
  }

  /// 启动时自动连接（设置 autoConnect=true 时由首页在**拿到线路后**调用）。
  ///
  /// 语义（每次启动最多真正发起一次连接）：
  /// - 开关为 false → 绝不连接（返回 [AutoConnectOutcome.disabled]）；
  /// - 开关为 true 且**有可用线路**（无论来自网络订阅还是磁盘缓存）→ 必然
  ///   `connect()` 一次（返回 [AutoConnectOutcome.started]）；
  /// - 门闩 [_autoConnectTried] 保证不重复连接，但**只在真的发起连接、或开关
  ///   明确关闭、或账号门禁/已在连接时**才置位；「没有线路」不置位，否则
  ///   冷启动那一瞬间的空列表会白白吃掉整次启动的自动连接机会
  ///   （旧实现在 `nodes.isNotEmpty` 判断**之后**就置了门闩，这也是它脆的一环）；
  /// - 门闩在**第一个 await 之前**占位：首页的启动、回前台、下拉刷新可能并发
  ///   到达，不占位就会有两个调用各自走完判定 → 双开 [connect] → 双开内核。
  Future<AutoConnectOutcome> autoConnectIfEnabled() async {
    if (_autoConnectTried) return AutoConnectOutcome.alreadyTried;
    if (status != ConnStatus.disconnected) {
      // 已经在连接/已连接：启动自动连接的目标已达成（用户手动连的也一样）
      _autoConnectTried = true;
      return AutoConnectOutcome.busy;
    }
    _autoConnectTried = true; // 占位（下面有 await，必须先占）
    final s = await SettingsStore.instance.load();
    if (s['autoConnect'] != true) {
      // 开关关：绝不连接，且本次启动不用再看第二次
      return AutoConnectOutcome.disabled;
    }
    // 账号门禁：到期 / 设备满 / 被禁用 / 未开通 —— 与手动连接同一道拦截。
    // 不发起建连（connect() 的同一道门也只落到同一句文案），但**必须有可见
    // 结果**：文案落到 error（首页错误区可见），首页另有受限横幅带 CTA。
    final acc = AccountService.instance;
    if (acc.loaded && acc.isConnectionBlocked) {
      status = ConnStatus.disconnected;
      error = acc.blockText;
      errorKind = ConnErrorKind.none;
      notifyListeners();
      return AutoConnectOutcome.blocked;
    }
    if (nodes.isEmpty) {
      // 没有可用线路：不消费门闩 —— 线路到位后（订阅重试成功 / 回前台读到
      // 磁盘缓存）仍要补一次自动连接；用户可见的「为什么没连上」由订阅链路
      // 的提示给出（断网/订阅为空/被踢）。
      _autoConnectTried = false;
      return AutoConnectOutcome.noNodes;
    }
    await connect();
    return AutoConnectOutcome.started;
  }

  /// WakeLock：连接/重连时短暂持有（<5s），防止 Doze 打断握手
  void _acquireWakeLock() {
    if (!Platform.isAndroid) return;
    _wakeLockTimer?.cancel();
    try { WakelockPlus.enable(); } catch (_) {}
    _wakeLockTimer = Timer(const Duration(seconds: 5), _releaseWakeLock);
  }

  void _releaseWakeLock() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
    if (!Platform.isAndroid) return;
    try { WakelockPlus.disable(); } catch (_) {}
  }

  /// 连接（Hiddify 模式）：立即启动内核 → 已连接 → 后台自动测速切换最优节点。
  /// 测速绝不阻塞连接：点连接立刻生效，测速在后台并行，完成后自动切换更优节点。
  /// [fromReconnect] 由断线重连调度发起：失败时继续重试（不中断重连链）。
  /// _epoch 守卫：连接过程中用户断开/再次连接时，旧流程的结果不再覆盖状态
  Future<void> connect({bool runSpeedTest = true, bool fromReconnect = false}) async {
    // 收掉「测速专用内核」（若有）：真连接期间内核测速直接复用连接中的内核，
    // 临时探测实例没有存在意义，留着白占内存与一个 socket 端口。
    unawaited(SpeedProbeKernel.instance.stop());
    // 账号门禁：到期 / 设备满 / 被禁用 / 未开通 —— 一律不允许建立 VPN。
    // 放在最前，自动连接、断线重连、首页点连接都走同一道拦截；
    // 会话内已判定过（AccountService.loaded）才生效，内核 e2e 直连不受影响。
    final acc = AccountService.instance;
    if (acc.loaded && acc.isConnectionBlocked) {
      status = ConnStatus.disconnected;
      error = acc.blockText;
      errorKind = ConnErrorKind.none;
      notifyListeners();
      return;
    }
    // 已在连接/重连中时忽略新的连接请求（重连自身的入口除外）：
    // 否则两次 connect() 会并发推进到内核启动（epoch 只能事后作废，拦不住双开），
    // 造成双开内核、_proc 被覆盖、失去跟踪的孤儿占死端口。
    if (!fromReconnect &&
        (status == ConnStatus.connecting || status == ConnStatus.reconnecting)) {
      return;
    }
    if (nodes.isEmpty) {
      // 订阅正在同步（刚登录/刚刷新）→ 这是过程不是错误，由 UI 显示同步中
      if (syncingSubscription) {
        status = ConnStatus.disconnected;
        error = null;
        errorKind = ConnErrorKind.none;
        notifyListeners();
        return;
      }
      error = AppStrings.t('no_available_nodes');
      errorKind = ConnErrorKind.none;
      notifyListeners();
      return;
    }
    // 已连接时再次触发连接（首页「重新测速」「自动最优」）＝仅重新测速选优，
    // 不重启内核 —— 否则 start() 抛「内核已在运行」，误置错误态并还原系统代理，
    // 造成内核仍在运行但系统流量中断。
    if (status == ConnStatus.connected && _core.isRunning) {
      await retest();
      return;
    }
    final epoch = ++_epoch;
    _reconnectTimer?.cancel();
    // 用户手动发起的连接（含启动自动连接）：上一轮崩溃自愈链作废，额度重置 ——
    // 否则「连着崩三次后用户自己点了一次连接」会带着已耗尽的额度继续算账。
    if (!fromReconnect) {
      _crashRecoveryChain = false;
      _kernelRecoverCount = 0;
    }
    // 等待上一次断开(内核停止)真正完成，再启动新内核 —— 避免
    // disconnect 的 stop() 与本次 start() 并发：旧 stop 的
    // POST /shutdown / 系统代理 restore 可能误关刚就绪的新内核/新代理
    final pendingStop = _stopInFlight;
    if (pendingStop != null) {
      try {
        await pendingStop;
      } catch (_) {}
    }
    // 重连时确保旧内核已停干净（上次 start 可能半途失败留下残留进程）
    if (_core.isRunning) {
      try {
        await _core.stop();
      } catch (e) {
        AppLog.error('stop stale kernel failed: $e');
      }
    }
    // 从设置读取内核启动参数。smartMode / autoTest / autoReconnect 是运行时
    // 状态（启动时 applySettings 同步、设置页/首页开关即时更新），连接时不再
    // 用 defaultMode 覆盖，避免用户在首页的选择被静默重置。
    final settings = await SettingsStore.instance.load();
    final dns = settings['dns']?.toString() ?? '223.5.5.5';
    // 本机代理监听端口（设置页可改，默认 2080）：mixed 入站 + 系统代理共同指向
    final localPort = _asPort(settings['localPort'], 2080);
    // Clash API 端口（设置页可改，默认 9090）：内核管理通道（切节点/测速/流量）
    final clashApiPort = _asPort(settings['clashApiPort'], 9090);
    // 测速探测地址（设置页可改，默认 gstatic 204）
    final u = settings['testUrl']?.toString();
    if (u != null && u.trim().isNotEmpty) testUrl = u.trim();
    // 桌面端（macOS/Windows）默认「仅系统代理」：TUN 需要 root 权限，
    // 默认开启会导致用户一点连接就失败（operation not permitted）；
    // Android 默认「TUN + 系统代理双通道」：VpnService 授权后 TUN 接管全部流量。
    final defaultTunMode = (Platform.isAndroid || Platform.isIOS) ? 'auto' : 'off';
    // Android 必须走 TUN：平台没有桌面那种「系统代理」机制，若用户曾把
    // tunMode 设成 off，连接后内核只监听本地 mixed 端口、App 流量根本不进
    // 隧道 —— 表现为「已连接但没网」。移动端强制 auto。
    final effectiveTunMode = (Platform.isAndroid || Platform.isIOS)
        ? 'auto'
        : (settings['tunMode']?.toString() ?? defaultTunMode);
    final tunMode = effectiveTunMode;
    final bypassLan = settings['bypassLan'] != false;
    final intervalMin = (settings['testIntervalMin'] as num?)?.toInt() ?? 30;
    // 自动重连次数上限：读设置（旧实现硬编码 3，用户改了不生效）
    _maxReconnect =
        ((settings['reconnectTimes'] as num?)?.toInt() ?? 3).clamp(1, 10);
    if (epoch != _epoch) return;

    status = ConnStatus.connecting;
    error = null;
    errorKind = ConnErrorKind.none;
    _acquireWakeLock();
    notifyListeners();

    // 选连接节点：优先恢复「上次手动选择的节点」（跨重启/断开重连都保持
    // 固定国家不跳）→ 其次延迟最优 → 再次首个在线节点兜底。
    if (current == null) {
      final remembered = await _restoreSelection(nodes);
      if (remembered != null) {
        current = remembered;
        // 固定节点：不设国家锁（固定是最强约束，自动逻辑一律不动它）；
        // 否则恢复后继续锁定该国家：后台测速/自动选优只在该国范围，绝不乱跳
        if (pinnedTag == null) {
          lockedCountry ??= remembered.countryCode;
        }
      }
    }
    final best = SpeedTester.selectBest(nodes);
    current ??= best ?? nodes.firstWhere((n) => n.online, orElse: () => nodes.first);
    if (epoch != _epoch) return;
    if (current == null) {
      status = ConnStatus.error;
      error = AppStrings.t('all_nodes_offline');
      errorKind = ConnErrorKind.none;
      notifyListeners();
      return;
    }

    try {
      if (epoch != _epoch) return;
      // 离线 Geo 数据落盘（智能模式 CN 分流）：
      // - 桌面端：落到内核 workDir（配置里以绝对路径引用）
      // - Android：落到 filesDir/work（与 VpnService 同一内核目录；原生层的
      //   assets 复制保留为启动兜底，此处 Dart 幂等复制为准，保证就绪状态
      //   真实可判）
      // 数据源是打包进 App 的 assets/rules/*（CI 构建时下载），这里是本地
      // 复制、零网络；落盘失败（内置文件缺失/IO 异常）→ geoReady=false →
      // 智能规则降级为全代理：内核不会因缺文件联网下载 geo，启动不被网络
      // 拖慢、不会失败。
      // iOS：geo 数据随 PacketTunnel 扩展 bundle 分发，由扩展在启动时复制进
      // 自己的可写目录（App 写不进扩展容器，扩展也读不到 App 容器）→ 这里不落盘、
      // 直接视为就绪。若因落盘失败置 false，生成配置会降级掉 GEOSITE/GEOIP
      // 规则，智能分流就没了。
      final geoWorkDir = await _geoWorkDir();
      final geoReady = Platform.isIOS
          ? true
          : await GeoAssets.materialize(preferDir: geoWorkDir);
      final geoDirForRules = geoWorkDir ?? '';
      if (epoch != _epoch) return;
      final cfg = await compute(_buildConfigInIsolate, {
        'proxies': [for (final n in nodes) n.raw],
        'selectedTag': current!.tag,
        'smartMode': smartMode,
        'dns': dns,
        'tunMode': tunMode,
        'bypassLan': bypassLan,
        'localPort': localPort,
        'clashApiPort': clashApiPort,
        'geoReady': geoReady,
        'logLevel': settings['kernelLogLevel']?.toString() ?? 'warning',
        'dnsMode': settings['dnsMode']?.toString() ?? 'auto',
        'tunStack': settings['tunStack']?.toString() ?? 'gvisor',
        'tunAutoRoute': !(Platform.isAndroid || Platform.isIOS),
        // iOS 走「扩展注入 fd + socketpair 桥」，必须关 recvmsgx（见生成器注释）；
        // Android 是 Linux 侧 tun 实现、桌面由内核自建接口，都不需要
        'tunFdInjected': Platform.isIOS,
        // iOS：规则集用相对文件名（扩展启动时把自己的 work 目录设为工作目录）
        'ruleSetDir': Platform.isIOS ? '' : geoDirForRules,
        'udpSkipCertVerify': settings['udpSkipCertVerify'] != false,
        'bypassDomains': (settings['bypassDomains'] as List?)?.cast<String>() ?? const [],
        'forceProxyDomains': (settings['forceProxyDomains'] as List?)?.cast<String>() ?? const [],
        'dnsNameservers': (settings['dnsNameservers'] as List?)?.cast<String>() ?? const [],
        'fakeIpFilterExtra': (settings['fakeIpFilterExtra'] as List?)?.cast<String>() ?? const [],
      });
      await _core.start(cfg);
      if (epoch != _epoch) {
        // 连接建立期间用户已断开/发起新连接：内核此刻才起来，若直接 return
        // 会残留一个「在跑但 UI 显示已断开」的孤儿内核（流量仍走、再连报
        // 「内核已在运行」）。必须立刻停掉。
        unawaited(_core.stop());
        return;
      }
      status = ConnStatus.connected;
      connectedAt = DateTime.now();
      // 不立刻清零重连计数：只有稳定存活够久才算「真的连上了」，才允许把
      // 计数归零（见 _stableResetTimer 说明）
      _stableResetTimer?.cancel();
      _stableResetTimer = Timer(_stableResetAfter, () {
        // 稳定存活够久才算「真的连上了」→ 重连/崩溃自愈计数一并归零
        // （否则「能启动但几十秒后必崩」的内核会被计数逐步耗尽额度）
        _reconnectCount = 0;
        _kernelRecoverCount = 0;
        _crashRecoveryChain = false;
      });
      sessionUpMB = 0;
      sessionDownMB = 0;
      AppLog.conn('connected via ${current?.tag} (${current?.type})');
      // 内核就绪后回放一次「当前节点」到对应组（select=智能 / GLOBAL=全局）：
      // - 全局模式：内核内置 GLOBAL 组默认选中 proxies 首个节点，与用户预选
      //   (可能在列表中间)不一致 → 出口跳到别的线路，必须回放纠正；
      // - 智能模式：connect 期间(connecting 窗口)用户切换了节点只改了 current，
      //   内核 select 组仍是配置默认项，同样回放纠正 → 「选了谁就走谁」。
      if (current != null) {
        try {
          await _core.switchNode(current!.tag);
        } catch (_) {
          // 组指向失败不阻塞连接(自动测速/手动切换可再纠正)
        }
      }
      // 后台测速：不阻塞连接，完成后在同国范围内择优。
      // forceBest:false —— 尊重用户已选节点/已锁国家：当前节点在线且未明显
      // 劣化（<100ms）就不切换，避免「刚手动选的节点被无条件换掉→出口 IP
      // 跳动」；若用户从未选择过，current 即全局最优，行为与原先一致。
      if (runSpeedTest && autoTest) {
        unawaited(_autoSpeedTestAndSwitch(epoch, forceBest: false));
      }
      _startBackgroundTest(intervalMin);
      unawaited(refreshRealCountry(force: true)); // 实测真实出口国家（新隧道，强制重查）
    } catch (e) {
      if (epoch != _epoch) return;
      _releaseWakeLock();
      status = ConnStatus.error;
      AppLog.error('connect failed: $e');
      final TypedConnError? typedErr = e is TypedConnError ? e : null;
      errorKind = typedErr?.kind ?? ConnErrorKind.unknown;
      // StateError('内核已在运行') 是内部并发守卫触发的英文串（Bad state: ...），
      // 不该直接展示给用户；转成可读文案。
      // TUN 启动失败：按分类给出**可执行**的提示（提权 / 网卡冲突 / 驱动被拦），
      // 并把内核尾部日志落到日志中心 —— 比一句万能的「请以管理员身份运行」有用。
      final tunErr = e is TunStartException ? e : null;
      var errMsg = tunErr != null
          ? _tunFailureMessage(tunErr.failure)
          : (typedErr?.message ??
              (e is UnsupportedError
                  ? _core.lastError ?? e.message
                  : (e is StateError ? AppStrings.t('kernel_busy') : e.toString())));
      if (tunErr != null) {
        AppLog.error('[TUN] 启动失败（${tunErr.failure.name}）：${tunErr.tail}');
      }
      // 桌面 TUN 的权限提示兜底：只匹配**真正的权限类文本**。
      // 旧实现在这里还带一个 `'tun'` 子串 —— 任何提到 tun 的错误都会被改写成
      // 「需要管理员权限」，把「网卡冲突 / 驱动被拦」这类真因掩盖掉。
      if (tunErr == null &&
          typedErr == null &&
          (Platform.isMacOS || Platform.isWindows) &&
          (tunMode == 'force' || tunMode == 'auto')) {
        final errLower = errMsg?.toLowerCase() ?? '';
        if (errLower.contains('permission') ||
            errLower.contains('operation not permitted') ||
            errLower.contains('access is denied') ||
            errLower.contains('access denied')) {
          errMsg = Platform.isMacOS
              ? AppStrings.t('tun_need_admin_mac')
              : AppStrings.t('tun_need_admin_win');
        }
      }
      error = errMsg;
      // 注意：这里不再手动 restore 系统代理 —— 代理生命周期绑定内核
      // 启停（ProxyCoreCli.start/stop），且失败路径的异步 restore 可能与
      // 下一次重连成功后的 apply 交错，出现「已连接但系统代理被误关」；
      // 系统代理异常时由连接期的保活巡检自动恢复（见 SystemProxyManager）。
      // 重连链不中断：重连发起的连接失败 → 继续调度下一次重试（上限取自
      // 设置 reconnectTimes；内核崩溃自愈链在 autoReconnect 关闭时用自愈额度，
      // 见 [_autoRetryAllowed]）。例外：**确定性**失败不重试 ——
      //  - TUN 权限类失败：进程不可能运行中拿到管理员权限；
      //  - Android 多用户/分身空间拦截（androidMultiUserBlocked）：普通 App 不可能
      //    拿到 INTERACT_ACROSS_USERS，用户不换空间就永远失败（线上日志里连续
      //    3 次、每次白等 20s 就是这个）。
      if (fromReconnect &&
          _autoRetryAllowed &&
          errorKind != ConnErrorKind.androidMultiUserBlocked &&
          (tunErr == null || isRetryableTunFailure(tunErr.failure))) {
        _scheduleReconnect();
      }
    }
    notifyListeners();
  }

  /// 统一测速入口：**按用户选定的测速方式**分流（设置页可切，默认内核测速）。
  ///
  /// - [SpeedTestMode.kernel]（内核测速 / 真连接，默认）：
  ///   1. 已连接且内核在跑 → 直接走内核 Clash API delay（复用连接中的内核）；
  ///   2. 未连接（桌面端）→ 拉起**测速专用临时内核**再测（可取消、空闲自动回收）；
  ///   3. 移动端（内核在系统隧道进程里，App 起不了第二个）或临时内核启动失败
  ///      → 抛 [KernelProbeException]，由调用方明确提示用户「先连接」，
  ///      **绝不静默退回 TCP**。
  /// - [SpeedTestMode.tcp]（TCP 测速 / Ping，用户可选）：始终走纯 TCP 探测，
  ///   即使已连接也不会偷偷换成内核实测（用户的选择必须被尊重）。
  ///
  /// [onEach] 每测完一个节点即回调 (tag, 延迟, 在线)，供上层实时回填 UI。
  Future<List<ProxyNode>> testAllNodes(List<ProxyNode> list,
      {void Function(int done, int total)? onProgress,
      void Function(String tag, int latencyMs, bool online)? onEach,
      bool Function()? shouldStop}) async {
    if (speedTestMode == SpeedTestMode.tcp) {
      return SpeedTester.instance.testAll(list,
          onProgress: onProgress, onEach: onEach, shouldStop: shouldStop);
    }
    if (status == ConnStatus.connected && _core.isRunning) {
      return _testViaKernel(list,
          onProgress: onProgress, onEach: onEach, shouldStop: shouldStop);
    }
    return _testViaProbeKernel(list,
        onProgress: onProgress, onEach: onEach, shouldStop: shouldStop);
  }

  /// 桌面端内核测速（未连接时）：拉起临时探测内核 → 并发 delay → 结果回填。
  ///
  /// 失败（平台不支持 / 找不到内核二进制 / 内核起不来）一律抛
  /// [KernelProbeException]，调用方负责把原因显示给用户。
  Future<List<ProxyNode>> _testViaProbeKernel(List<ProxyNode> nodes,
      {void Function(int done, int total)? onProgress,
      void Function(String tag, int latencyMs, bool online)? onEach,
      bool Function()? shouldStop}) async {
    if (nodes.isEmpty) return nodes;
    await SpeedProbeKernel.instance.ensureStarted(nodes);
    // 取消条件 = 上层的取消 + 本轮 epoch 失效（用户点了连接/断开：
    // connect() 会在开始处收掉探测内核，此刻在途的探测结果必须**作废**，
    // 否则会把「内核已被收掉」误记成「节点不可用」）。
    final probeEpoch = _epoch;
    // startedRunning 用「启动后是否真的在跑」做基线：只有**本来在跑、
    // 中途被收掉**才算取消（真的取消了就别再回填）；否则（例如测试注入的
    // 延迟桩）不该被当成取消。
    final startedRunning = SpeedProbeKernel.instance.isRunning;
    bool cancelled() =>
        (shouldStop?.call() ?? false) ||
        probeEpoch != _epoch ||
        (startedRunning && !SpeedProbeKernel.instance.isRunning);
    return _delayAllViaKernel(
      nodes,
      (tag) => SpeedProbeKernel.instance.testDelay(tag,
          timeout: speedTestTimeout, url: testUrl),
      onProgress: onProgress,
      onEach: onEach,
      shouldStop: cancelled,
    );
  }

  /// 内核测速超时（毫秒口径与设置页/clash delay 的 timeout 参数一致）。
  static const speedTestTimeout = Duration(seconds: 5);

  /// 内核 delay 并发跑一批节点（连接中的内核与临时探测内核共用这一段）。
  ///
  /// 并发上限 16：内核本身可处理更多，但每个 delay 都是一次**真实建连 +
  /// 一次 HTTP 往返**（走远端节点），并发过高会让远端按 IP 限速/封禁，
  /// 也让本机短暂占满 socket/FD（实测 100 并发时内核日志里开始出现
  /// `dial tcp: cannot assign requested address`）。
  Future<List<ProxyNode>> _delayAllViaKernel(
    List<ProxyNode> nodes,
    Future<int> Function(String tag) probe, {
    void Function(int done, int total)? onProgress,
    void Function(String tag, int latencyMs, bool online)? onEach,
    bool Function()? shouldStop,
  }) async {
    final result = [for (final n in nodes) n.clone()];
    var nextIdx = 0;
    var done = 0;
    const maxConcurrent = 16;

    Future<void> worker() async {
      while (true) {
        // 用户中途发起新一轮测速 → 立即收尾（不再发新的探测请求）
        if (shouldStop != null && shouldStop()) break;
        final idx = nextIdx;
        if (idx >= result.length) break;
        nextIdx++;
        final tag = result[idx].tag;
        // 面板展示性伪节点（📢官网/💬客服 之类 server=baidu.com 的占位项）
        // 不是真节点：订阅解析阶段（SubscriptionService._nodesFromYamlMap）
        // 已把它们滤掉，正常路径到不了这里；这里是防御性兜底 —— 一旦有人
        // 从别的入口塞进来，也跳过并清零，绝不给它编一个延迟
        // （内核里没有这条 proxy，delay 会 404）。
        if (isPanelPseudoNode(tag, result[idx].server)) {
          result[idx].latencyMs = -1;
          done++;
          onProgress?.call(done, result.length);
          onEach?.call(tag, -1, true);
          continue;
        }
        final ms = await probe(tag);
        // 探测期间被取代（用户点了连接/断开、或用户又发起新一轮测速）：
        // 本次结果作废且**不回填** —— 绝不能把一次被打断的探测记成「节点不可用」。
        if (shouldStop != null && shouldStop()) break;
        result[idx].latencyMs = ms;
        result[idx].online = mfLatencyUsable(ms);
        done++;
        onProgress?.call(done, result.length);
        onEach?.call(tag, ms, mfLatencyUsable(ms));
      }
    }

    final count = result.length < maxConcurrent ? result.length : maxConcurrent;
    await Future.wait(List.generate(count, (_) => worker()));
    return result;
  }

  /// 经内核并发测各节点延迟（**当前已连接的**内核；限流，避免一次性打爆内核）。
  /// 测速在**副本**上进行：绝不把结果就地写进传入列表的元素 —— 否则
  /// 断开/切网瞬间在途测速会把 UI 正在用的节点整批标成 offline（epoch
  /// 守卫只能阻止"整体替换"，挡不住"元素已被逐个改写"）。
  Future<List<ProxyNode>> _testViaKernel(List<ProxyNode> nodes,
      {void Function(int done, int total)? onProgress,
      void Function(String tag, int latencyMs, bool online)? onEach,
      bool Function()? shouldStop}) async {
    if (nodes.isEmpty) return nodes;
    return _delayAllViaKernel(
      nodes,
      (tag) => _core.testNodeDelay(tag, timeout: speedTestTimeout, url: testUrl),
      onProgress: onProgress,
      onEach: onEach,
      shouldStop: shouldStop,
    );
  }

  /// 测速串行化：同一时刻只跑一轮测速。旧实现是「忙就直接 return」，
  /// 于是连接后自动跑的后台测速会**静默吃掉**用户手动点的测速 ——
  /// 用户看到的是「点了 ⚡ 只弹了个提示、延迟一个没变、也没有进度」。
  Future<void>? _speedTestInFlight;

  /// 测速代次：新一轮测速一开始就自增，让在跑的那轮尽快收尾（其结果作废）。
  int _speedTestGen = 0;

  /// 统一测速入口（节点页 ⚡ / 首页 ⚡ / 后台自动测速都走这里）。
  ///
  /// [tags] 非空 = **只测这些节点**（节点页搜索/筛选后），null = 测全部。
  /// [userInitiated] true = 用户主动点的：即使已有测速在跑也会**排队执行**，
  ///   并先让在跑的那轮收尾（通常几百毫秒内），绝不静默丢弃请求。
  /// 返回**实际测过的节点数**（0 = 一个都没测，调用方不要谎报"已完成"）。
  Future<int> speedTest({
    Set<String>? tags,
    bool switchToBest = true,
    bool userInitiated = true,
    void Function(int done, int total)? onProgress,
  }) async {
    if (nodes.isEmpty) return 0;
    final running = _speedTestInFlight;
    if (running != null) {
      if (!userInitiated) return 0; // 后台自动测速：忙就跳过，避免任务堆叠
      _speedTestGen++; // 让在跑的那轮尽快收尾
      await running;
    }
    final targets = tags == null
        ? List<ProxyNode>.of(nodes)
        : nodes.where((n) => tags.contains(n.tag)).toList();
    if (targets.isEmpty) return 0;
    final gen = ++_speedTestGen;
    final task = _runSpeedTest(
      targets,
      replaceAll: tags == null,
      switchPolicy: switchToBest ? _SwitchPolicy.best : _SwitchPolicy.none,
      onProgress: onProgress,
      gen: gen,
      epoch: _epoch,
    );
    _speedTestInFlight = task;
    try {
      return await task;
    } finally {
      if (identical(_speedTestInFlight, task)) _speedTestInFlight = null;
    }
  }

  /// 执行一轮测速。[replaceAll] true=整体替换节点列表（测了全部），
  /// false=只把被测节点替换回去（未测节点状态原样保留）。
  Future<int> _runSpeedTest(
    List<ProxyNode> targets, {
    required bool replaceAll,
    required _SwitchPolicy switchPolicy,
    required int gen,
    required int epoch,
    void Function(int done, int total)? onProgress,
  }) async {
    bool cancelled() => gen != _speedTestGen || epoch != _epoch;
    speedTesting = true;
    // 记录**本轮实际使用的**测速方式：用户可能在测速途中改设置，结果必须归属
    // 于真正执行的那一种（否则 UI 会把 TCP 的数字标成「内核测速」）。
    final mode = speedTestMode;
    speedTestError = null;
    notifyListeners();
    try {
      final tested = await testAllNodes(
        targets,
        onProgress: onProgress,
        onEach: (tag, ms, online) {
          if (gen != _speedTestGen) return; // 已被更新的一轮取代：不再回填
          _mergeOneLatency(epoch, tag, ms, online);
        },
        shouldStop: cancelled,
      );
      if (cancelled()) return 0; // 被新请求取代：本轮结果作废
      if (replaceAll) {
        nodes = tested;
      } else {
        // 只替换被测节点：未列入的节点既不改延迟也不改在线状态
        final byTag = {for (final t in tested) t.tag: t};
        nodes = [for (final n in nodes) byTag[n.tag] ?? n];
      }
      _retargetCurrent();
      lastSpeedTestTime = _now();
      lastSpeedTestMode = mode;
      await _applySwitchPolicy(switchPolicy, tested);
      return tested.length;
    } on KernelProbeException catch (e) {
      // 内核测速不可用（移动端未连接 / 临时内核起不来）→ **如实报错**。
      // 绝不在这里退回 TCP：用户选的就是内核测速，退回 TCP 等于给他一个
      // 「有延迟」的假象 —— 那正是本次要修掉的问题。
      speedTestError = e.detail == null ? e.message : '${e.message}：${e.detail}';
      AppLog.error('内核测速失败: $speedTestError');
      return 0;
    } catch (e) {
      speedTestError = '$e';
      AppLog.error('测速失败: $e');
      return 0;
    } finally {
      speedTesting = false;
      notifyListeners();
    }
  }

  /// 测速后的切换策略：
  /// - [none]：手动挑节点场景，只填延迟，不动当前线路
  /// - [best]：直接切到实测最优（节点页 / 用户点「自动最优」）
  /// - [auto]：连接后的后台测速，只在当前线路离线或明显更慢（>100ms）时才切，
  ///   避免把用户手选的线路无谓地换掉
  Future<void> _applySwitchPolicy(
      _SwitchPolicy policy, List<ProxyNode> tested) async {
    if (policy == _SwitchPolicy.none) return;
    // 用户固定了节点 → 任何自动策略都不换（测速只更新延迟数字）；
    // 「自动选择最优」是显式动作（unlockSelection），不走这里
    if (pinnedTag != null) return;
    if (status != ConnStatus.connected || !_core.isRunning) return;
    final best = selectBestRespectingLock(tested);
    if (best == null) return;
    if (policy == _SwitchPolicy.best) {
      await switchNode(best, userInitiated: false);
      return;
    }
    final cur = current;
    if (cur == null) {
      await switchNode(best, userInitiated: false);
      return;
    }
    final curOnline =
        nodes.firstWhere((n) => n.tag == cur.tag, orElse: () => cur);
    if (!curOnline.online ||
        (best.latencyMs >= 0 &&
            curOnline.latencyMs >= 0 &&
            best.latencyMs < curOnline.latencyMs - 100)) {
      await switchNode(best, userInitiated: false);
    }
  }


  /// 在 [tested] 中按 lockedCountry 过滤后选延迟最优节点。
  /// 锁定国家无候选/无在线节点时返回 null（宁可不切换，也绝不跨国家跳）。
  /// 用户固定了具体节点时**恒返回 null**：自动换线的所有调用点都以此为准，
  /// 一处收敛，避免遗漏某条回落路径把用户的固定悄悄换掉。
  ProxyNode? selectBestRespectingLock(List<ProxyNode> tested) {
    if (pinnedTag != null) return null;
    if (lockedCountry == null) return SpeedTester.selectBest(tested);
    final candidates = tested
        .where((n) => (n.countryCode?.toUpperCase() ?? 'XX') == lockedCountry)
        .toList();
    return SpeedTester.selectBest(candidates);
  }

  /// 测单个节点延迟(节点行"点一下测")：按选定的测速方式走
  /// （内核测速＝已连接用当前内核 / 未连接用临时探测内核；TCP＝纯 TCP）。
  /// 返回 ms(失败 -1)，不修改任何列表。
  Future<int> testOneNode(ProxyNode node) async {
    if (isPanelPseudoNode(node.tag, node.server)) return -1;
    if (speedTestMode == SpeedTestMode.tcp) {
      return SpeedTester.instance.testOne(node);
    }
    if (status == ConnStatus.connected && _core.isRunning) {
      return _core.testNodeDelay(node.tag, timeout: speedTestTimeout, url: testUrl);
    }
    try {
      await SpeedProbeKernel.instance.ensureStarted(nodes.isEmpty ? [node] : nodes);
    } on KernelProbeException catch (e) {
      AppLog.log('SPEED', '单点内核测速不可用: $e');
      rethrow;
    }
    return SpeedProbeKernel.instance
        .testDelay(node.tag, timeout: speedTestTimeout, url: testUrl);
  }

  /// 手动重新测速并切换最优（首页「重新测速/自动最优」在已连接时走这里；
  /// 只测速+热切换节点，不重启内核、不断网）
  Future<void> retest() async {
    if (nodes.isEmpty) return;
    // 用户主动触发（首页「重新测速/自动最优」）：排队执行，不被后台测速吃掉
    await speedTest(switchToBest: true, userInitiated: true);
  }

  /// 实时测速通知节流：逐节点回填每来一次就 notifyListeners 会在千节点时
  /// 触发上千次整页重建；这里≥100ms 才推一次（约 10fps，肉眼已是"实时"）。
  DateTime _lastLiveNotify = DateTime.fromMillisecondsSinceEpoch(0);
  static const _liveNotifyGap = Duration(milliseconds: 100);

  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastLiveNotify) >= _liveNotifyGap) {
      _lastLiveNotify = now;
      notifyListeners();
    }
  }

  /// 把单个节点的测速结果就地回填进当前展示列表（实时 UI 用）。
  /// [epoch] 守卫：断开/重连会自增 _epoch，本轮测速立即失效停止回填 ——
  /// 绝不把正在拆除连接测出的 offline 结果写进用户在用的列表。
  void _mergeOneLatency(int epoch, String tag, int latencyMs, bool online) {
    if (epoch != _epoch) return;
    for (final n in nodes) {
      if (n.tag == tag) {
        n.latencyMs = latencyMs;
        n.online = online;
        break;
      }
    }
    _throttledNotify();
  }

  /// 统一「实时测速」入口：逐节点回填 + 节流刷新，测完按需切最优。
  /// - 节点页「⚡测速」、首页选择器「⚡测速」都走这里；
  /// - [switchToBest] 已连接且允许时测完切到最优（节点页/自动选优 true；
  ///   首页选择器手动挑节点时传 false，不打断用户选择）；
   /// 手动重新测速（节点页 / 首页「⚡测速」）：[switchToBest] 已连接且允许时
  /// 测完切到最优；[tags] 非空时只测这些节点（节点页筛选后）。
  /// 返回实际测过的节点数。
  Future<int> retestAll({
    bool switchToBest = true,
    bool userInitiated = true,
    void Function(int done, int total)? onProgress,
  }) =>
      speedTest(
        switchToBest: switchToBest,
        userInitiated: userInitiated,
        onProgress: onProgress,
      );

  /// 后台测速 + 自动切换最优节点（不阻塞连接；测速中保持已连接状态，
  /// UI 通过 speedTesting 标记显示「测速中」）。
  /// 尊重 [lockedCountry]：用户手动选了国家后，只在该国范围内选最优。
  Future<void> _autoSpeedTestAndSwitch(int epoch, {bool forceBest = false}) async {
    // 已有测速在跑（用户手动或上一轮后台）→ 跳过本轮，绝不与用户抢
    if (nodes.isEmpty || _speedTestInFlight != null) return;
    final gen = ++_speedTestGen;
    final task = _runSpeedTest(
      List<ProxyNode>.of(nodes),
      replaceAll: true,
      switchPolicy: forceBest ? _SwitchPolicy.best : _SwitchPolicy.auto,
      gen: gen,
      epoch: epoch,
    );
    _speedTestInFlight = task;
    try {
      await task;
    } finally {
      if (identical(_speedTestInFlight, task)) _speedTestInFlight = null;
    }
  }

  void _clearState() {
    speedTesting = false;
    upSpeedMbps = 0;
    downSpeedMbps = 0;
    speedNotifier.value = const SpeedSnapshot();
    status = ConnStatus.disconnected;
    error = null;
    errorKind = ConnErrorKind.none;
    realCountry = null;
    realCountryFailed = false;
    lockedCountry = null;
    connectedAt = null;
    sessionUpMB = 0;
    sessionDownMB = 0;
    upHistory.clear();
    downHistory.clear();
    // 用户主动断开/登出：本轮崩溃自愈链作废（下次内核崩了重新给满额度）
    _crashRecoveryChain = false;
    _kernelRecoverCount = 0;
  }

  /// 在途的内核停止任务（disconnect/resetForLogout 发起）。
  /// connect 前 await 它，保证「旧内核停干净 + 系统代理已恢复」之后
  /// 新内核才启动 —— 杜绝停/启并发（旧 stop 关掉新内核/误关新代理）。
  Future<void>? _stopInFlight;

  Future<void> disconnect() async {
    _epoch++;
    // 断开时一并收掉测速专用内核：断开后用户若再测速会重新拉起，
    // 但不该让它在后台一直挂着（探针内核与连接状态机无关，必须显式收）。
    unawaited(SpeedProbeKernel.instance.stop());
    AppLog.conn('disconnect requested');
    _reconnectTimer?.cancel();
    _stableResetTimer?.cancel();
    _bgTestTimer?.cancel();
    _releaseWakeLock();
    status = ConnStatus.disconnecting;
    notifyListeners();
    _clearState();
    final stopFut = _core.stop().catchError((e) {
      AppLog.error('disconnect stop failed: $e');
    });
    _stopInFlight = stopFut;
    try {
      await stopFut;
    } catch (_) {}
    if (identical(_stopInFlight, stopFut)) _stopInFlight = null;
    notifyListeners();
  }

  /// 端口被占用时的自救：换一个空闲端口写回设置，然后重连。
  ///
  /// 为什么必须是**用户点一下**才执行（首页错误区的「换端口并重连」）：
  /// 本地端口是用户配置项（系统代理也会指向它），静默改掉等于「我明明设的是
  /// 2080，怎么自己变了」。做成显式动作，用户知道发生了什么、也随时能改回去。
  ///
  /// 只会改**真的被占用**的那个端口：本地代理端口 / Clash API 端口各自判断，
  /// 两者永远不同号（内核要求）。
  Future<void> fixPortAndReconnect() async {
    if (status != ConnStatus.disconnected) {
      try {
        await disconnect();
      } catch (_) {}
    }
    final s = await SettingsStore.instance.load();
    final local = _asPort(s['localPort'], 2080);
    final clash = _asPort(s['clashApiPort'], 9090);
    var newLocal = local;
    if (!await PortGuard.isFree(local)) {
      newLocal = await PortGuard.pickFree(from: local + 1, avoid: {clash});
    }
    var newClash = clash;
    if (newClash == newLocal || !await PortGuard.isFree(clash)) {
      newClash = await PortGuard.pickFree(from: clash + 1, avoid: {newLocal});
    }
    await SettingsStore.instance.update((m) {
      m['localPort'] = newLocal;
      m['clashApiPort'] = newClash;
    });
    AppLog.log('PORT', '端口自救：本地代理 $local→$newLocal，Clash API $clash→$newClash');
    notifyListeners();
    await connect();
  }

  Future<void> resetForLogout() async {
    _epoch++;
    _reconnectTimer?.cancel();
    _stableResetTimer?.cancel();
    _bgTestTimer?.cancel();
    _clearState();
    // 登出/切号：清掉持久化的节点选择（含固定节点/锁定国家），
    // 避免旧账号的固定线路残留到新账号
    pinnedTag = null;
    lockedCountry = null;
    unawaited(_clearPersistedSelection());
    final stopFut = _core.stop().catchError((e) {
      AppLog.error('resetForLogout stop failed: $e');
    });
    _stopInFlight = stopFut;
    try {
      await stopFut;
    } catch (_) {}
    if (identical(_stopInFlight, stopFut)) _stopInFlight = null;
    nodes = [];
    current = null;
    _autoConnectTried = false;
    notifyListeners();
  }

  /// 切换节点（热切换；失败则提示；成功后重测真实出口国家）。
  ///
  /// [userInitiated] = true 表示**用户点了这个节点** → 固定该节点（pinnedTag）：
  /// 后台测速/自动选优不再换节点，断开重连与重启后仍恢复它。
  /// 点「国家」走 [switchCountry]（只锁国家、允许在国内换节点）；
  /// 点「自动选择最优」走 [unlockSelection]。
  /// 自动选优/回落调用时传 false，不改动用户的固定与锁定。
  Future<void> switchNode(ProxyNode node, {bool userInitiated = true}) async {
    if (userInitiated) {
      pinnedTag = node.tag;
      lockedCountry = null; // 固定节点是国家锁的更强形式，二者互斥
      // 持久化：跨重启 / 断开重连后恢复（固定节点不跳的前提）
      unawaited(_persistSelection(node));
    }
    await _applyNodeSwitch(node);
  }

  /// 真正落地一次节点切换：内存态 + 内核热切换 + 出口国家重测。
  Future<void> _applyNodeSwitch(ProxyNode node) async {
    current = node;
    notifyListeners();
    if (status == ConnStatus.connected && _core.isRunning) {
      try {
        await _core.switchNode(node.tag);
        realCountry = null;
        realCountryFailed = false;
        notifyListeners(); // 立即清掉旧国家显示（切换后先显示「检测中」，不停在旧值）
        // 出口已变，强制重查绕过 TTL 缓存 —— 否则 10 分钟内真实出口显示不更新
        unawaited(refreshRealCountry(force: true));
      } catch (e) {
        error = AppStrings.t('node_switch_fail', {'err': '$e'});
        errorKind = ConnErrorKind.none;
        notifyListeners();
      }
    }
  }

  /// 切换模式（智能/全局）
  Future<void> toggleMode(bool smart) async {
    _modeUserSet = true;
    smartMode = smart;
    notifyListeners();
    if (status != ConnStatus.connected || !_core.isRunning) return;
    if (Platform.isAndroid) {
      if (switchingMode) return; // 切换中忽略再次点击
      // Android 内核以 embed(cmfa)模式运行：Clash API 禁 PATCH /configs(405)，
      // 无法热切模式 → 自动断开并以新模式重连（1~2s）。
      // 参考：sing-box 嵌入模式（SetEmbedMode）同样禁用 update/patch configs。
      switchingMode = true;
      notifyListeners();
      unawaited(_modeRestartByReconnect());
      return;
    }
    try {
      await _core.switchMode(smart);
    } catch (e) {
      AppLog.error('mode switch failed: $e');
      error = AppStrings.t('mode_switch_fail', {'err': '$e'});
      errorKind = ConnErrorKind.none;
      notifyListeners();
    }
  }

  /// Android 模式切换：断开后立即用当前（新）模式重连。
  Future<void> _modeRestartByReconnect() async {
    // 断开会清 lockedCountry（_clearState），但模式切换只是重启内核，
    // 用户锁定的国家/线路不应丢 —— 先记住，重连后若未恢复则补回。
    final keepLock = lockedCountry;
    final keepTag = current?.tag;
    try {
      await disconnect();
    } catch (_) {}
    try {
      if (status == ConnStatus.disconnected && nodes.isNotEmpty) {
        await connect();
      }
    } catch (_) {}
    // connect 已按持久化记忆恢复 lastSelectedTag 与锁；无记忆时用 keepLock 补
    if (lockedCountry == null && keepLock != null) {
      final stillHas = nodes
          .any((n) => (n.countryCode?.toUpperCase() ?? 'XX') == keepLock);
      if (stillHas) lockedCountry = keepLock;
    }
    if (current == null && keepTag != null) {
      for (final n in nodes) {
        if (n.tag == keepTag) {
          current = n;
          break;
        }
      }
    }
    switchingMode = false;
    notifyListeners();
  }

  /// 热更内核日志级别（「内核日志」实时页用）：连接时即时生效并持久化，
  /// 下次连接按该级别启动。返回是否**即时生效**（false = 只保存了设置，
  /// 需重连后生效 → 调用方应提示用户，避免「改了没反应」被当成故障）。
  Future<bool> setKernelLogLevel(String level) async {
    var liveApplied = false;
    if (!Platform.isAndroid) {
      // 桌面内核可热更 log-level；Android embed 模式禁 PATCH(405)，
      // 仅保存设置，下次连接按该级别启动
      try {
        if (status == ConnStatus.connected && _core.isRunning) {
          await _core.setKernelLogLevel(level);
          liveApplied = true;
        }
      } catch (_) {}
    }
    try {
      await SettingsStore.instance.update((s) => s['kernelLogLevel'] = level);
    } catch (_) {}
    return liveApplied;
  }

  /// 网络环境变化（WiFi↔蜂窝切换）：已连接且内核在跑时，不重启内核，
  /// 仅重新测速选优（内核的 TCP/UDP 连接会自动恢复，重启反而断流）。
  /// 自动测速开关关闭时不做任何自动切换（切网不换用户当前线路）。
  void onNetworkChanged() {
    if (status != ConnStatus.connected || !_core.isRunning) return;
    if (!autoTest) return;
    unawaited(retest());
  }

  /// 内核异常退出回调：未连接/用户主动断开时忽略，否则走重连或放弃
  void onDisconnectedUnexpectedly() {
    AppLog.kernel('unexpected exit, status=$status, autoReconnect=$autoReconnect, '
        'count=$_reconnectCount, recover=$_kernelRecoverCount');
    if (status != ConnStatus.connected && status != ConnStatus.reconnecting) {
      return; // 用户主动断开/未连接时不重连
    }
    // 熔断：短时间内反复异常退出（内核被 OOM/安全软件反复杀、端口/缓存锁
    // 持续冲突）→ 停止自动重连。否则「启动成功但几秒后必崩」的内核会无限
    // connect→崩→reconnect 循环。
    final now = DateTime.now();
    _unexpectedExitAt.removeWhere((t) => now.difference(t) > _exitWindow);
    _unexpectedExitAt.add(now);
    final burst = _unexpectedExitAt.length > _exitBurstLimit;
    // 本次是「内核进程消失」触发 → 标记为崩溃自愈链：即使 autoReconnect 关闭，
    // 也必须拉起来（额度见 [_maxKernelRecover]，判定见 [decideCrashRecovery]）
    _crashRecoveryChain = true;
    final action = decideCrashRecovery(
      autoReconnect: autoReconnect,
      burst: burst,
      reconnectCount: _reconnectCount,
      maxReconnect: _maxReconnect,
      kernelRecoverCount: _kernelRecoverCount,
      maxKernelRecover: _maxKernelRecover,
    );
    if (action == CrashRecoveryAction.giveUp) {
      status = ConnStatus.disconnected;
      // 文案分层：开了自动重连却「重连次数耗尽」沿用原文案；内核反复异常退出
      // 则直接指向「谁在杀内核」的排查方向（安全软件拦截 / 端口与缓存锁冲突 /
      // 旧 CPU 指令集与新版内核不兼容），而不是含糊的「连接已断开」。
      final exhausted =
          !burst && autoReconnect && _reconnectCount >= _maxReconnect;
      error = _withKernelReason(exhausted
          ? AppStrings.t('reconnect_exhausted')
          : AppStrings.t('kernel_crash_recover_failed'));
      errorKind = ConnErrorKind.none;
      unawaited(SystemProxyManager.restore());
      LocalNotify.instance.showReconnectFailed();
      notifyListeners();
      return;
    }
    _scheduleReconnect();
  }

  /// 把内核侧错误摘要（含 `code=-9` 这类退出码）拼到用户可见的错误文案上。
  /// 旧实现只显示「重连 N 次仍失败」这类通用文案，退出码与 stderr 只写进
  /// app_log.txt，用户排查内核被杀必须自己进「日志中心」翻。
  String _withKernelReason(String base) {
    final raw = _core.lastError;
    if (raw == null || raw.trim().isEmpty) return base;
    final first = raw.trim().split('\n').first.trim();
    if (first.isEmpty) return base;
    final brief = first.length > 120 ? '${first.substring(0, 120)}…' : first;
    return '$base：$brief';
  }

  /// TUN 启动失败的分类 → 可执行文案。
  /// 旧实现不分原因，一律提示「请以管理员身份运行」，于是「同名虚拟网卡残留」
  /// 与「驱动被安全软件拦」这两类非权限问题被掩盖，用户按提示提权后照样失败。
  String _tunFailureMessage(TunStartFailure failure) => switch (failure) {
        TunStartFailure.privilege => AppStrings.t('tun_fail_privilege'),
        TunStartFailure.adapterBusy => AppStrings.t('tun_fail_adapter_busy'),
        TunStartFailure.driver => AppStrings.t('tun_fail_driver'),
        _ => AppStrings.t('tun_fail_unknown'),
      };

  /// 调度下一次重连（onDisconnectedUnexpectedly 与重连失败共用，
  /// 保证链条连续：第 1 次失败 → 第 2 次 → 第 3 次 → 放弃）
  void _scheduleReconnect() {
    status = ConnStatus.reconnecting;
    notifyListeners();
    _reconnectCount++;
    if (_crashRecoveryChain) {
      _kernelRecoverCount++;
      AppLog.conn('kernel crash recovery #$_kernelRecoverCount '
          '(autoReconnect=$autoReconnect)');
    }
    final delay = [1, 2, 5][(_reconnectCount - 1).clamp(0, 2)];
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
        Duration(seconds: delay), () => connect(runSpeedTest: true, fromReconnect: true));
  }

  void _onTraffic(double upMbps, double downMbps) {
    upSpeedMbps = upMbps;
    downSpeedMbps = downMbps;
    // 会话累计(采样≈1s 一次,按 MB 近似累加)
    sessionUpMB += upMbps;
    sessionDownMB += downMbps;
    // 速率历史(环形裁剪)
    upHistory.add(upMbps);
    if (upHistory.length > historyMax) upHistory.removeAt(0);
    downHistory.add(downMbps);
    if (downHistory.length > historyMax) downHistory.removeAt(0);
    // 只更新速率快照，不 notifyListeners —— 首页速率卡片用
    // ValueListenableBuilder(speedNotifier) 局部刷新，整页不重建
    speedNotifier.value = SpeedSnapshot(upMbps: upMbps, downMbps: downMbps);
  }

  /// 后台定时测速（设置 testIntervalMin；仅已连接时运行，断开即停 → 省电）。
  /// 受 [autoTest] 门控：用户关闭「自动测速/自动切换」后，不再周期性测速与
  /// 自动换节点（手动「重新测速」与节点页测速不受影响）。
  void _startBackgroundTest(int intervalMin) {
    _bgTestTimer?.cancel();
    if (intervalMin <= 0 || !autoTest) return;
    _bgTestTimer = Timer.periodic(Duration(minutes: intervalMin), (_) async {
      if (status != ConnStatus.connected || nodes.isEmpty || !_core.isRunning) return;
      if (!autoTest) return;
      final epoch = _epoch;
      final tested = await testAllNodes(nodes,
          onEach: (tag, ms, online) => _mergeOneLatency(epoch, tag, ms, online));
      if (epoch != _epoch) return;
      if (status != ConnStatus.connected || !autoTest) return;
      nodes = tested;
      _retargetCurrent(); // 列表整体替换后 current 重指向新实例
      // 用户固定了节点 → 只更新延迟，绝不换线（与 _applySwitchPolicy 同一规则）
      if (pinnedTag != null) {
        lastSpeedTestTime = _now();
        notifyListeners();
        return;
      }
      final best = selectBestRespectingLock(tested);
      final cur = current;
      if (best == null || cur == null) return;
      final curOnline = nodes.firstWhere(
          (n) => n.tag == cur.tag, orElse: () => cur);
      if (!curOnline.online ||
          (best.latencyMs >= 0 && curOnline.latencyMs >= 0 &&
              best.latencyMs < curOnline.latencyMs - 100)) {
        await switchNode(best, userInitiated: false);
      }
      lastSpeedTestTime = _now();
      notifyListeners();
    });
  }

  String _now() {
    final t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _bgTestTimer?.cancel();
    _wakeLockTimer?.cancel();
    // 测速专用内核是独立子进程：不显式收会变成孤儿（App 退出后仍占内存）
    unawaited(SpeedProbeKernel.instance.stop());
    _core.dispose();
    super.dispose();
  }
}
