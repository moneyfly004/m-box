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
  bool _loading = false;
  bool _loadFailed = false; // 上次加载失败(数据区给重试,避免全零误读)
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
    if (mainTabIndex.value == _profileTabIndex && mounted) {
      unawaited(_load());
    }
  }

  /// 冷启动：先展示磁盘缓存（不再转圈），再后台静默刷新；无缓存才走网络 loading。
  Future<void> _initLoad() async {
    if (_dashboard == null) {
      final disk = await UserService.instance.loadCachedDashboard();
      if (!mounted) return;
      if (disk != null) {
        UserService.instance.adoptCachedDashboard(disk);
        setState(() {});
      }
    }
    await _load();
  }

  Future<void> _load() async {
    final hadCache = _dashboard != null;
    if (!hadCache) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    try {
      await UserService.instance.dashboard(force: true);
      if (mounted) {
        setState(() {
          _loadFailed = false;
          _failIssue = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (!hadCache) {
        // 无缓存且失败：给「错误+重试」占位，并按原因给出**正确出路**
        setState(() {
          _loadFailed = true;
          _failIssue = SubscriptionService.classifyFromError(ApiClient.errorMsg(e));
        });
        _toast(ApiClient.errorMsg(e));
      }
      // 已有缓存时静默失败：保留旧数据继续浏览，不打断用户
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    // 与首页**同源**刷新设备数字：首页的「设备数」读 AccountService 的订阅信息
    // （/user/subscribe），本页此前只刷 dashboard（/users/dashboard-info）。
    // 两个接口刷新时机不同，设备增删后同一个客户就会出现「首页 7 台、我的 6 台」。
    // 单独 try：订阅信息拉取失败不影响本页展示（设备数字退回 dashboard 字段）。
    try {
      await AccountService.instance.refresh(force: true);
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
    final name = dash?.username ?? '—';
    final email = dash?.email ?? '';
    final balance = dash?.balance ?? 0;
    final remaining = dash?.remainingDays ?? 0;
    final expire = (dash?.expireTime ?? '').toString().isEmpty
        ? AppStrings.t('expire_na')
        : dash!.expireTime.toString();
    // 设备「已用/上限」与首页**同一来源**（AccountService 的 /user/subscribe），
    // 保证两页永远显示同一组数字；订阅信息尚未就绪时才退回 dashboard 的字段。
    final subInfo = AccountService.instance.sub;
    final online = subInfo?.currentDevices ?? dash?.onlineDevices ?? 0;
    final total = subInfo?.deviceLimit ?? dash?.totalDevices ?? 0;
    final hasSub = dash?.hasSubscription == true;
    // 到期展示取日期部分
    final expireShort = expire.length > 10 ? expire.substring(0, 10) : expire;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
            children: [
              _buildHeader(name, email, balance),
              const SizedBox(height: 16),
              if (_loading && _dashboard == null)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator(color: MFColors.brand)),
                )
              else if (_loadFailed && _dashboard == null)
                // 加载失败:给"错误+重试"占位,避免全零/占位误读为无套餐。
                // 这一段本身在 ListView 里（可滚动、不会 RenderFlex overflow）；
                // 文案仍然限行 + 省略号，防止超长本地化/服务端文案把卡片撑变形。
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Column(
                    children: [
                      Icon(Icons.cloud_off_outlined, size: 40, color: MFColors.txt3),
                      const SizedBox(height: 10),
                      Text(
                          _failIssue == SubscribeIssue.authRequired
                              ? AppStrings.t('issue_auth_title')
                              : AppStrings.t('profile_load_fail'),
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: MFColors.txt2)),
                      if (_failIssue == SubscribeIssue.authRequired)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(AppStrings.t('issue_auth_body'),
                              textAlign: TextAlign.center,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: MFColors.txt3)),
                        ),
                      const SizedBox(height: 14),
                      // 审计 P2：小控件一律 InkWell（有按压反馈）+ 命中区够大
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _failIssue == SubscribeIssue.authRequired
                            ? _relogin
                            : _load,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                          constraints: const BoxConstraints(minHeight: 44),
                          decoration: BoxDecoration(
                              gradient: MFColors.brandGradient,
                              borderRadius: BorderRadius.circular(12)),
                          child: Text(
                              _failIssue == SubscribeIssue.authRequired
                                  ? AppStrings.t('profile_relogin')
                                  : AppStrings.t('retry'),
                              style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                // 账号状态横幅（禁用 > 套餐停用 > 到期 > 设备满），
                // 之后才是「剩余 < 7 天」的普通续费提醒
                if (_dashboard != null) ..._buildStatusBanners(_dashboard!),
                // #7 浅色玻璃信息卡（不再深色看不清）
                _buildInfoCard(hasSub, remaining, expireShort, online, total),
                const SizedBox(height: 18),
                _buildMenu(context, online, total),
                const SizedBox(height: 18),
                _buildLogout(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(String name, String email, double balance) {
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
            Text('¥${formatPrice(balance)}',
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
  Widget _buildInfoCard(bool hasSub, int remaining, String expire, int online, int total) {
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
                Text(hasSub
                    ? ((_dashboard?.membership ?? '').isNotEmpty
                        ? _dashboard!.membership
                        : AppStrings.t('member'))
                    : AppStrings.t('no_plan_yet'),
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: MFColors.txt)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: (hasSub ? MFColors.green : MFColors.amber).withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: (hasSub ? MFColors.green : MFColors.amber).withValues(alpha: .35)),
                  ),
                  child: Text(hasSub ? '● ${AppStrings.t('active')}' : '● ${AppStrings.t('inactive')}',
                      style: TextStyle(fontSize: 10, color: hasSub ? MFColors.green : MFColors.amber, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              _SubItem(value: '$remaining', unit: AppStrings.t('days'), label: AppStrings.t('remaining_days'), highlight: true),
              _SubItem(value: expire, label: AppStrings.t('expire_time')),
              _SubItem(value: '$online/$total', label: AppStrings.t('plan_devices')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMenu(BuildContext context, int online, int total) {
    // 「检查更新」放在这里（原先设置页里那份已移除）：与版本号同处，且有新版时
    // 直接显示红点，不需要用户在「我的 → 关于」与「设置 → 检查更新」之间二选一。
    return ValueListenableBuilder<bool>(
      valueListenable: UpdateService.hasUpdate,
      builder: (context, hasUpdate, _) {
        final rows = <(String, String, String?, bool, VoidCallback)>[
          ('📱', AppStrings.t('profile_devices'), '$online/$total', false, () => _push(context, const DevicesPage())),
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
