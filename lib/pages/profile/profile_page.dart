import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/account_service.dart';
import '../../core/services/subscription_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/update_service.dart';
import '../../core/services/user_service.dart';
import '../../widgets/update_prompt.dart';
import '../../main.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../devices/devices_page.dart';
import '../notifications/notifications_page.dart';
import '../orders/orders_page.dart';
import '../settings/settings_page.dart';

/// 我的页：真实仪表盘数据（UserService 会话内缓存，进入不重复刷新）+ 各功能入口
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  DashboardInfo? get _dashboard => UserService.instance.cachedDashboard;

  /// 后台刷新中（**不阻塞页面渲染**：只在数据区顶部显示一条细提示）。
  ///
  /// 旧实现用 `_loading` 把整页替换成大转圈 —— 于是「我的」页每次进来都要等
  /// 数据回来才长出内容（设置/订单/客服/退出登录这些**固定项**也被一起挡住）。
  /// 用户看到的就��「位置会跳、要等一下、刷新才出来」。
  bool _refreshing = false;
  bool _loadFailed = false; // 上次加载失败(数据区给重试,避免全零误读)

  /// 最近一次**成功**拉取数据的时间：切回本页只有超过 TTL 才自动刷新。
  /// 为什么要 TTL：这个页面 90% 是固定布局，只有到期/设备/账号几个数字会变；
  /// 每次切 tab 都强制走一次网络只会让页面"等一下才出来"。
  DateTime? _lastLoadAt;
  static const _autoRefreshTtl = Duration(seconds: 60);
  /// 上次失败的分类：登录态失效（401）与真正的网络异常要给出**不同**的出路。
  /// 旧实现一律提示"账户信息加载失败"，用户只能反复点重试（对过期令牌永远无效）。
  SubscribeIssue? _failIssue;

  /// 「我的」页在主 Tab 里的下标（见 main.dart 的 _pages）。
  /// 页面被 IndexedStack 保活，切回来不会重跑 initState，
  /// 因此靠监听 tab 下标在**每次进入本页**时刷新数据。
  static const int _profileTabIndex = 3;

  @override
  void initState() {
    super.initState();
    _initLoad();
    mainTabIndex.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    mainTabIndex.removeListener(_onTabChanged);
    super.dispose();
  }

  /// 切回本页时重新拉取（设备增删、后台改设备数后立刻见效，
  /// 不再出现「首页已刷新、我的还是旧数字」）
  void _onTabChanged() {
    if (mainTabIndex.value != _profileTabIndex || !mounted) return;
    // 进来就先用「内存 → 磁盘」缓存直接上屏（setState 只补数字，不动布局），
    // 只有超过 TTL / 还没有任何数据时才在后台刷新。
    final at = _lastLoadAt;
    final stale = at == null || DateTime.now().difference(at) > _autoRefreshTtl;
    if (_dashboard == null || stale) {
      unawaited(_load(force: false));
    }
  }

  /// 冷启动：先展示磁盘缓存（不转圈、不等网络），再后台静默刷新。
  Future<void> _initLoad() async {
    if (_dashboard == null) {
      final disk = await UserService.instance.loadCachedDashboard();
      if (!mounted) return;
      if (disk != null) {
        UserService.instance.adoptCachedDashboard(disk);
        _lastLoadAt = DateTime.now(); // 磁盘数据也算"有数据"，TTL 从这里起算
        setState(() {});
      }
    }
    // 首次进入：后台刷新（不 await 阻塞渲染）
    unawaited(_load(force: true));
  }

  /// 拉数据。[force] = false 时走 内存→磁盘→网络 的逐级命中（切 tab / 冷启动用），
  /// true = 强制走网络（下拉刷新、错误重试用）。
  ///
  /// **无论成败都不会把页面清空**：失败只在数据区顶部挂一条可重试的提示，
  /// 固定项（设置/订单/客服/退出登录）始终可点。
  Future<void> _load({bool force = false}) async {
    if (_refreshing) return;
    final hadCache = _dashboard != null;
    if (mounted) {
      setState(() {
        _refreshing = true;
        if (!hadCache) _loadFailed = false;
      });
    }
    try {
      await UserService.instance.dashboard(force: force);
      _lastLoadAt = DateTime.now();
      if (mounted) {
        setState(() {
          _loadFailed = false;
          _failIssue = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (!hadCache) {
        // 无数据显示失败提示（带重试 / 重新登录的**正确出路**）
        setState(() {
          _loadFailed = true;
          _failIssue = SubscriptionService.classifyFromError(ApiClient.errorMsg(e));
        });
        _toast(ApiClient.errorMsg(e));
      }
      // 已有缓存时静默失败：保留旧数据继续浏览，不打断用户
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
    // 与首页**同源**刷新设备数字：首页的「设备数」读 AccountService 的订阅信息
    // （/user/subscribe），本页此前只刷 dashboard（/users/dashboard-info）。
    // 两个接口刷新时机不同，设备增删后同一个客户就会出现「首页 7 台、我的 6 台」。
    // 单独 try：订阅信息拉取失败不影响本页展示（设备数字退回 dashboard 字段）。
    try {
      await AccountService.instance.refresh(force: force);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// 重新登录：清会话/缓存后回到登录页（与订阅提示里的"重新登录"同一套行为）
  Future<void> _relogin() async {
    try {
      await AuthService.instance.logout();
      UserService.instance.invalidateCache();
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      context.read<SessionState>().setLoggedIn(false);
    } catch (e) {
      debugPrint('relogin failed: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final dash = _dashboard;
    final hasData = dash != null;
    final name = dash?.username ?? '—';
    final email = dash?.email ?? '';
    final balance = dash?.balance ?? 0;
    final remaining = dash?.remainingDays ?? 0;
    final expire = (dash?.expireTime ?? '').toString().isEmpty
        ? (hasData ? AppStrings.t('expire_na') : '—')
        : dash!.expireTime.toString();
    // 设备「已用/上限」与首页**同一来源**（AccountService 的 /user/subscribe），
    // 保证两页永远显示同一组数字；订阅信息尚未就绪时才退回 dashboard 的字段。
    final subInfo = AccountService.instance.sub;
    final online = subInfo?.currentDevices ?? dash?.onlineDevices ?? 0;
    final total = subInfo?.deviceLimit ?? dash?.totalDevices ?? 0;
    final hasSub = dash?.hasSubscription == true;
    // 到期展示取日期部分
    final expireShort = expire.length > 10 ? expire.substring(0, 10) : expire;

    // 关键：**布局固定、立即上屏**。数据（到期/设备/账号）只是卡片里的值，
    // 没到之前显示「—」，不再用大转圈把整页（含设置/订单/客服/退出登录）挡住。
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          // 下拉 = 强制刷新（唯一会等网络的地方，且是用户主动要的）
          onRefresh: () => _load(force: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
            children: [
              _buildHeader(name, email, balance, hasData: hasData),
              const SizedBox(height: 16),
              // 后台刷新中：一条细提示，不改变布局、不阻塞点击
              if (_refreshing && hasData) _buildRefreshingHint(),
              // 真的没有数据且失败了：顶部挂一条可重试的提示（不替换整页）
              if (_loadFailed && !hasData) _buildInlineError(),
              if (hasData) ..._buildStatusBanners(dash),
              // 浅色玻璃信息卡（固定位置；值未知时显示「—」）
              _buildInfoCard(hasSub, remaining, expireShort, online, total,
                  hasData: hasData),
              const SizedBox(height: 18),
              // 固定入口（设置/订单/设备/通知/检查更新）—— 永远可点
              _buildMenu(context, online, total, hasData: hasData),
              const SizedBox(height: 18),
              _buildLogout(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 后台刷新中的细提示（替代原来的整页转圈）
  Widget _buildRefreshingHint() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
                strokeWidth: 1.6, color: MFColors.brand),
          ),
          const SizedBox(width: 7),
          Text(AppStrings.t('refreshing'),
              style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
        ],
      ),
    );
  }

  /// 加载失败提示（内联在数据区，带重试 / 重新登录的正确出路）
  Widget _buildInlineError() {
    final authIssue = _failIssue == SubscribeIssue.authRequired;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: MFColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MFColors.amber.withValues(alpha: .45)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: MFColors.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    authIssue
                        ? AppStrings.t('issue_auth_title')
                        : AppStrings.t('profile_load_fail'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: MFColors.txt)),
                const SizedBox(height: 2),
                Text(
                    authIssue
                        ? AppStrings.t('issue_auth_body')
                        : AppStrings.t('profile_load_fail_hint'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: authIssue ? _relogin : () => _load(force: true),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                constraints: const BoxConstraints(minHeight: 36),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    gradient: MFColors.brandGradient,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(
                    authIssue
                        ? AppStrings.t('profile_relogin')
                        : AppStrings.t('retry'),
                    style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(String name, String email, double balance,
      {required bool hasData}) {
    return Row(
      children: [
        Container(
          width: 50, height: 50,
          decoration: BoxDecoration(
              color: MFColors.isDark ? Colors.black : MFColors.card2,
              border: Border.all(color: MFColors.line),
              borderRadius: BorderRadius.circular(15)),
          child: Icon(Icons.flight_takeoff, color: MFColors.brand, size: 26),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(email.isEmpty ? AppStrings.t('no_email_hint') : email,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: MFColors.txt3)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 金额口径与套餐页/支付弹窗统一走 formatPrice()：200 显示「¥200」
            // 而不是「¥200.00」，0.02 也不会被凑整成 0。
            Text(hasData ? '¥${formatPrice(balance)}' : '—',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: MFColors.brandLight, fontFamily: kNumFont)),
            Text(AppStrings.t('balance'), style: TextStyle(fontSize: 9.5, color: MFColors.txt3)),
          ],
        ),
      ],
    );
  }

  /// 到期提醒（剩余 < 7 天）→ 一键续费
  Widget _buildExpiringBanner(int remaining) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0x33FFB020), Color(0x0DFFB020)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MFColors.amber.withValues(alpha: .45)),
      ),
      child: Row(
        children: [
          const Text('⏰', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(AppStrings.t('expiring_days', {'days': '$remaining'}),
                style: TextStyle(fontSize: 12, color: MFColors.txt)),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => mainTabIndex.value = 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                constraints: const BoxConstraints(minHeight: 40),
                alignment: Alignment.center,
                decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(10)),
                child: Text(AppStrings.t('renew'), style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 账号状态横幅列表：
  /// 账号禁用（无购买按钮）> 套餐停用 > 套餐到期（去续费）> 设备满（管理/升级）
  /// > 到期倒计时提醒（0<剩余<7）。正常账号不出现任何购买类横幅。
  List<Widget> _buildStatusBanners(DashboardInfo dash) {
    final banners = <Widget>[];
    final status = dash.subscriptionStatus;
    final hasSub = dash.hasSubscription;
    final remaining = dash.remainingDays;
    final online = dash.onlineDevices;
    final total = dash.totalDevices;
    final isExpired = hasSub && remaining <= 0;
    final deviceFull = hasSub && total > 0 && online >= total;

    if (!dash.isActive) {
      banners.add(_buildNoticeBanner(
        emoji: '🚫',
        text: AppStrings.t('account_disabled_block'),
        color: MFColors.red,
      ));
    } else if (status.isNotEmpty && status != 'active') {
      banners.add(_buildNoticeBanner(
        emoji: '🚫',
        text: AppStrings.t('sub_disabled_block'),
        color: MFColors.red,
      ));
    } else if (isExpired) {
      banners.add(_buildNoticeBanner(
        emoji: '⏰',
        text: AppStrings.t('account_expired_block'),
        color: MFColors.red,
        buttonLabel: AppStrings.t('go_renew'),
        onTap: () => mainTabIndex.value = 2,
      ));
    } else if (deviceFull) {
      banners.add(_buildNoticeBanner(
        emoji: '📱',
        text: AppStrings.t('devices_full_hint', {'cur': '$online', 'limit': '$total'}),
        color: MFColors.amber,
        buttonLabel: AppStrings.t('manage_devices'),
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DevicesPage())),
      ));
    } else if (hasSub && remaining > 0 && remaining < 7) {
      banners.add(_buildExpiringBanner(remaining));
    }
    if (banners.isEmpty) return const [];
    return [
      for (var i = 0; i < banners.length; i++) ...[
        banners[i],
        const SizedBox(height: 12),
      ]
    ];
  }

  /// 通用提示横幅（emoji + 文案 + 可选按钮）
  Widget _buildNoticeBanner({
    required String emoji,
    required String text,
    required Color color,
    String? buttonLabel,
    VoidCallback? onTap,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        gradient: LinearGradient(
            colors: [color.withValues(alpha: .2), color.withValues(alpha: .05)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, color: MFColors.txt, height: 1.5)),
          ),
          if (buttonLabel != null && onTap != null) ...[
            const SizedBox(width: 6),
            Material(
              color: Colors.transparent,
              child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                constraints: const BoxConstraints(minHeight: 40),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    gradient: MFColors.brandGradient,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(buttonLabel,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
              ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// #7 浅色信息卡：到期 / 设备 / 剩余天数 三格（柔光底色 + 清晰深色文字）
  Widget _buildInfoCard(bool hasSub, int remaining, String expire, int online,
      int total, {required bool hasData}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 15, 6, 14),
      decoration: BoxDecoration(
        // 品牌光晕必须随外观模式走：写死浅色模式的品牌蓝时，
        // 在 warm/gray/darkblue/black 等模式下卡片还是蓝色，和边框/文字的品牌色
        // 对不上（外观切换是设置里的主打功能，切过去卡片不跟着变很显眼）。
        gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [
              MFColors.brand.withValues(alpha: .18),
              MFColors.brand.withValues(alpha: .07),
            ]),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MFColors.brand.withValues(alpha: .38)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Text(!hasData
                    ? AppStrings.t('member')
                    : hasSub
                        ? ((_dashboard?.membership ?? '').isNotEmpty
                            ? _dashboard!.membership
                            : AppStrings.t('member'))
                        : AppStrings.t('no_plan_yet'),
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: MFColors.txt)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: (!hasData
                            ? MFColors.txt3
                            : hasSub
                                ? MFColors.green
                                : MFColors.amber)
                        .withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: (!hasData
                                ? MFColors.txt3
                                : hasSub
                                    ? MFColors.green
                                    : MFColors.amber)
                            .withValues(alpha: .35)),
                  ),
                  child: Text(!hasData
                          ? '● …'
                          : hasSub
                              ? '● ${AppStrings.t('active')}'
                              : '● ${AppStrings.t('inactive')}',
                      style: TextStyle(
                          fontSize: 10,
                          color: !hasData
                              ? MFColors.txt3
                              : hasSub
                                  ? MFColors.green
                                  : MFColors.amber,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              _SubItem(value: hasData ? '$remaining' : '—', unit: hasData ? AppStrings.t('days') : '', label: AppStrings.t('remaining_days'), highlight: true),
              _SubItem(value: expire, label: AppStrings.t('expire_time')),
              _SubItem(value: hasData ? '$online/$total' : '—', label: AppStrings.t('plan_devices')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMenu(BuildContext context, int online, int total,
      {required bool hasData}) {
    // 「检查更新」放在这里（原先设置页里那份已移除）：与版本号同处，且有新版时
    // 直接显示红点，不需要用户在「我的 → 关于」与「设置 → 检查更新」之间二选一。
    return ValueListenableBuilder<bool>(
      valueListenable: UpdateService.hasUpdate,
      builder: (context, hasUpdate, _) {
        final rows = <(String, String, String?, bool, VoidCallback)>[
          ('📱', AppStrings.t('profile_devices'), hasData ? '$online/$total' : null, false, () => _push(context, const DevicesPage())),
          ('🧾', AppStrings.t('profile_orders'), null, false, () => _push(context, const OrdersPage())),
          ('🔔', AppStrings.t('profile_notifications'), null, false, () => _push(context, const NotificationsPage())),
          ('⚙️', AppStrings.t('settings'), null, false, () => _push(context, const SettingsPage())),
          ('🔄', AppStrings.t('settings_check_update'), 'v${UpdateInfo.currentVersion}', hasUpdate,
              () => UpdatePrompt.checkManually(context)),
        ];
        return Column(
      children: [
        for (final (icon, title, badge, showDot, onTap) in rows)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            decoration: BoxDecoration(
                color: MFColors.card, borderRadius: BorderRadius.circular(15),
                border: Border.all(color: MFColors.line)),
            child: InkWell(
              borderRadius: BorderRadius.circular(15),
              onTap: onTap,
              child: Row(
                children: [
                  Text(icon, style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: MFColors.txt))),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: MFColors.card2, borderRadius: BorderRadius.circular(12)),
                      child: Text(badge, style: TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
                    ),
                  if (showDot) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                          color: MFColors.red, shape: BoxShape.circle),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 18, color: MFColors.txt3),
                ],
              ),
            ),
          ),
        ],
      );
      },
    );
  }

  Widget _buildLogout(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: MFColors.card2,
            title: Text(AppStrings.t('logout'), style: TextStyle(fontSize: 16)),
            content: Text(AppStrings.t('logout_confirm'), style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.t('cancel'))),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppStrings.t('logout_yes'), style: TextStyle(color: MFColors.red)),
              ),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          await AuthService.instance.logout();
          UserService.instance.invalidateCache();
          if (!context.mounted) return;
          // 确保回到根部路由，登录窗口不被残留页面盖住
          Navigator.of(context).popUntil((r) => r.isFirst);
          if (context.mounted) context.read<SessionState>().setLoggedIn(false);
        }
      },
      child: Container(
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: MFColors.red.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: MFColors.red.withValues(alpha: .35)),
        ),
        child: Text(AppStrings.t('logout'), style: TextStyle(fontSize: 14.5, color: MFColors.red, fontWeight: FontWeight.w600)),
      ),
      ),
    );
  }

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));


}

class _SubItem extends StatelessWidget {
  const _SubItem({required this.value, required this.label, this.unit, this.highlight = false});
  final String value;
  final String? unit;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: highlight ? 18 : 14.5,
                      fontWeight: FontWeight.w800,
                      color: highlight ? MFColors.green : MFColors.txt,
                      fontFamily: kNumFont)),
              if (unit != null) ...[
                const SizedBox(width: 2),
                Text(unit!, style: TextStyle(fontSize: 10, color: MFColors.txt2)),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: MFColors.txt2)),
        ],
      ),
    );
  }
}
