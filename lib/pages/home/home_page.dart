import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../package/upgrade_devices_page.dart';

import '../../core/models/models.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/services/account_service.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/subscription_service.dart';
import '../../core/services/update_service.dart';
import '../../widgets/subscribe_issue.dart';
import '../../widgets/update_prompt.dart';
import '../../core/api/api_client.dart';
import '../../core/services/app_log.dart';
import '../../l10n/app_strings.dart';
import '../../core/services/geo_lookup.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import '../../widgets/country_flag.dart';
import '../devices/devices_page.dart';
import '../settings/settings_page.dart';

/// 首页 · 连接页（设计稿 02）
/// 电源按钮 / 智能·全局模式 / 自动测速选优卡 / 快速切换国家 / 实时速率
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _loadingNodes = false;

  /// 「开关开着但没有可用线路 → 自动连接没连上」的提示每次进页面只弹一次
  bool _autoConnectNoticeShown = false;

  static final _pillRadius = BorderRadius.circular(99);

  /// 连接状态下的呼吸动画（仅连接时运行，断开即停 → 省电 + 流畅）
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
    lowerBound: .35,
    upperBound: 1,
  );

  @override
  void initState() {
    super.initState();
    _ensureNodes();
    // 连接状态变化时启停呼吸动画
    ConnectionController.instance.addListener(_onConnChanged);
    // 启动后台检查发现新版本 → 弹一次更新提示（同版本一次运行只弹一次）
    UpdateService.hasUpdate.addListener(_onUpdateAvailable);
    _onLaunchAutoInstall();
    // 检查往往在本页挂载**之前**就完成了（启动即发起），那时只加监听收不到通知
    // → 用当前值补一次，否则「检查比进主页快」时永远不会弹（静默错过更新）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onUpdateAvailable();
    });
    // 回前台自动刷新订阅（保活页面避免数据过期）
    WidgetsBinding.instance.addObserver(this);
  }

  /// 有新版本时弹提示。放到首帧之后：构建期弹窗会抛异常。
  void _onUpdateAvailable() {
    if (!UpdateService.hasUpdate.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(UpdatePrompt.maybePromptOnLaunch(context));
    });
  }

  /// 启动时先补最后一步：后台已下载好的新版本包直接静默安装（Windows 安装版）。
  /// 这样「点了检查更新 → 后台下好 → 重启」就能真正完成升级，而不是永远停在
  /// 「已下载」。
  void _onLaunchAutoInstall() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(UpdatePrompt.maybeAutoInstallPending(context));
    });
  }

  @override
  void dispose() {
    UpdateService.hasUpdate.removeListener(_onUpdateAvailable);
    ConnectionController.instance.removeListener(_onConnChanged);
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _ensureNodes();
    }
  }

  void _onConnChanged() {
    if (!mounted) return;
    final s = ConnectionController.instance.status;
    if (s == ConnStatus.connected && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (s != ConnStatus.connected && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  /// 刷新账号状态 + 节点列表。
  /// 状态判定（到期/设备满/禁用）先于节点拉取完成，任何自动连接/手动连接
  /// 都能基于真实状态拦截——不会出现「拉订阅之前就放行」的窗口。
  Future<void> _ensureNodes({bool force = false}) async {
    final conn = context.read<ConnectionController>();
    final hadNodes = conn.nodes.isNotEmpty;
    // 一进页面立刻进入「正在更新订阅」态。
    //
    // 旧实现把 `_loadingNodes = true` 放在账号刷新**之后**，于是冷启动那一瞬间
    // nodes 仍为空、loading 仍为 false → 首页先闪出一句
    // 「节点加载失败，请检查网络后重试」+ 重试按钮（用户实测反馈）：明明只是订阅
    // 还在路上，却看起来像出错了。现在这一整段都算「更新订阅中」。
    if (mounted) setState(() => _loadingNodes = true);
    try {
      // 首次进入 / 下拉刷新时刷新账号状态（登录成功时已判定过一次，这里幂等）。
      // 状态判定先于节点拉取完成：任何自动连接/手动连接都能基于真实状态拦截，
      // 不会出现「拉订阅之前就放行」的窗口。
      if (force || !AccountService.instance.loaded) {
        await AccountService.instance.refresh(force: force);
      }
      if (!mounted) return;
      // 冷启动即时展示：账号**正常**（非受限）且当前无节点时，先读本地磁盘缓存
      // 秒显上次的线路（不发网络请求），避免弱网下干等订阅拉取 → 首页转圈或
      // 「切换主页空白」。放在门禁判定之后：受限账号（到期/禁用/设备满）绝不
      // 秒显旧线路误导用户，仍走下方 fetchNodes → applySubscriptionNodes([])
      // 清空展示的既有链路。断开态才注入，避免覆盖已连接会话。
      if (conn.nodes.isEmpty &&
          conn.status == ConnStatus.disconnected &&
          !AccountService.instance.isBlocked) {
        final cached = await SubscriptionService.instance.loadCachedNodes();
        if (!mounted) return;
        if (cached.isNotEmpty && conn.nodes.isEmpty) {
          await conn.loadNodes(cached);
        }
      }
      if (conn.nodes.isNotEmpty && !force) {
        // ★ 关键修复（2.2.23）：旧实现直接在这里 `return`，而
        // `autoConnectIfEnabled()` 只写在下面那条「真的走了网络拉订阅」的支路里
        // —— 于是**冷启动从磁盘缓存秒显线路**（老用户每次启动的常态）、
        // 或 nodes 已就绪时，自动连接那一行永远不执行：开关形同虚设
        // （诊断脚本实测：无缓存 → 连；有同版本缓存 → 不连；nodes 已就绪 → 不连）。
        // 现在「拿到线路」的两条支路都走同一个自动连接入口：只要有线路就尝试一次。
        await _autoConnect(conn);
        return;
      }
      final nodes = await SubscriptionService.instance.fetchNodes(force: force);
      if (!mounted) return;
      // 用受保护的合并入口:已连接且当前线路不在新订阅时保持现状(不打断),
      // 受限账号空列表清空展示 —— 与首页直接 loadNodes(无条件替换)区分
      await conn.applySubscriptionNodes(nodes);
      // 设置「启动时自动连接」→ 订阅加载完成后自动连接（每次启动仅一次；默认关闭）
      final auto = await _autoConnect(conn);
      // 刚才用户是对着「正在更新订阅，请稍等」在等 → 更新完必须告诉他下一步
      // （旧实现更新完什么都不说，用户以为还卡着）。
      // 已经自动连上时不再说「请点击连接」—— 同一句话会和自动连接互相矛盾。
      if (!hadNodes &&
          conn.nodes.isNotEmpty &&
          mounted &&
          auto != AutoConnectOutcome.started) {
        _toast(AppStrings.t('sub_updated_click_connect'));
      }
      // 拉取「成功但没节点」也要说清楚原因：到期 / 未开通 / 订阅被停用 /
      // 设备被移除 / 后端没给订阅地址 —— 每种都给能解决问题的按钮
      if (nodes.isEmpty) {
        if (!mounted) return;
        await SubscribeIssuePrompt.showIfAny(context,
            onRetry: () => _ensureNodes(force: true));
      }
    } catch (e) {
      if (mounted) {
        final msg = ApiClient.errorMsg(e);
        // 设备被踢下线：断开当前连接并清空节点，提示用户
        if (SubscriptionService.isKickedMessage(msg)) {
          await conn.disconnect();
          await conn.loadNodes(const []);
        }
        // 有可分类的原因（被移除/禁用/设备上限/网络）→ 弹可操作框；
        // 分类不出来才退回原始文案 toast
        if (!mounted) return;
        if (!await SubscribeIssuePrompt.showIfAny(context,
            onRetry: () => _ensureNodes(force: true))) {
          _toast(msg);
        }
      }
    } finally {
      if (mounted) setState(() => _loadingNodes = false);
    }
  }

  /// 尝试一次「启动时自动连接」，并把「开关开着却没连上」的原因讲清楚。
  ///
  /// 首页有 3 个入口会走到这里：冷启动（磁盘缓存秒显 / 网络订阅两条支路）、
  /// 下拉刷新、回前台自动刷新。门闩在 [ConnectionController.autoConnectIfEnabled]
  /// 里，所以多次调用最多只连一次。
  Future<AutoConnectOutcome> _autoConnect(ConnectionController conn) async {
    AutoConnectOutcome r;
    try {
      r = await conn.autoConnectIfEnabled();
    } catch (e) {
      // 判定本身出意外（设置读取异常等）：绝不静默吞掉
      AppLog.error('autoConnectIfEnabled failed: $e');
      if (mounted) _toast(ApiClient.errorMsg(e));
      return AutoConnectOutcome.noNodes;
    }
    if (!mounted) return r;
    switch (r) {
      case AutoConnectOutcome.noNodes:
        // 开关开着却连不上：只提示一次（订阅链路自己的提示更具体，这里兜底）
        if (!_autoConnectNoticeShown) {
          _autoConnectNoticeShown = true;
          _toast(AppStrings.t('auto_connect_no_nodes'));
        }
        break;
      case AutoConnectOutcome.blocked:
        // 门禁文案已在首页的受限横幅 + 错误区可见（自动连接被账号门禁拦截）
        break;
      case AutoConnectOutcome.started:
      case AutoConnectOutcome.disabled:
      case AutoConnectOutcome.alreadyTried:
      case AutoConnectOutcome.busy:
        break;
    }
    return r;
  }

  Future<void> _toggleConnect(ConnectionController conn) async {
    unawaited(HapticFeedback.mediumImpact());
    final acc = AccountService.instance;
    // 模式切换(自动断开重连)期间忽略连接按钮点击,避免竞态
    if (conn.switchingMode) return;
    if (conn.status == ConnStatus.disconnecting) {
      return; // 正在断开，忽略点击
    } else if (conn.status == ConnStatus.connected) {
      unawaited(conn.disconnect());
    } else if (conn.status == ConnStatus.testing ||
        conn.status == ConnStatus.connecting ||
        conn.status == ConnStatus.reconnecting) {
      unawaited(conn.disconnect());
      _toast(AppStrings.t('cancel_connect'));
    } else if (acc.isConnectionBlocked) {
      // 到期 / 被禁用 / 未开通 / **后端拒绝本设备（超限）**：先给对应提示，绝不放行
      // （状态在登录/进入主页时已判定，这里不依赖节点拉取结果）
      // 注意用 isConnectionBlocked 而不是 isBlocked：设备数达到上限但本机在允许
      // 范围内时（例如上限 5 台里的第 5 台）要正常连接，只提示不拦截。
      _showBlockedDialog(acc);
    } else if (conn.syncingSubscription && conn.nodes.isEmpty) {
      // 订阅还在同步：这是过程不是错误，别报"没有节点"
      _toast(AppStrings.t('sub_syncing_wait'));
    } else if (conn.nodes.isEmpty) {
      _toast(AppStrings.t('no_nodes'));
    } else {
      // 连接前：VPN 授权 + 通知（带首次说明框与授权失败引导卡，
      // 见 _ensurePermissionsGuided）
      final ok = await _ensurePermissionsGuided();
      if (!ok) return;
      unawaited(conn.connect());
    }
  }

  /// 连接前权限链（带引导）：
  /// 1) 尚未授权时先弹自家说明框——告诉用户接下来系统会请求 VPN 权限、
  ///    应该点「允许」，降低首次误点拒绝的概率；
  /// 2) 授权失败（点了拒绝 / 系统框被吞没有弹出）→ 底部引导卡：
  ///    重新授权 / 打开系统 VPN 设置（排查其他 VPN「始终开启」占用）/ 取消。
  /// 返回 true = 权限就绪可继续连接。桌面端 isVpnPrepared 恒 true，直接放行。
  Future<bool> _ensurePermissionsGuided() async {
    final ps = PermissionService.instance;
    // 已授权过 → 不打扰；未授权 → 先解释一次再弹系统框
    var explained = await ps.isVpnPrepared();
    while (true) {
      if (!mounted) return false;
      if (!explained) {
        explained = true; // 每轮连接流程只解释一次，后续重试直接弹系统框
        final go = await _showVpnExplainer();
        if (!go || !mounted) return false;
      }
      final ok = await ps.ensureAllForConnect();
      if (ok) return true;
      if (!mounted) return false;
      final action = await _showVpnDeniedSheet();
      switch (action) {
        case 'retry':
          continue; // 用户主动要求重试 → 再走一遍授权
        case 'settings':
          await ps.openVpnSettings();
          return false; // 用户去系统设置处理，回来后自行再点连接
        default:
          return false; // 取消/关闭引导卡
      }
    }
  }

  /// 首次连接的 VPN 授权说明框（仅在尚未授权时出现一次）
  Future<bool> _showVpnExplainer() async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.card2,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18))),
        title: Text('🔐\n${AppStrings.t('vpn_guide_title')}',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, height: 1.4)),
        content: Text(AppStrings.t('vpn_guide_text'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: MFColors.txt, height: 1.7)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MFColors.brand,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.t('vpn_guide_ok'),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return res == true;
  }

  /// 授权失败引导卡：返回 'retry' | 'settings' | null（取消）
  Future<String?> _showVpnDeniedSheet() {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: MFColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: MFColors.line2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('🚫 ${AppStrings.t('vpn_denied_title')}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(AppStrings.t('vpn_denied_text'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5, color: MFColors.txt, height: 1.6)),
              const SizedBox(height: 8),
              Text(AppStrings.t('vpn_denied_hint_always_on'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11.5, color: MFColors.txt3, height: 1.6)),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: MFColors.brand,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onPressed: () => Navigator.pop(ctx, 'retry'),
                child: Text(AppStrings.t('re_authorize'),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: MFColors.brand.withValues(alpha: .5)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onPressed: () => Navigator.pop(ctx, 'settings'),
                child: Text(AppStrings.t('open_vpn_settings'),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppStrings.t('cancel'),
                    style: TextStyle(color: MFColors.txt3)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 受限账号（到期/设备满/禁用/未开通）弹窗 → 一键跳对应处理页
  void _showBlockedDialog(AccountService acc) {
    final emoji = switch (acc.status) {
      AccountStatus.expired => '⏰',
      AccountStatus.deviceFull => '📱',
      AccountStatus.accountDisabled || AccountStatus.subscriptionDisabled => '🚫',
      AccountStatus.noSubscription => '🛒',
      _ => '⚠️',
    };
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
        title: Text('$emoji\n${acc.blockTitle}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.4)),
        content: Text(acc.blockText,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: MFColors.txt, height: 1.7)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          if (acc.status == AccountStatus.accountDisabled ||
              acc.status == AccountStatus.subscriptionDisabled) ...[
            // 被禁用：不可购买/不可连接，只给关闭
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.t('ok_btn')),
            ),
          ] else ...[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.t('cancel')),
            ),
            if (acc.status == AccountStatus.deviceFull) ...[
              // 设备超限：先给「管理设备」（删旧设备），再给「升级设备套餐」
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DevicesPage()));
                },
                child: Text(AppStrings.t('manage_devices'),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MFColors.brand,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              onPressed: () {
                Navigator.pop(context);
                if (acc.status == AccountStatus.deviceFull) {
                  // 设备超限 → 走「增量升级设备」页（+N 台/可选加时长/支付）
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const UpgradeDevicesPage()));
                } else {
                  mainTabIndex.value = 2; // 到期续费 / 新开通 → 套餐页
                }
              },
              child: Text(
                switch (acc.status) {
                  AccountStatus.deviceFull =>
                    AppStrings.t('go_upgrade_devices'),
                  AccountStatus.noSubscription =>
                    AppStrings.t('go_purchase'),
                  _ => AppStrings.t('go_renew'),
                },
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final acc = context.watch<AccountService>();
    final compact = MediaQuery.sizeOf(context).height < 820;
    final pad = compact ? 16.0 : 22.0;
    final gap = compact ? 6.0 : 12.0;
    final gapL = compact ? 6.0 : 14.0;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _ensureNodes(force: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: pad),
            children: [
              _buildHeader(),
              SizedBox(height: compact ? 2 : 6),
              _buildSubInfoBar(acc),
              SizedBox(height: gap),
              // 顶部横幅：受限状态 + 设备数已达上限都要提示。
              // 注意用 needsAttention 而不是 isBlocked —— 设备满必须给"升级设备/
              // 管理设备"的主动提示，但**不阻断**本机连接（范围内的第 N 台照常连）。
              if (acc.needsAttention) ...[
                _buildAccountBanner(acc),
                SizedBox(height: gap),
              ],
              // 连接卡片(含模式开关)：status/current/error/speedTesting/smartMode 变化时重建
              // 注意：selector 必须包含 realCountry / realCountryFailed —— 切国家后
              // switchNode 先把 realCountry 置 null（显示「检测中」）、再写回新国家
              // 或置失败态，若 selector 不监听它们，这几次 notifyListeners 都不会
              // 触发本卡重建，「真实出口」就停留在旧显示，直到别的字段变化才被动刷新。
              // sy（订阅同步中）必须进 selector：否则同步状态单独变化时
              // 连接卡不会重建 —— 会出现「同步中」文案一直挂着不消失
              Selector<ConnectionController, ({ConnStatus s, String? tag, String? err, bool st, bool sm, String? rc, bool rcf, bool sy})>(
                selector: (_, c) => (s: c.status, tag: c.current?.tag, err: c.error, st: c.speedTesting, sm: c.smartMode, rc: c.realCountry, rcf: c.realCountryFailed, sy: c.syncingSubscription),
                builder: (ctx, v, child) {
                  final conn = ctx.read<ConnectionController>();
                  final connected = conn.status == ConnStatus.connected;
                  final busy = conn.status == ConnStatus.testing || conn.status == ConnStatus.connecting || conn.status == ConnStatus.disconnecting || conn.switchingMode;
                  return _buildConnectCard(conn, connected, busy, compact);
                },
              ),
              SizedBox(height: gapL),
              RepaintBoundary(child: _buildStats(ConnectionController.instance, compact)),
              SizedBox(height: gapL),
              Selector<ConnectionController,
                  ({int nodesHash, String? curTag, String? lock, String? pin})>(
                selector: (_, c) => (
                  nodesHash: c.nodes.length,
                  curTag: c.current?.tag,
                  lock: c.lockedCountry,
                  pin: c.pinnedTag
                ),
                builder: (ctx, v, child) =>
                    _buildQuickCountries(ctx.read<ConnectionController>(), compact),
              ),
              SizedBox(height: compact ? 6 : 16),
            ],
          ),
        ),
      ),
    );
  }

  /// 订阅信息条：到期时间 / 设备数量 / 剩余天数。
  /// 颜色随账号状态变化（到期红 / 设备满橙 / 禁用红），正常态品牌蓝。
  Widget _buildSubInfoBar(AccountService acc) {
    final sub = acc.sub;
    final status = acc.status;
    final expired = status == AccountStatus.expired;
    final deviceFull = status == AccountStatus.deviceFull;
    final disabled = status == AccountStatus.accountDisabled ||
        status == AccountStatus.subscriptionDisabled;
    final warn = expired || deviceFull || disabled;
    String expireText = AppStrings.t('expire_na');
    if (sub?.expireTime != null) {
      final dt = sub!.expireTime!;
      expireText = '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    if (expired) expireText = AppStrings.t('expired_short');
    final deviceText = sub == null
        ? '—'
        : '${sub.currentDevices} / ${sub.deviceLimit}';
    final daysText = sub == null ? '—' : '${sub.remainingDays}';
    final color = disabled
        ? MFColors.red
        : expired
            ? MFColors.red
            : deviceFull
                ? MFColors.amber
                : MFColors.brand;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        gradient: warn
            ? LinearGradient(colors: [color.withValues(alpha: .18), color.withValues(alpha: .05)])
            : LinearGradient(colors: [
                MFColors.brand.withValues(alpha: .18),
                MFColors.brand.withValues(alpha: .06),
              ]),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withValues(alpha: warn ? .55 : .4)),
      ),
      child: Row(
        children: [
          _InfoCell(label: AppStrings.t('home_sub_expire'), value: expireText, flex: 2),
          _InfoCell(label: AppStrings.t('home_sub_devices'), value: deviceText, flex: 2),
          _InfoCell(
            label: AppStrings.t('home_sub_days'),
            value: sub == null ? '—' : '$daysText ${AppStrings.t('days')}',
            flex: 2,
            highlight: !warn && !expired,
          ),
          // 节点更新：显示最近成功拉取订阅的时间，点击立即刷新
          GestureDetector(
            onTap: _refreshSubManual,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 6, right: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _refreshing
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.refresh, size: 15, color: color),
                  const SizedBox(height: 3),
                  Text(
                    _fmtSubTime(),
                    style: TextStyle(
                        fontSize: 10,
                        color: MFColors.txt3,
                        fontFamily: kNumFont),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _refreshing = false;

  Future<void> _refreshSubManual() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await _ensureNodes(force: true);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _fmtSubTime() {
    final t = SubscriptionService.instance.lastUpdatedAt;
    if (t == null) return '--:--';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 受限账号顶部引导条：只有「确实受限」才出现，且按钮按状态区分 ——
  /// 到期→去续费；设备满→升级设备/管理设备；禁用→无购买按钮；未开通→去开通。
  /// 正常账号节点加载失败等临时问题不再被引导去购买（原实现按 nodes.isEmpty 判断）。
  Widget _buildAccountBanner(AccountService acc) {
    final status = acc.status;
    final (Color color, Color soft) = switch (status) {
      AccountStatus.expired => (MFColors.red, const Color(0x2EFF5A5F)),
      AccountStatus.deviceFull => (MFColors.amber, const Color(0x33FFB020)),
      AccountStatus.accountDisabled ||
      AccountStatus.subscriptionDisabled =>
        (MFColors.red, const Color(0x2EFF5A5F)),
      AccountStatus.noSubscription => (MFColors.amber, const Color(0x33FFB020)),
      _ => (MFColors.brand, MFColors.brand.withValues(alpha: .18)),
    };
    final emoji = switch (status) {
      AccountStatus.expired => '⏰',
      AccountStatus.deviceFull => '📱',
      AccountStatus.accountDisabled ||
      AccountStatus.subscriptionDisabled =>
        '🚫',
      AccountStatus.noSubscription => '🛒',
      _ => 'ℹ️',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [soft, color.withValues(alpha: .06)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(acc.blockText,
                style: TextStyle(fontSize: 12, color: MFColors.txt, height: 1.5)),
          ),
          if (status != AccountStatus.accountDisabled &&
              status != AccountStatus.subscriptionDisabled)
            GestureDetector(
              onTap: () {
                if (status == AccountStatus.deviceFull) {
                  // 设备满：管理设备（删除旧设备）优先级最高，次选升级
                  Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DevicesPage()));
                } else {
                  mainTabIndex.value = 2;
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                    gradient: MFColors.brandGradient,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(
                  switch (status) {
                    AccountStatus.expired => AppStrings.t('go_renew'),
                    AccountStatus.deviceFull =>
                      AppStrings.t('manage_devices'),
                    _ => AppStrings.t('go_purchase'),
                  },
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openNodePicker(ConnectionController conn) {
    if (conn.nodes.isEmpty) {
      _toast(AppStrings.t('no_nodes'));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MFColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _NodePickerSheet(conn: conn),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(11)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Image.asset('assets/moneyfly-logo.png', width: 36, height: 36),
            ),
          ),
          const SizedBox(width: 10),
           Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MoneyFly', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
              Text(AppStrings.t('home_ready'), style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
            ],
          ),
          const Spacer(),
          IconButton(
            icon:  Icon(Icons.refresh, size: 20, color: MFColors.txt2),
            tooltip: AppStrings.t('refresh_sub'),
            onPressed: _loadingNodes ? null : () => _ensureNodes(force: true),
          ),
          IconButton(
            icon:  Icon(Icons.settings_outlined, size: 20, color: MFColors.txt2),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectCard(ConnectionController conn, bool connected, bool busy, bool compact) {
    final acc = AccountService.instance;
    // 未连接时也展示「将连接」的线路：取当前选中，没有则默认列表第一个在线节点，
    // 避免有节点的正常用户看到「暂无节点/去开通」的误导（原实现 current==null 时误报）
    final node = conn.current ??
        (conn.nodes.isNotEmpty
            ? conn.nodes.firstWhere((n) => n.online, orElse: () => conn.nodes.first)
            : null);
    final statusColor = busy
        ? MFColors.amber
        : (connected ? MFColors.green : MFColors.txt3);
    final statusLabel = conn.switchingMode
        ? AppStrings.t('switching_mode')
        : switch (conn.status) {
            ConnStatus.testing => AppStrings.t('testing'),
            ConnStatus.connecting => AppStrings.t('connecting'),
            ConnStatus.disconnecting => AppStrings.t('disconnecting_status'),
            ConnStatus.reconnecting => AppStrings.t('reconnecting'),
            ConnStatus.connected =>
              conn.speedTesting
                  ? AppStrings.t('connected_speed_testing')
                  : AppStrings.t('connected'),
            ConnStatus.error => AppStrings.t('error'),
            _ => AppStrings.t('disconnected'),
          };
    return Container(
      padding: EdgeInsets.fromLTRB(16, compact ? 10 : 20, 16, compact ? 8 : 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        // #1 背景浅化：品牌蓝紫柔光渐变（不再深黑难辨）
        gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [
              MFColors.brand.withValues(alpha: .22),
              MFColors.brand.withValues(alpha: .06),
              Colors.white.withValues(alpha: .04),
            ]),
        border: Border.all(
            color: connected ? MFColors.green.withValues(alpha: .55) : MFColors.brand.withValues(alpha: .45)),
      ),
      child: Column(
        children: [
          // 状态文案定高 + 单行：文案在「已连接」↔「已连接 · 测速中」之间切换、
          // 窄窗口下也不折行，卡片高度恒定（避免每次自动测速都顶一下下方内容）
          SizedBox(
            height: 16,
            child: Text(statusLabel,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: statusColor)),
          ),
          // 已连接时长 + 本次流量(独立 1s 刷新,不重建整卡)
          if (connected) ...[
            const SizedBox(height: 5),
            _SessionInfo(conn: conn),
          ],
          SizedBox(height: compact ? 6 : 14),
          GestureDetector(
            onTap: () => _toggleConnect(conn),
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final glow = connected ? _pulse.value : 1.0;
                  return Container(
                    width: compact ? 62 : 108,
                    height: compact ? 62 : 108,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: connected
                              ? MFColors.green.withValues(alpha: .45 * glow)
                              : MFColors.brand.withValues(alpha: .25),
                          blurRadius: 34,
                        ),
                      ],
                    ),
                    child: child,
                  );
                },
                child: Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: connected
                        ? const RadialGradient(colors: [Color(0xFF1E3B3A), Color(0xFF0E1716)], stops: [0, .75])
                        : const RadialGradient(colors: [Color(0xFF1B2233), Color(0xFF0E121B)], stops: [0, .75]),
                    border: Border.all(
                        color: connected ? MFColors.green.withValues(alpha: .5) : MFColors.line2,
                        width: 1.2),
                  ),
                  child: Center(
                    child: busy
                        ? SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: statusColor,
                            ),
                          )
                        : Icon(
                            Icons.power_settings_new_rounded,
                            size: compact ? 26 : 44,
                            color: connected ? MFColors.green : MFColors.txt2,
                          ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 8 : 16),
          if (node != null)
            GestureDetector(
              onTap: () => _openNodePicker(conn),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: MFColors.card2.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: MFColors.line),
                ),
                child: Row(
                  children: [
                    CountryFlag(node.countryCode, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(conn.current == null
                              ? AppStrings.t('will_connect_node')
                              : AppStrings.t('current_node'),
                              style: TextStyle(fontSize: 10, color: MFColors.txt3)),
                          const SizedBox(height: 2),
                          Text(node.tag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    // 已固定节点：明确告知「不会自动跳」，这是用户最容易困惑的点
                    if (conn.pinnedTag != null && conn.pinnedTag == node.tag)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: MFColors.brand.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: MFColors.brand.withValues(alpha: .38)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.push_pin,
                                size: 11, color: MFColors.brandLight),
                            const SizedBox(width: 3),
                            Text(AppStrings.t('node_pinned'),
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: MFColors.brandLight,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    if (node.online && node.latencyMs >= 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: mfLatencyColor(node.latencyMs, true).withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: mfLatencyColor(node.latencyMs, true).withValues(alpha: .25)),
                        ),
                        child: SizedBox(
                          width: 46,
                          child: Text('${node.latencyMs} ms',
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: mfLatencyColor(node.latencyMs, true),
                                  fontFamily: kNumFont,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                    const SizedBox(width: 6),
                    // #2 明显的切换箭头（整行可点）
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: MFColors.brand.withValues(alpha: .22),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: MFColors.brand.withValues(alpha: .5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(AppStrings.t('node_switch'),
                              style: TextStyle(fontSize: 11.5, color: MFColors.brandLight, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 2),
                          Icon(Icons.chevron_right, size: 15, color: MFColors.brandLight),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            // 无任何节点：受限状态由顶部横幅解释（不引导去开通）；
            // 正常账号节点拉取失败 → 给「重试」而非「去开通」
            Column(
              children: [
                Text(
                  acc.isBlocked
                      ? AppStrings.t('no_nodes')
                      : (_loadingNodes
                          ? AppStrings.t('sub_updating_wait')
                          : AppStrings.t('nodes_empty_retry')),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: MFColors.txt3, height: 1.5),
                ),
                if (!acc.isBlocked && !_loadingNodes) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => _ensureNodes(force: true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                      decoration: BoxDecoration(
                          color: MFColors.brand.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: MFColors.brand.withValues(alpha: .4))),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh, size: 13, color: MFColors.brandLight),
                          const SizedBox(width: 4),
                          Text(AppStrings.t('retry_btn'),
                              style: TextStyle(fontSize: 11.5, color: MFColors.brandLight, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          // 连接期间常驻此行：已测出→国旗+国家；检测中→占位；重试用尽仍
          // 失败→「检测失败，点按重试」（可点，手动再发起一轮检测）——
          // 不再整块消失/永远停在「检测中」，用户始终知道出口状态
          if (connected) ...[
            const SizedBox(height: 8),
            // 定高一行：三个状态（已测出 / 检测中 / 检测失败可点重试）文案长度
            // 不同，旧实现高度随内容变，切换时下方内容上下跳
            SizedBox(
              height: 15,
              child: conn.realCountry != null
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CountryFlag(conn.realCountry, size: 13, rounded: true),
                        const SizedBox(width: 5),
                        Text('${AppStrings.t('real_exit')} · ${GeoLookupService.countryName(conn.realCountry)}',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: MFColors.green)),
                      ],
                    )
                  : conn.realCountryFailed
                      ? GestureDetector(
                          onTap: () => conn.refreshRealCountry(force: true),
                          child: Center(
                            child: Text(AppStrings.t('real_exit_failed_retry'),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11, color: MFColors.amber)),
                          ),
                        )
                      : Center(
                          child: Text(AppStrings.t('real_exit_detecting'),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 11, color: MFColors.txt3)),
                        ),
            ),
          ],
          // 真实错误优先（如内核启动失败），绝不被同步提示掩盖；
          // 没有错误且正在同步 → 显示「正在同步订阅…」这个**过程**，
          // 而不是让用户看到上一会话残留/或"节点还没到"的假错误。
          if (conn.error != null) ...[
            const SizedBox(height: 8),
            Text(conn.error!, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: MFColors.red, height: 1.5)),
            // 类型化失败 → 分场景引导（授权 VPN / 允许通知 / 保持前台重试）；
            // 受限状态（自动连接被账号门禁拦截）不放按钮——
            // 顶部横幅已给续费/升级/管理入口；点电源键也会弹对应说明弹窗
            if (!acc.isBlocked) ...[
              const SizedBox(height: 8),
              _buildErrorActions(conn),
            ],
          ],
          if (conn.error == null && conn.syncingSubscription) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: MFColors.brandLight),
                ),
                const SizedBox(width: 6),
                Text(AppStrings.t('sub_syncing'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: MFColors.txt3)),
              ],
            ),
          ],
          const SizedBox(height: 10),
          _buildModeSwitch(conn),
        ],
      ),
    );
  }

  /// 错误区按钮：按失败类型分场景引导
  Widget _buildErrorActions(ConnectionController conn) {
    final guide = guideForConnError(conn.errorKind);
    final actions = <Widget>[
      if (guide.foregroundHint)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(AppStrings.t('stay_foreground_hint'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, color: MFColors.amber, height: 1.5)),
        ),
    ];
    if (guide.showGrantVpn) {
      actions.add(_ErrorBtn(
          label: AppStrings.t('grant_vpn_btn'),
          onTap: () => _retryConnect(ConnErrorKind.noVpnPermission)));
    }
    if (guide.showGrantNotify) {
      actions.add(_ErrorBtn(
          label: AppStrings.t('grant_notify_btn'),
          onTap: () => _retryConnect(ConnErrorKind.noNotificationPermission)));
    }
    if (guide.showRetry) {
      actions.add(
          _ErrorBtn(label: AppStrings.t('retry_btn'), onTap: () => _retryConnect(conn.errorKind)));
    }
    if (actions.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: actions,
    );
  }

  /// 授权类失败：先引导权限（授权成功再重连）；普通失败直接重连
  Future<void> _retryConnect(ConnErrorKind kind) async {
    final conn = ConnectionController.instance;
    if (kind == ConnErrorKind.noVpnPermission ||
        kind == ConnErrorKind.noNotificationPermission) {
      final ok = await _ensurePermissionsGuided();
      if (!ok) return;
    }
    await conn.connect();
  }

  Widget _buildModeSwitch(ConnectionController conn) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: MFColors.card, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: MFColors.line)),
      child: Row(
        children: [
          _ModeOption(
            label: AppStrings.t('smart_mode'),
            icon: Icons.gps_fixed,
            selected: conn.smartMode,
            onTap: conn.switchingMode ? null : () => conn.toggleMode(true),
          ),
          _ModeOption(
            label: AppStrings.t('global_mode'),
            icon: Icons.travel_explore,
            selected: !conn.smartMode,
            onTap: conn.switchingMode ? null : () => conn.toggleMode(false),
          ),
        ],
      ),
    );
  }

  Widget _buildStats(ConnectionController conn, bool compact) {
    return ValueListenableBuilder<SpeedSnapshot>(
      valueListenable: conn.speedNotifier,
      builder: (context, snap, _) {
        // 单位迟滞需要「上次的单位」。这两个字段是**显示缓存**：随每次速率快照
        // 更新，同一次 build 立刻用到，所以直接赋值、不调 setState（不触发重建）。
        final up = formatSpeed(snap.upMbps, lastUnit: _upUnit);
        final down = formatSpeed(snap.downMbps, lastUnit: _downUnit);
        _upUnit = up.unit;
        _downUnit = down.unit;
        return Row(
          children: [
            Expanded(
              child: _StatCard(
                label: AppStrings.t('up_speed'),
                value: up.value,
                unit: up.unit,
                icon: Icons.arrow_upward_rounded,
                color: MFColors.brandLight,
                spark: conn.upHistory,
                compact: compact,
              ),
            ),
            SizedBox(width: compact ? 10 : 12),
            Expanded(
              child: _StatCard(
                label: AppStrings.t('down_speed'),
                value: down.value,
                unit: down.unit,
                icon: Icons.arrow_downward_rounded,
                color: MFColors.green,
                spark: conn.downHistory,
                compact: compact,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 速率显示单位缓存（见 [_buildStats] 与 [formatSpeed] 的迟滞说明）
  String _upUnit = 'MB/s';
  String _downUnit = 'MB/s';

  /// 快速切换国家：等宽网格（对称），点按即切该国延迟最优的在线节点。
  ///
  /// 三个决定（都来自实际反馈）：
  ///  1. **只聚合已知国家**。`countryCode` 为空 / `'XX'`（订阅里未标地区的中转
  ///     节点，例如 "JMS-1235364@c18s3..." 与 "未知 01"）不再进网格 —— 否则会
  ///     出现一个写着「XX」的药丸，而且会抢掉一个真实国家的槽位。这些节点在
  ///     节点列表 / 切换面板里照常可选。
  ///  2. **固定 3 列等宽**。旧实现是 `Wrap`：国家一多就换行到 3~4 行（380 宽下
  ///     实测 190px，把整页顶出屏幕）；后来改成单行横向滚动，高度稳了但用户
  ///     看不到后面的国家。现在是恒定网格，既不随数量长高、也不藏东西。
  ///  3. **行数随窗口高度**：默认/最小窗口（高 <820）2 行 = 自动最优 + 5 国；
  ///     窗口拉高后 3 行 = 自动最优 + 8 国。槽位不足的国家可在「切换」面板里选。
  ///     「自动最优」永远是第一格，任何窗口尺寸下都不会丢失。
  Widget _buildQuickCountries(ConnectionController conn, bool compact) {
    final byCountry = <String, ProxyNode>{};
    for (final n in conn.nodes) {
      final code = n.countryCode?.toUpperCase();
      if (code == null || code.isEmpty || code == 'XX') continue;
      if (!n.online || n.latencyMs < 0) continue;
      final cur = byCountry[code];
      if (cur == null || n.latencyMs < cur.latencyMs) byCountry[code] = n;
    }
    final entries = byCountry.entries.toList()
      ..sort((a, b) => a.value.latencyMs.compareTo(b.value.latencyMs));
    // 一个国家都没测出来时整段隐藏（保持冷启动时的高度不变）
    if (entries.isEmpty) return const SizedBox.shrink();

    const cols = 3;
    final rows = compact ? 2 : 3;
    final shown = entries.take(cols * rows - 1).toList();
    final cellH = compact ? 28.0 : 32.0;
    final rowGap = compact ? 5.0 : 6.0;
    // 第一格恒为「自动最优」，其余按延迟从低到高
    final cells = <Widget>[
      _autoBestPill(conn, 0),
      for (var i = 0; i < shown.length; i++) _countryPill(conn, shown[i], compact, i + 1),
    ];
    return Column(
      key: const ValueKey('quick_countries'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 2, bottom: compact ? 5 : 8),
          child: Text(AppStrings.t('quick_switch_country'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: MFColors.txt2)),
        ),
        for (var r = 0; r < rows; r++) ...[
          if (r > 0) SizedBox(height: rowGap),
          SizedBox(
            key: ValueKey('quick_row_$r'),
            height: cellH,
            child: Row(
              children: [
                for (var c = 0; c < cols; c++) ...[
                  if (c > 0) const SizedBox(width: 6),
                  // 等宽单元格（Expanded）＝ 视觉对称；空槽留白，保持行列整齐
                  Expanded(
                    child: r * cols + c < cells.length
                        ? cells[r * cols + c]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 「自动最优」药丸：解除「固定节点 / 锁定国家」，回到全局选优。恒占网格第一格。
  Widget _autoBestPill(ConnectionController conn, int index) {
    // 亮着 = 当前没有任何固定/锁定（全局自动选最优）
    final active = conn.lockedCountry == null && conn.pinnedTag == null;
    return GestureDetector(
      key: ValueKey('quick_pill_$index'),
      onTap: () async {
        await conn.unlockSelection();
        if (mounted) _toast(AppStrings.t('auto_best_activated'));
      },
      child: _pillShell(
        active: active,
        color: MFColors.green,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome,
                size: 13, color: active ? MFColors.green : MFColors.txt2),
            const SizedBox(width: 4),
            Flexible(
              child: Text(AppStrings.t('auto_best'),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: active ? MFColors.green : MFColors.txt)),
            ),
          ],
        ),
      ),
    );
  }

  /// 国家药丸：国旗 + 国家名 + 该国最低延迟。
  /// 点它 = **锁定国家**（只在该国范围内自动挑最优，允许换节点），
  /// 与「点节点 = 固定节点」区分开。
  Widget _countryPill(
      ConnectionController conn, MapEntry<String, ProxyNode> e, bool compact, int index) {
    // 高亮 = 当前正处于「锁定该国」状态（固定了具体节点时不高亮国家格）
    final active =
        conn.pinnedTag == null && conn.lockedCountry?.toUpperCase() == e.key;
    return GestureDetector(
      key: ValueKey('quick_pill_$index'),
      onTap: () async {
        final ok = await conn.switchCountry(e.key);
        if (!mounted) return;
        _toast(ok
            ? AppStrings.t('country_locked_toast',
                {'name': GeoLookupService.countryName(e.key)})
            : AppStrings.t('no_nodes'));
      },
      child: _pillShell(
        active: active,
        color: MFColors.brand,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CountryFlag(e.key, size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Text(GeoLookupService.countryName(e.key),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: compact ? 11.5 : 12,
                      fontWeight: FontWeight.w600,
                      color: active ? MFColors.brandLight : MFColors.txt)),
            ),
            const SizedBox(width: 4),
            Text('${e.value.latencyMs}ms',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                    fontSize: 9.5, color: MFColors.txt3, fontFamily: kNumFont)),
          ],
        ),
      ),
    );
  }

  /// 药丸外壳：铺满所在单元格（等宽），内容居中
  Widget _pillShell({required bool active, required Color color, required Widget child}) {
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: .18) : MFColors.card,
        borderRadius: _pillRadius,
        border: Border.all(color: active ? color.withValues(alpha: .7) : MFColors.line),
      ),
      child: child,
    );
  }
}

/// 节点选择底部面板（从首页「切换」进入）。
/// 测速逐节点回填会高频 notify（~10fps），每次整表重排 O(n log n) 会把低端机
/// 主线程打满，表现为面板卡死/空白。这里把「重排」节流到 300ms，其余 notify
/// 仅重绘可见项（高亮/延迟文本），既保留实时延迟又避免卡顿。
class _NodePickerSheet extends StatefulWidget {
  const _NodePickerSheet({required this.conn});
  final ConnectionController conn;

  @override
  State<_NodePickerSheet> createState() => _NodePickerSheetState();
}

class _NodePickerSheetState extends State<_NodePickerSheet> {
  List<ProxyNode> _sorted = const [];

  /// 上一轮通知时是否在测速：用于识别「测速刚结束」这一次转换
  bool _wasTesting = false;

  @override
  void initState() {
    super.initState();
    widget.conn.addListener(_onConnChanged);
    _sorted = List.of(widget.conn.nodes)..sort(_compare);
  }

  @override
  void dispose() {
    widget.conn.removeListener(_onConnChanged);
    super.dispose();
  }

  void _onConnChanged() {
    if (!mounted) return;
    final conn = widget.conn;
    final testing = conn.speedTesting;
    final wasTesting = _wasTesting;
    _wasTesting = testing;
    // 测速**进行中不重排**：逐节点回填会以 ~10fps 通知，表在测速过程中不断换位
    // （用户看到的是「列表自己来回跳」），且每次重排是 O(n log n)。
    // 现在只在「测速刚结束」或「节点列表被整体替换（订阅刷新 → 长度变化，
    // 否则表里还是旧对象）」时重排一次；其余通知只刷新高亮/延迟。
    if (conn.nodes.length != _sorted.length || (wasTesting && !testing)) {
      _resort();
    } else {
      setState(() {}); // 仅刷新高亮/延迟，不重排
    }
  }

  void _resort() {
    final sorted = List.of(widget.conn.nodes)..sort(_compare);
    if (mounted) setState(() => _sorted = sorted);
  }

  static int _compare(ProxyNode a, ProxyNode b) {
    if (a.online != b.online) return a.online ? -1 : 1;
    if (a.latencyMs < 0 && b.latencyMs < 0) return a.tag.compareTo(b.tag);
    if (a.latencyMs < 0) return 1;
    if (b.latencyMs < 0) return -1;
    return a.latencyMs.compareTo(b.latencyMs);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final conn = widget.conn;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (_, scroll) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: MFColors.line2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Row(
              children: [
                Text(AppStrings.t('nodes_title'),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(width: 10),
                Text(AppStrings.t('tap_switch_node'),
                    style: TextStyle(fontSize: 11, color: MFColors.txt3)),
                const Spacer(),
                // ⚡实时测速：手动挑节点时不切走（switchToBest:false），
                // 仅逐个填延迟并重排，最优浮到最上。
                // 内核测速失败（未连接且内核拉不起来）必须说出来 ——
                // 旧实现直接丢弃结果，用户点了没反应却不知道原因。
                GestureDetector(
                  onTap: conn.speedTesting
                      ? null
                      : () async {
                          await conn.retestAll(
                              switchToBest: false, userInitiated: true);
                          if (!mounted) return;
                          final err = conn.speedTestError;
                          if (err != null && err.isNotEmpty) {
                            _toast(AppStrings.t(
                                'speed_mode_probe_failed', {'err': err}));
                          }
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: MFColors.brandGradient,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: conn.speedTesting
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text('⚡ ${AppStrings.t('speed_test')}',
                            style: const TextStyle(
                                fontSize: 11.5,
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              itemCount: _sorted.length,
              itemBuilder: (_, i) {
                final n = _sorted[i];
                final isCurrent = conn.current?.tag == n.tag;
                final latencyColor = mfLatencyColor(n.latencyMs, n.online);
                return GestureDetector(
                  onTap: () async {
                    Navigator.pop(context);
                    await conn.switchNode(n);
                    _toast(AppStrings.t('pin_toast', {'name': n.tag}));
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                    decoration: BoxDecoration(
                      color: isCurrent ? MFColors.brand.withValues(alpha: .09) : MFColors.card2,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isCurrent ? MFColors.brand.withValues(alpha: .55) : MFColors.line,
                      ),
                    ),
                    child: Row(
                      children: [
                        CountryFlag(n.countryCode, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(n.tag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                        ),
                        Text(
                          n.online && n.latencyMs >= 0 ? '${n.latencyMs} ms' : '—',
                          style: TextStyle(
                            fontSize: 12,
                            color: latencyColor,
                            fontFamily: kNumFont,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (conn.pinnedTag == n.tag) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.push_pin, size: 14, color: MFColors.brandLight),
                        ],
                        if (isCurrent) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.check_circle, size: 16, color: MFColors.brandLight),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBtn extends StatelessWidget {
  const _ErrorBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
            gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(10)),
        child: Text(label,
            style: const TextStyle(
                fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption(
      {required this.label,
      required this.icon,
      required this.selected,
      this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 38,
          decoration: BoxDecoration(
            gradient: selected ? MFColors.brandGradient : null,
            borderRadius: BorderRadius.circular(11),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: MFColors.brand.withValues(alpha: .4),
                        blurRadius: 16)
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 15,
                  color: selected
                      ? Colors.white
                      : (enabled ? MFColors.txt2 : MFColors.txt3)),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? Colors.white
                          : (enabled ? MFColors.txt2 : MFColors.txt3))),
              if (!enabled) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: selected ? Colors.white70 : MFColors.txt3),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    required this.icon,
    this.spark,
    this.compact = false,
  });
  final String label;
  final String value;
  final String unit;
  final Color color;
  final IconData icon;
  /// 矮窗口（桌面默认 780 / 最小 620）：卡片整体再压一档，给「快速切换国家」
  /// 的两行网格腾高度，保证主页一屏放得下
  final bool compact;
  /// 迷你趋势(最近 ~60s 速率 MB/s;null 不显示)
  final List<double>? spark;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 桌面窗口高度有限（默认 780、最小 620）：卡片整体压矮，让主页一屏放得下
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 14, vertical: compact ? 7 : 9),
      decoration: BoxDecoration(
        color: MFColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MFColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: compact ? 15 : 16, color: color),
              const SizedBox(width: 6),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: compact ? 11.5 : 12,
                      color: MFColors.txt2,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          SizedBox(height: compact ? 4 : 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // 数值定宽 + 右对齐：位数变化（0.0 / 51 / 1234）与单位切换都不再
              // 推动右侧内容 —— 旧实现里 unit 是这个 Text 的兄弟节点，数值一变宽
              // 单位就左右平移（每秒一次，就是用户看到的「卡片来回跳」）。
              // 宽度按最大现实值取：MB/s 下 4 位整数 + 小数（~78px）。
              SizedBox(
                width: compact ? 76 : 88,
                child: Text(value,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                        fontSize: compact ? 20 : 22,
                        fontWeight: FontWeight.w700,
                        color: color,
                        fontFamily: kNumFont,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        height: 1)),
              ),
              const SizedBox(width: 6),
              // 单位也定宽左对齐：KB/s 与 MB/s 等长，但仍占固定槽位，彻底不受影响
              SizedBox(
                width: compact ? 38 : 42,
                child: Text(unit,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                        fontSize: compact ? 12 : 13,
                        color: MFColors.txt3,
                        fontWeight: FontWeight.w500)),
              ),
            ],
          ),
          // 趋势线**始终占位**：旧实现按 `spark.length >= 2` 决定是否渲染，
          // 连上约 2 秒后卡片突然长高 36px、断开清空 history 又缩回去 ——
          // 下方所有卡片跟着上下位移。现在恒定占位，样本不足时画一条基线。
          if (spark != null) ...[
            SizedBox(height: compact ? 4 : 6),
            SizedBox(
                height: compact ? 12 : 16,
                width: double.infinity,
                child: _Sparkline(values: spark!, color: color)),
          ],
        ],
      ),
    );
  }
}

/// 速率显示（数值 + 单位）。
///
/// 为什么需要迟滞（hysteresis）：单位切换的分界点是 0.1 MB/s，而空闲时保活
/// 流量/心跳会让速率在 0 附近抖动 —— 没有迟滞时单位每秒在 `KB/s` 与 `MB/s`
/// 之间翻转，加上数值位数变化（`0.0` ↔ `51` ↔ `1234`），视觉上就是「卡片里的
/// 数字来回跳」。迟滞把「切到 KB/s」和「切回 MB/s」的门槛分开，抖动不再翻转。
///
/// [lastUnit] 上次显示的单位（首次传 null）。完全空闲（<=0）时**沿用**上次
/// 单位，避免刚归零就换单位。
({String value, String unit}) formatSpeed(double mbps, {String? lastUnit}) {
  const kb = 'KB/s';
  const mb = 'MB/s';
  if (mbps <= 0) return (value: '0.0', unit: lastUnit ?? mb);
  final useKb = lastUnit == kb ? mbps < 0.15 : mbps < 0.08;
  if (!useKb) return (value: mbps.toStringAsFixed(1), unit: mb);
  return (value: (mbps * 1024).toStringAsFixed(0), unit: kb);
}

/// 迷你趋势折线(无新依赖,纯 CustomPaint):平滑一条随时间变化的速率曲线
class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _SparkPainter(values: values, color: color),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    // 样本不足（刚连接、断开后清空）也画一条基线：占位高度恒定，卡片不再
    // 因为「趋势线有没有」而长高/缩回，避免下方内容上下跳。
    if (values.length < 2) {
      canvas.drawLine(
        Offset(0, size.height - 0.7),
        Offset(size.width, size.height - 0.7),
        Paint()
          ..strokeWidth = 1.4
          ..color = color.withValues(alpha: .35),
      );
      return;
    }
    var maxV = 0.0;
    for (final v in values) {
      if (v > maxV) maxV = v;
    }
    if (maxV <= 0) maxV = 0.1; // 全零也有基线
    final path = Path();
    final n = values.length;
    for (var i = 0; i < n; i++) {
      final x = size.width * i / (n - 1);
      final y = size.height - (values[i] / maxV).clamp(0.0, 1.0) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawPath(path, stroke);
    // 浅色填充(0→曲线→底部)
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: .10));
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color;
}




/// #3 顶部信息条单元格（窄屏自动收缩，不溢出）
class _InfoCell extends StatelessWidget {
  const _InfoCell({required this.label, required this.value, this.flex = 1, this.highlight = false});
  final String label;
  final String value;
  final int flex;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: highlight ? MFColors.green : MFColors.txt,
                fontFamily: kNumFont,
              )),
          const SizedBox(height: 3),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: MFColors.txt2)),
        ],
      ),
    );
  }
}

/// 已连接会话信息(时长 + 本次上下行累计)：独立 1s 自刷新,
/// 不触发整页/整卡重建(连接卡其它内容保持静态)
class _SessionInfo extends StatefulWidget {
  const _SessionInfo({required this.conn});
  final ConnectionController conn;

  @override
  State<_SessionInfo> createState() => _SessionInfoState();
}

class _SessionInfoState extends State<_SessionInfo> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  static String _fmtMB(double mb) {
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final conn = widget.conn;
    if (conn.status != ConnStatus.connected || conn.connectedAt == null) {
      // 固定高度占位：连接/断开切换时卡片高度不变，下方内容不上下跳
      return const SizedBox(height: 15);
    }
    // 整行用**固定宽度槽位**拼装（不用单个居中 Text）：时长是定宽的 HH:MM:SS，
    // 但 ↑/↓ 的累计值每秒都在变宽（1.2 MB → 12.3 MB → 1.02 GB），旧实现是一行
    // 居中的 Text → 宽度每秒变一次、整行重新居中，看起来就是卡片内容左右抖。
    final numStyle = TextStyle(
        fontSize: 10.5,
        color: MFColors.txt3,
        fontFamily: kNumFont,
        fontFeatures: const [FontFeature.tabularFigures()]);
    return SizedBox(
      height: 15,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('${AppStrings.t('connected_for')} ${conn.sessionUptime}',
              maxLines: 1, softWrap: false, style: numStyle),
          const SizedBox(width: 6),
          Text('↑', style: numStyle),
          const SizedBox(width: 3),
          SizedBox(
              width: 62,
              child: Text(_fmtMB(conn.sessionUpMB),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: numStyle)),
          const SizedBox(width: 8),
          Text('↓', style: numStyle),
          const SizedBox(width: 3),
          SizedBox(
              width: 62,
              child: Text(_fmtMB(conn.sessionDownMB),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: numStyle)),
        ],
      ),
    );
  }
}
