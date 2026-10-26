import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/server_pool.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/services/account_service.dart';
import '../../core/services/app_log.dart';
import '../../core/services/autostart.dart';
import '../../core/services/crash_logger.dart';
import '../../core/services/settings_store.dart';
import '../../core/services/speed_test_mode.dart';
import '../../core/services/subscription_service.dart';
import '../../core/services/update_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/mf_input.dart';
import '../../widgets/mf_row.dart';
import '../auth/change_password_page.dart';
import '../devices/devices_page.dart';
import 'access_page.dart';
import 'bypass_page.dart';
import 'geo_update_page.dart';
import 'kernel_page.dart';
import 'log_center_page.dart';

/// 主 DNS 列表默认值（阿里 223.5.5.5 + 腾讯 119.29.29.29，国内可达）
const _defaultDnsServers = ['223.5.5.5', '119.29.29.29'];

/// 设置页（设计稿 09）：完整清单 + 持久化
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic> _s = {};
  bool _loaded = false;

  /// 设置项搜索关键词（小写，空 = 不过滤）。
  /// 用户反馈「设置里面东西很乱、同类功能不集中」——除了按用户意图重新分组，
  /// 再加一个搜索框：知道名字就能一步定位，不用逐组翻。
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }


  @override
  void initState() {
    super.initState();
    SettingsStore.instance.load().then((v) {
      if (mounted) {
        setState(() {
          _s = v;
          _loaded = true;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  Future<void> _set(String key, dynamic value) async {
    setState(() => _s[key] = value);
    // 连接相关设置即时生效到连接控制器（自动测速/断线重连/默认模式）
    ConnectionController.instance.applySettings(_s);
    // 基于最新值只改这一键再保存(update 单写队列),避免整份旧快照回写
    // 覆盖其它模块(如 lastSelectedTag/kernelVariant)刚写入的值
    await SettingsStore.instance.update((s) => s[key] = value);
  }

@override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(body: Center(child: CircularProgressIndicator(color: MFColors.brand)));
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('settings_title')),
        actions: [
          TextButton(
            onPressed: () async {
              await SettingsStore.instance.reset();
              final defaults = await SettingsStore.instance.load();
              if (!mounted) return;
              setState(() => _s = defaults);
              // 默认值同步生效到连接控制器与主题
              ConnectionController.instance.applySettings(defaults);
              ThemeController.instance.setAppearance(defaults['appearance']?.toString() ?? 'light');
              _toast(AppStrings.t('restored'));
            },
            child: Text(AppStrings.t('restore_default'), style: TextStyle(fontSize: 12.5, color: MFColors.txt3)),
          ),
        ],
      ),
      body: SafeArea(
        child: Builder(builder: (_) {
          // 分组按**用户意图**（不是代码归属）排列；搜索时整组/整行动态过滤。
          final groups = <List<Widget>>[
            _groupConnect(), // ① 连接与内核
            _groupSpeedTest(), // ② 测速
            _groupDnsSplit(), // ③ DNS 与分流
            _groupSubscription(), // ④ 订阅与更新
            _groupAccount(), // ⑤ 账号与安全
            _groupNotify(), // ⑥ 通知与提醒
            _groupAppearance(), // ⑦ 外观与语言
            _groupAbout(), // ⑧ 诊断与关于
          ];
          final searching = _query.trim().isNotEmpty;
          final hitAny = groups.any((g) => g.isNotEmpty);
          return ListView(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
            children: [
              _searchField(),
              if (searching && !hitAny) _searchEmpty(),
              for (final g in groups) ...g,
              const SizedBox(height: 12),
              Center(
                child: Text('MoneyFly v${UpdateInfo.currentVersion} · dy.moneyfly.top',
                    style: TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
              ),
            ],
          );
        }),
      ),
    );
  }

  // ── 分组定义 ────────────────────────────────────────────────────────────
  // 每个分组 = 组标题 + 组内条目；条目顺序按「用户先用到的排前面」。
  // 所有条目都通过 _item() 登记搜索关键词（中英文案 + i18n key 都参与匹配）。

  /// ① 连接与内核：连什么模式、怎么自动连/常驻、内核与网卡、端口
  List<Widget> _groupConnect() => _group('group_connect', [
        _item(['settings_default_mode'], _row(icon: '🎯', title: AppStrings.t('settings_default_mode'),
            trailing: _seg2(
              left: AppStrings.t('smart_mode'), right: AppStrings.t('global_mode'),
              selectedLeft: _s['defaultMode'] != 'global',
              onLeft: () => _set('defaultMode', 'smart'),
              onRight: () => _set('defaultMode', 'global'),
            ))),
        _item(['settings_auto_connect'], _row(icon: '🔌', title: AppStrings.t('settings_auto_connect'),
            trailing: _switch(_s['autoConnect'] == true, (v) => _set('autoConnect', v)))),
        // 开机自启动 / 关闭窗口行为：「让代理随时可用」的常驻行为，与自动连接同类
        if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
          _item(['settings_launch_startup'], _row(icon: '🚀', title: AppStrings.t('settings_launch_startup'),
              trailing: _switch(_s['launchAtStartup'] == true, (v) async {
                // 先落系统、成功才落设置。旧实现是先写设置再 unawaited(enable())：
                // 插件在没 setup 时抛 UnsupportedError 被 unawaited 吞掉，于是
                // 开关显示「已开启」而系统里从没注册过 —— 失败必须让用户看见，
                // 且不能让设置项停在「开着」的假状态。
                final ok = v
                    ? await AutostartService.enable()
                    : await AutostartService.disable();
                if (!ok) {
                  _toast(AppStrings.t('launch_at_startup_failed'));
                  return;
                }
                await _set('launchAtStartup', v);
              }))),
        if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
          _item(['close_action'], _row(icon: '🚪', title: AppStrings.t('close_action'),
              value: _closeActionLabel(),
              onTap: _pickCloseAction)),
        _item(['settings_reconnect'], _row(icon: '🔁', title: AppStrings.t('settings_reconnect'), desc: AppStrings.t('settings_reconnect_desc'),
            trailing: _switch(_s['autoReconnect'] == true, (v) => _set('autoReconnect', v)))),
        // TUN 模式行只在**真的能选**的平台显示：Android/iOS 的 tunMode 会被
        // 内核侧强制成 auto（移动端只能走系统隧道），显示出来是个点了没用的
        // 假开关 —— 用户以为自己关掉了 TUN，其实仍在走（旧实现 iOS 正是如此）。
        if (!Platform.isAndroid && !Platform.isIOS)
          _item(['settings_tun'], _row(icon: '🚀', title: AppStrings.t('settings_tun'),
              desc: _tunDesc(),
              value: _tunModeValue(),
              onTap: _pickTunMode)),
        if (Platform.isAndroid)
          _item(['settings_tun_stack'], _row(icon: '🧱', title: AppStrings.t('settings_tun_stack'),
              desc: AppStrings.t('settings_tun_stack_desc'),
              value: _tunStackValue(),
              onTap: () => _picker([
                AppStrings.t('tun_stack_gvisor'),
                AppStrings.t('tun_stack_mixed'),
              ], (v) => _set('tunStack',
                  v == AppStrings.t('tun_stack_mixed') ? 'mixed' : 'gvisor'),
                  current: _tunStackValue()))),
        _item(['settings_local_port'], _row(icon: '🔢', title: AppStrings.t('settings_local_port'),
            desc: AppStrings.t('settings_local_port_desc'),
            value: '${_s['localPort'] ?? 2080}',
            onTap: _pickLocalPort)),
        _item(['settings_clash_api_port'], _row(icon: '🔧', title: AppStrings.t('settings_clash_api_port'),
            desc: AppStrings.t('settings_clash_api_port_desc'),
            value: '${_s['clashApiPort'] ?? 9090}',
            onTap: _pickClashApiPort)),
        _item(['settings_kernel', 'settings_kernel_desc'], _row(icon: '🧩', title: AppStrings.t('settings_kernel'),
            desc: 'SagerNet/sing-box',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const KernelPage())))),
        _item(['settings_geo_data'], _row(icon: '🌍', title: AppStrings.t('settings_geo_data'),
            desc: AppStrings.t('settings_geo_data_desc'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const GeoUpdatePage())))),
      ]);

  /// ② 测速：测速开关、间隔、方式、探测地址 —— 全部集中在同一组
  List<Widget> _groupSpeedTest() => _group('group_speedtest', [
        _item(['settings_auto_test'], _row(icon: '⚡', title: AppStrings.t('settings_auto_test'), desc: AppStrings.t('settings_auto_test_desc'),
            trailing: _switch(_s['autoTest'] == true, (v) => _set('autoTest', v)))),
        _item(['settings_test_interval'], _row(icon: '⏱️', title: AppStrings.t('settings_test_interval'), value: _testIntervalValue(),
            onTap: () => _picker(['15 ${AppStrings.t('settings_minutes')}', '30 ${AppStrings.t('settings_minutes')}', '60 ${AppStrings.t('settings_minutes')}'], (v) => _set('testIntervalMin', int.parse(v.split(' ').first)),
                current: _testIntervalValue()))),
        // 测速方式（对标 Shadowrocket 的 Ping / Connect）。
        // **默认 TCP 测速**＝Ping：只测端口握手的连通性，快、不额外拉起内核；
        // 想要「真连接」判定节点是否真的可用，用户可自己切到内核测速＝Connect
        // （内核真的通过节点发一次请求，凭据/协议/回程全部参与验证）。
        _item(['settings_speed_mode'], _row(icon: '📶', title: AppStrings.t('settings_speed_mode'),
            desc: AppStrings.t('settings_speed_mode_desc'),
            value: _speedModeLabel(),
            onTap: _pickSpeedMode)),
        _item(['settings_test_url'], _row(icon: '🧭', title: AppStrings.t('settings_test_url'), desc: AppStrings.t('settings_test_url_desc'),
            value: _testUrlHost(),
            onTap: _pickTestUrl)),
      ]);

  /// ③ DNS 与分流：DNS 解析、直连名单、按应用分流、证书校验
  List<Widget> _groupDnsSplit() => _group('group_dns_split', [
        // 主 DNS 列表（逗号分隔文本编辑；旧 'dns' 单值键保留兼容，主列表优先）
        _item(['settings_dns'], _row(icon: '🌐', title: AppStrings.t('settings_dns'),
            desc: AppStrings.t('settings_dns_desc'),
            value: _dnsList().join(', '),
            onTap: _pickDnsList)),
        _item(['settings_dns_mode'], _row(icon: '🧭', title: AppStrings.t('settings_dns_mode'),
            desc: AppStrings.t('settings_dns_mode_desc'),
            value: _dnsModeValue(),
            onTap: () => _picker([
              AppStrings.t('dns_mode_auto'),
              AppStrings.t('dns_mode_fakeip'),
              AppStrings.t('dns_mode_redirhost'),
            ], (v) => _set('dnsMode',
                v == AppStrings.t('dns_mode_fakeip')
                    ? 'fake-ip'
                    : (v == AppStrings.t('dns_mode_redirhost')
                        ? 'redir-host'
                        : 'auto')),
                current: _dnsModeValue()))),
        // fake-ip 过滤追加（这些域名保留真实解析，不映射 fake-ip）
        _item(['settings_fakeip_extra'], _row(icon: '🧩', title: AppStrings.t('settings_fakeip_extra'),
            desc: AppStrings.t('settings_fakeip_extra_desc'),
            value: '${_fakeIpExtra().length}',
            onTap: _pickFakeIpFilter)),
        _item(['settings_bypass_lan'], _row(icon: '🏠', title: AppStrings.t('settings_bypass_lan'),
            trailing: _switch(_s['bypassLan'] == true, (v) => _set('bypassLan', v)))),
        // 智能模式下「必须走代理」的网站（内置默认名单 + 这里追加）：
        // chatgpt / gemini / linkedin / tiktok 等被国内 DNS 污染或误判成直连
        // 时打不开，这里让用户能自己补（详见 singbox_config 的 defaultForceProxyDomains）
        _item(['settings_force_proxy'], _row(icon: '🌐', title: AppStrings.t('settings_force_proxy'),
            desc: AppStrings.t('settings_force_proxy_desc'),
            value: '${_forceProxyExtra().length}',
            onTap: _pickForceProxyDomains)),
        _item(['settings_bypass'], _row(icon: '🚫', title: AppStrings.t('settings_bypass'),
            desc: AppStrings.t('settings_bypass_desc'),
            value: '${((_s['bypassDomains'] as List?)?.length ?? 0)}',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BypassPage())))),
        if (Platform.isAndroid)
          _item(['settings_access'], _row(icon: '📱', title: AppStrings.t('settings_access'),
              desc: AppStrings.t('settings_access_desc'),
              value: _accessModeValue(),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AccessPage())))),
        // UDP+TLS 协议（hysteria/hysteria2/tuic）证书校验放宽：
        // 这类节点几乎都用伪装 SNI + 不匹配证书，开着校验必然握不上手
        // （实测 17/17 失败 → 关掉后 16/17 成功）。默认开，可关。
        _item(['settings_udp_insecure'], _row(icon: '🔓', title: AppStrings.t('settings_udp_insecure'),
            desc: AppStrings.t('settings_udp_insecure_desc'),
            trailing: _switch(_s['udpSkipCertVerify'] != false,
                (v) => _set('udpSkipCertVerify', v)))),
      ]);

  /// ④ 订阅与更新：订阅身份/域名、软件更新
  List<Widget> _groupSubscription() => _group('group_subscription_update', [
        _item(['settings_subscribe_ua'], _row(icon: '🪪', title: AppStrings.t('settings_subscribe_ua'),
            desc: AppStrings.t('settings_subscribe_ua_desc'),
            value: ((_s['subscribeUserAgent']?.toString() ?? '').trim().isEmpty)
                ? AppStrings.t('settings_subscribe_ua_default')
                : _s['subscribeUserAgent'].toString(),
            onTap: _pickSubscribeUa)),
        // 线路自救：某些地区官网域名被墙 → 自动/手动改用备用域名（订阅与接口都受益）
        _item(['settings_server_line'], _row(icon: '🛰️', title: AppStrings.t('settings_server_line'),
            desc: _serverLineDesc(),
            value: _serverLineLabel(),
            onTap: _pickServerLine)),
        if (Platform.isAndroid || Platform.isWindows || Platform.isMacOS)
          _item(['settings_auto_download_update'], _row(icon: '⬇️', title: AppStrings.t('settings_auto_download_update'),
              desc: AppStrings.t('settings_auto_download_update_desc'),
              trailing: _switch(_s['autoDownloadUpdatePkg'] == true,
                  (v) => _set('autoDownloadUpdatePkg', v)))),
      ]);

  /// ⑤ 账号与安全：登录态相关动作（改密、设备、本地数据）
  List<Widget> _groupAccount() => _group('group_account', [
        _item(['settings_change_pwd'], _row(icon: '🔑', title: AppStrings.t('settings_change_pwd'), desc: AppStrings.t('cur_pwd'), onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ChangePasswordPage())))),
        // 设备管理入口（与「我的」页同一页面）：账号与安全组里集中放账号相关动作
        _item(['profile_devices', 'settings_devices'], _row(icon: '📱', title: AppStrings.t('profile_devices'),
            desc: AppStrings.t('settings_devices_desc'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DevicesPage())))),
        _item(['settings_clear_data'], _row(icon: '🧹', title: AppStrings.t('settings_clear_data'),
            desc: AppStrings.t('settings_clear_data_desc'),
            danger: true,
            onTap: _clearLocalData)),
      ]);

  /// ⑥ 通知与提醒：本地通知总开关（到期提醒 / 连接异常）
  List<Widget> _groupNotify() => _group('group_notify', [
        _item(['settings_notify'], _row(icon: '🔔', title: AppStrings.t('settings_notify'),
            desc: AppStrings.t('settings_notify_desc'),
            trailing: _switch(_s['notify'] != false, (v) => _set('notify', v)))),
      ]);

  /// ⑦ 外观与语言：主题、语言
  List<Widget> _groupAppearance() => _group('group_appearance', [
        _item(['settings_theme', 'appearance'], _appearanceRow()),
        _item(['settings_language'], _row(icon: '🌏', title: AppStrings.t('settings_language'),
            value: AppStrings.lang == 'en' ? 'English' : '简体中文',
            onTap: _pickLanguage)),
      ]);

  /// ⑧ 诊断与关于：日志、许可、版本
  List<Widget> _groupAbout() => _group('group_about', [
        _item(['log_center_title'], _row(icon: '📋', title: AppStrings.t('log_center_title'),
            desc: AppStrings.t('log_center_desc'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogCenterPage())))),
        _item(['settings_crash_report'], _row(icon: '💥', title: AppStrings.t('settings_crash_report'),
            desc: AppStrings.t('settings_crash_report_desc'),
            trailing: _switch(_s['crashReport'] == true, (v) {
              setState(() => _s['crashReport'] = v);
              CrashLogger.setEnabled(v);
              _set('crashReport', v);
            }))),
        // 开源许可（Flutter 内置许可页：内核、依赖库的许可证一览）
        _item(['settings_licenses'], _row(icon: '📜', title: AppStrings.t('settings_licenses'),
            onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'MoneyFly',
                  applicationVersion: UpdateInfo.currentVersion,
                ))),
      ]);

  /// 设置项搜索框（空 = 正常浏览全部设置）
  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(fontSize: 13.5),
        decoration: mfInput(
          hint: AppStrings.t('settings_search_hint'),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
        ),
      ),
    );
  }

  Widget _searchEmpty() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 28, 2, 8),
      child: Center(
        child: Text(AppStrings.t('settings_search_empty'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: MFColors.txt3)),
      ),
    );
  }

  /// 一个设置条目 + 它的搜索关键词（中英文案与 i18n key 都参与匹配）
  _SettingItem _item(List<String> keys, Widget child) => _SettingItem(keys, child);

  /// 渲染一个分组：标题 + 组内条目；搜索时只渲染命中的条目，整组无命中则整组隐藏。
  List<Widget> _group(String titleKey, List<_SettingItem> items) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty ? items : items.where((it) => it.matches(q)).toList();
    if (shown.isEmpty) return const <Widget>[];
    return <Widget>[
      _section(AppStrings.t(titleKey)),
      for (final it in shown) it.child,
    ];
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Text(title,
          style:  TextStyle(fontSize: 11, color: MFColors.txt3, fontWeight: FontWeight.w700, letterSpacing: 2)),
    );
  }

  /// 统一行组件。原实现是 `Container(height: 52)` + 「标题/描述」和「值(≤150px)」
  /// 挤同一行 —— 380 宽（最小窗口）下描述只剩 ~94px，中英文描述都会被裁掉并抛
  /// RenderFlex overflow（实测 37 次）。现在委托给 MFRow：最小高度 + 描述独占一行。
  Widget _row({
    required String icon,
    required String title,
    String? desc,
    String? value,
    Widget? trailing,
    bool danger = false,
    bool showDot = false,
    VoidCallback? onTap,
  }) {
    return MFRow(
      icon: icon,
      title: title,
      desc: desc,
      value: value,
      trailing: trailing,
      danger: danger,
      showDot: showDot,
      onTap: onTap,
    );
  }

  Widget _switch(bool value, ValueChanged<bool> onChanged) {
    return Transform.scale(scale: .82, child: Switch(value: value, onChanged: onChanged));
  }

  /// 外观选择：6 套完整外观模式（背景 + 卡片 + 品牌整套切换），点击即切（立即生效 + 持久化）
  Widget _appearanceRow() {
    final current = ThemeController.instance.appearance;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      decoration: BoxDecoration(
          color: MFColors.card,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: MFColors.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                    color: MFColors.card2, borderRadius: BorderRadius.circular(9)),
                alignment: Alignment.center,
                child: const Text('🎨', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(AppStrings.t('settings_theme'),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: MFColors.txt)),
              ),
              Text(
                  AppStrings.t(
                      mfThemeLabels[current] ?? 'appearance_light'),
                  style: TextStyle(
                      fontSize: 12,
                      color: MFColors.brand,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final key in mfThemeKeys)
                // 外观色卡同样要有按压反馈（旧实现 GestureDetector + Container，
                // 按下去毫无反应）；色卡底色画在 Ink 上，水波纹才看得见
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      ThemeController.instance.setAppearance(key);
                      _set('appearance', key);
                    },
                    borderRadius: BorderRadius.circular(9),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Ink(
                          width: 42,
                          height: 30,
                          decoration: BoxDecoration(
                            color: mfThemeOf(key).card,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: current == key
                                  ? MFColors.brand
                                  : mfThemeOf(key).line,
                              width: current == key ? 2 : 1,
                            ),
                          ),
                          child: Center(
                            child: Container(
                              width: 11,
                              height: 11,
                              decoration: BoxDecoration(
                                  color: mfThemeOf(key).brand,
                                  shape: BoxShape.circle),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                            AppStrings.t(mfThemeLabels[key] ?? ''),
                            style: TextStyle(
                                fontSize: 10,
                                color: current == key
                                    ? MFColors.brand
                                    : MFColors.txt3,
                                fontWeight: current == key
                                    ? FontWeight.w700
                                    : FontWeight.w500)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 两段式开关（智能/全局 等）。
  ///
  /// 标签必须能压缩：它作为「行尾控件」时拿到的宽度可能很窄（英文标签 + 380 宽
  /// 最小窗口），旧实现两个 Text 都没有 maxLines/省略号，实测整行溢出 19px 并把
  /// 标题挤成 0 宽（标题完全看不见）。现在每个标签 Flexible + 单行省略。
  ///
  /// 可点区域用 InkWell（审计 P2）：旧实现是 GestureDetector + Container，按下去
  /// 没有任何反馈。渐变底必须画在 `Ink` 上（不是 Container）—— Material 的墨水层
  /// 在子 widget **下面**，用不透明 Container 会把水波纹整个盖住。
  Widget _seg2({required String left, required String right, required bool selectedLeft,
      required VoidCallback onLeft, required VoidCallback onRight}) {
    Widget seg(String label, bool selected, VoidCallback onTap) {
      return Flexible(
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              gradient: selected ? MFColors.brandGradient : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(7),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                child: Text(label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : MFColors.txt3)),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: MFColors.card2, borderRadius: BorderRadius.circular(9)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(left, selectedLeft, onLeft),
          seg(right, !selectedLeft, onRight),
        ],
      ),
    );
  }

  String _accessModeValue() {
    return switch (_s['accessControlMode']?.toString()) {
      'selected' => AppStrings.t('access_mode_selected'),
      'denied' => AppStrings.t('access_mode_denied'),
      _ => AppStrings.t('access_mode_all'),
    };
  }

  /// 后台测速间隔的展示文案（同时用作选择器「当前值」判定，两者必须同源）
  String _testIntervalValue() =>
      '${_s['testIntervalMin'] ?? 30} ${AppStrings.t('settings_minutes')}';

  /// TUN 堆栈展示文案（同上，行内展示与选择器勾选同源）
  String _tunStackValue() =>
      (_s['tunStack']?.toString() ?? 'gvisor') == 'mixed'
          ? AppStrings.t('tun_stack_mixed')
          : AppStrings.t('tun_stack_gvisor');

  /// DNS 模式展示文案（同上）
  String _dnsModeValue() {
    return switch (_s['dnsMode']?.toString()) {
      'fake-ip' => AppStrings.t('dns_mode_fakeip'),
      'redir-host' => AppStrings.t('dns_mode_redirhost'),
      _ => AppStrings.t('dns_mode_auto'),
    };
  }

  /// TUN 模式展示文案（同上）
  String _tunModeValue() {
    return switch (_s['tunMode']?.toString()) {
      'off' => AppStrings.t('tun_off'),
      'force' => AppStrings.t('tun_force'),
      _ => AppStrings.t('tun_auto'),
    };
  }

  String? _tunDesc() {
    final mode = _s['tunMode']?.toString() ?? 'off';
    if (mode == 'off') return AppStrings.t('tun_off_hint');
    if (Platform.isAndroid || Platform.isIOS) return null;
    if (Platform.isWindows) return AppStrings.t('tun_need_admin');
    if (Platform.isMacOS) return AppStrings.t('tun_need_root');
    return null;
  }

  /// 校验型文本对话框：**校验在对话框内部执行**。
  ///
  /// 旧实现（审计 P1）四个对话框是同一个坏模式：`Navigator.pop(ctx, ctrl.text)`
  /// **先关闭**，关闭之后才校验，失败只能 `_toast` 闪 4 秒 snackbar —— 用户（尤其是
  /// 一次性粘贴一整串 DNS 的）输入全被丢掉，必须重新打开对话框、重新输入。
  /// 现在 [validate] 返回非 null（错误文案）时：对话框**不关**、错误常驻在输入框
  /// 下方（InputDecoration.errorText）、已输入内容原样保留，用户可以就地改。
  Future<String?> _askText({
    required String title,
    required String initial,
    required String? Function(String raw) validate,
    String? hint,
    String? helper,
    TextInputType? keyboardType,
    int? minLines,
    int? maxLines,
    TextStyle? style,
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(builder: (ctx, setDlg) {
          void submit() {
            final e = validate(ctrl.text);
            if (e != null) {
              setDlg(() => error = e);
              return; // 校验不过：不 pop，输入与错误都留在对话框里
            }
            Navigator.pop(ctx, ctrl.text);
          }

          return AlertDialog(
            backgroundColor: MFColors.card2,
            title: Text(title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: keyboardType,
              minLines: minLines,
              maxLines: maxLines,
              style: style ?? TextStyle(color: MFColors.txt),
              onSubmitted: (_) => submit(),
              decoration: _mfInputErr(hint: hint, helper: helper, error: error),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppStrings.t('cancel_text')),
              ),
              TextButton(
                onPressed: submit,
                child: Text(AppStrings.t('save'),
                    style: TextStyle(color: MFColors.brandLight)),
              ),
            ],
          );
        });
      },
    );
  }

  /// 端口输入弹窗通用件：返回合法端口；[forbidden] 返回与之冲突的值时应拒绝
  Future<int?> _askPort(String title, String hint, int cur, String invalidMsg,
      int? forbidden, {String? helper}) async {
    final v = await _askText(
      title: title,
      initial: '$cur',
      hint: hint,
      helper: helper ?? AppStrings.t('settings_local_port_desc'),
      keyboardType: TextInputType.number,
      validate: (raw) {
        final p = int.tryParse(raw.trim());
        if (p == null ||
            p < 1024 ||
            p > 65535 ||
            (forbidden != null && p == forbidden)) {
          return invalidMsg;
        }
        return null;
      },
    );
    if (v == null) return null;
    return int.tryParse(v.trim());
  }

  /// 保存端口类设置：已连接 → 自动断开并用新值重连（内核重启后才生效）
  Future<void> _applyPortChange(String key, int value) async {
    await _set(key, value);
    final conn = ConnectionController.instance;
    if (conn.status == ConnStatus.connected) {
      _toast(AppStrings.t('local_port_reconnect'));
      unawaited(() async {
        await conn.disconnect();
        await conn.connect();
      }());
    } else {
      _toast(AppStrings.t('local_port_saved'));
    }
  }

  /// 本地代理端口（默认 2080），不能与 Clash API 端口相同
  Future<void> _pickLocalPort() async {
    final cur = (_s['localPort'] as num?)?.toInt() ?? 2080;
    final clash = (_s['clashApiPort'] as num?)?.toInt() ?? 9090;
    final p = await _askPort(AppStrings.t('settings_local_port'), '2080', cur,
        AppStrings.t('local_port_invalid'), clash);
    if (p == null) return;
    await _applyPortChange('localPort', p);
  }

  /// Clash API 管理端口（默认 9090），不能与本地代理端口相同
  Future<void> _pickClashApiPort() async {
    final cur = (_s['clashApiPort'] as num?)?.toInt() ?? 9090;
    final local = (_s['localPort'] as num?)?.toInt() ?? 2080;
    final p = await _askPort(AppStrings.t('settings_clash_api_port'), '9090', cur,
        AppStrings.t('clash_api_port_invalid'), local,
        helper: AppStrings.t('settings_clash_api_port_desc'));
    if (p == null) return;
    await _applyPortChange('clashApiPort', p);
  }

  /// 当前测速方式（缺 key / 值损坏都回落默认 TCP 测速，与 parseSpeedTestMode 一致）。
  SpeedTestMode get _speedMode =>
      parseSpeedTestMode(_s['speedTestMode']);

  /// 设置行右侧显示的当前方式（短文案，窄窗口不挤爆 MFRow 的值区）
  String _speedModeLabel() => _speedMode == SpeedTestMode.tcp
      ? AppStrings.t('speed_mode_tcp')
      : AppStrings.t('speed_mode_kernel');

  /// 切换测速方式。
  ///
  /// 选项文案带上「真实连接 / 仅端口连通」的取舍说明（放在选项里而不是
  /// 只放描述行）：用户点开选择器时正是要做决定的那一刻。
  /// **默认项（TCP 测速）排在第一行**：不选也是在用的那个，先看到它。
  /// 落盘后 `_set` → `ConnectionController.applySettings` 会检测到方式变化并
  /// **清空列表里另一种方式测出的延迟**，两种口径的数字绝不会混着显示。
  Future<void> _pickSpeedMode() async {
    final kernelLabel = AppStrings.t('speed_mode_kernel');
    final tcpLabel = AppStrings.t('speed_mode_tcp');
    final desc = {
      kernelLabel: AppStrings.t('speed_mode_kernel_desc'),
      tcpLabel: AppStrings.t('speed_mode_tcp_desc'),
    };
    // label → 模式 的映射与 options 同源，避免用字符串比较/identical 反推
    final modes = <String, SpeedTestMode>{
      '$tcpLabel · ${desc[tcpLabel]}': SpeedTestMode.tcp,
      '$kernelLabel · ${desc[kernelLabel]}': SpeedTestMode.kernel,
    };
    final options = modes.keys.toList();
    final current =
        options.firstWhere((o) => modes[o] == _speedMode, orElse: () => options[0]);
    await _picker(options, (v) {
      final mode = modes[v] ?? defaultSpeedTestMode;
      unawaited(_set('speedTestMode', speedTestModeKey(mode)));
    }, current: current);
  }

  /// 测速地址（默认谷歌 204；网络环境特殊时可改）
  Future<void> _pickTestUrl() async {
    final cur = _s['testUrl']?.toString() ?? ConnectionController.defaultTestUrl;
    final v = await _askText(
      title: AppStrings.t('settings_test_url'),
      initial: cur,
      hint: ConnectionController.defaultTestUrl,
      helper: AppStrings.t('settings_test_url_desc'),
      keyboardType: TextInputType.url,
      validate: (raw) {
        final u = raw.trim();
        return (u.startsWith('http://') || u.startsWith('https://'))
            ? null
            : AppStrings.t('test_url_invalid');
      },
    );
    if (v == null) return; // 取消
    // _set 内部已同步到连接控制器（applySettings 读取 testUrl）
    await _set('testUrl', v.trim());
  }

  /// 订阅自定义 User-Agent：部分机场按 UA 返回不同客户端格式，留一个自救入口。
  /// 留空 = 使用默认 `MoneyFly/<版本>`。
  Future<void> _pickSubscribeUa() async {
    final cur = _s['subscribeUserAgent']?.toString() ?? '';
    final ctrl = TextEditingController(text: cur);
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_subscribe_ua'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: MFColors.txt),
          decoration: mfInput(
            hint: 'clash-verge/v2.0.0',
            helper: AppStrings.t('settings_subscribe_ua_desc'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('cancel_text')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text(AppStrings.t('save'),
                style: TextStyle(color: MFColors.brandLight)),
          ),
        ],
      ),
    );
    if (v == null) return; // 取消
    await _set('subscribeUserAgent', v); // 空串 = 回默认 UA
  }

  /// 测速地址行展示：取 host，避免超长 URL 挤爆行
  String _testUrlHost() {
    final u = _s['testUrl']?.toString() ?? ConnectionController.defaultTestUrl;
    final host = Uri.tryParse(u)?.host;
    return (host != null && host.isNotEmpty) ? host : u;
  }

  /// 服务器线路行展示：当前**实际生效**域名（兜底/自定义时加标记）。
  /// 用户选的那条与实际不一致时，说明文案由 [_serverLineDesc] 如实给出。
  String _serverLineLabel() {
    final pool = ServerPool.instance;
    if (pool.fellBackFromPin) return '${pool.activeHost} · 兜底';
    if (pool.usingCustom) return '${pool.activeHost} · 自定义';
    return pool.activeHost;
  }

  /// ① 线路说明：默认是原说明；当"用户选的线路"没在用时，如实说明并给出口
  String _serverLineDesc() {
    final pool = ServerPool.instance;
    if (pool.fellBackFromPin) {
      return AppStrings.t('settings_server_line_pinned', {
        'pinned': pool.userPinnedHost,
        'active': pool.activeHost,
      });
    }
    return AppStrings.t('settings_server_line_desc');
  }

  /// 服务器线路选择：自动（主域名优先）／池内其它线路／自定义域名。
  ///
  /// 存在的意义：某些地区官网域名被墙，用户"登录不进去、更新不了订阅"。
  /// 这里让用户能看到当前走哪个域名，并手动切到能用的那个（自动切换见 ServerPool）。
  Future<void> _pickServerLine() async {
    final pool = ServerPool.instance;
    await pool.ensureLoaded();
    if (!mounted) return;
    final all = pool.all;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_server_line'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        children: [
          if (pool.fellBackFromPin)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, '__back_to_pin__'),
              child: Text(
                AppStrings.t('settings_server_line_back_to_pin',
                    {'host': pool.userPinnedHost}),
                style: TextStyle(color: MFColors.brandLight),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, '__auto__'),
            child: Text(
              AppStrings.t('settings_server_line_auto'),
              style: TextStyle(
                  color: pool.usingCustom || pool.activeIndex != 0
                      ? MFColors.txt
                      : MFColors.brandLight),
            ),
          ),
          for (final base in all)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, base),
              child: Text(
                '${Uri.tryParse(base)?.host ?? base}'
                '${base == pool.activeBase ? '  ✓' : ''}',
                style: TextStyle(
                    color: base == pool.activeBase
                        ? MFColors.brandLight
                        : MFColors.txt),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, '__custom__'),
            child: Text(AppStrings.t('settings_server_line_custom'),
                style: TextStyle(color: MFColors.txt)),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;

    if (picked == '__back_to_pin__') {
      // ② 一键回到用户选的线路：清掉它的失败冷却并记为生效线路，
      // 然后立刻重拉（下面的 _refreshAfterLineSwitch 会带你走一遍）
      await pool.retryUserPinnedLine();
    } else if (picked == '__auto__') {
      await pool.reset();
    } else if (picked == '__custom__') {
      final ctrl = TextEditingController(text: pool.usingCustom ? pool.activeHost : '');
      final input = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: MFColors.card2,
          title: Text(AppStrings.t('settings_server_line'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: MFColors.txt),
            decoration: mfInput(hint: AppStrings.t('settings_server_line_custom_hint')),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.t('cancel_text'))),
            TextButton(
                onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                child: Text(AppStrings.t('save'),
                    style: TextStyle(color: MFColors.brandLight))),
          ],
        ),
      );
      if (input == null || !mounted) return;
      final normalized = ServerPool.normalizeBase(input);
      if (normalized.isEmpty) {
        _toast(AppStrings.t('settings_server_line_custom_bad'));
        return;
      }
      await pool.setCustom(normalized);
    } else {
      await pool.markWorking(picked);
    }
    if (!mounted) return;
    // 用户已经做出新选择 → 之前的兜底提示过期，清掉避免首页再弹
    ServerPool.clearFallbackNotice();
    setState(() {});
    _toast(AppStrings.t('settings_server_line_switched')
        .replaceAll('{host}', pool.activeHost));
    // 换线路后**立刻用新线路的域名重拉账号与订阅**：
    // 只改地址不重拉的话，本次会话（以及重启前的每次自动刷新）仍然沿用旧域名
    // 拉到的内容/旧域名的订阅地址，用户看到的还是「换了线路照样拉取失败」。
    // 重拉会按当前线路改写订阅域名（见 SubscriptionService._pinToActiveLine）。
    await _refreshAfterLineSwitch();
  }

  /// 换线路后的强制刷新（账号 + 订阅 + 应用到连接器）。
  ///
  /// 复用与「重新绑定本机」相同的刷新链路：先刷账号（拿到最新的 subscribe_url /
  /// 设备状态），再拉订阅节点，最后喂给连接器（已连接时不会打断当前线路）。
  Future<void> _refreshAfterLineSwitch() async {
    // ⑥ 换线路后重排「域名快慢」：实测结果只在启动时测过一次，换线路/换网络后
    //    结论可能已经变了。探测很轻（约 1KB 的小接口），失败不影响主流程。
    unawaited(() async {
      try {
        final ranked = await ApiClient.probeDomainLatency();
        if (ranked.isNotEmpty) {
          await ServerPool.instance.applyLatencyRanking(ranked);
        }
      } catch (e) {
        AppLog.error('换线路后域名重排失败: $e');
      }
    }());
    try {
      await AccountService.instance.refresh(force: true);
      final nodes = await SubscriptionService.instance.fetchNodes(force: true);
      await ConnectionController.instance.applySubscriptionNodes(nodes);
      AppLog.log('LINE', '已切到线路 ${ServerPool.instance.activeHost} 并重拉订阅');
    } catch (e) {
      // 新线路也拉不到时如实记录，不打断用户（首页的限制/失败提示会引导重试）
      AppLog.error('refresh after line switch failed: $e');
    }
  }

  /// 生效的主 DNS 列表：dnsNameservers（新，主列表）> dns（旧单值兼容）> 默认
  List<String> _dnsList() {
    final stored = _s['dnsNameservers'];
    if (stored is List && stored.isNotEmpty) {
      return List<String>.from(stored.whereType<String>());
    }
    final legacy = _s['dns']?.toString().trim() ?? '';
    if (legacy.isNotEmpty && legacy != '223.5.5.5') return [legacy];
    return List<String>.from(_defaultDnsServers);
  }

  /// fake-ip 过滤追加域名列表（SettingsStore['fakeIpFilterExtra']）
  List<String> _fakeIpExtra() {
    final l = _s['fakeIpFilterExtra'];
    return l is List
        ? List<String>.from(l.whereType<String>())
        : const <String>[];
  }

  /// 逗号（半/全角）、换行分隔的 DNS 文本 → 去空白、去重、保序的列表
  static List<String> _splitServerText(String v) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in v.split(RegExp(r'[,，\r\n]+'))) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  bool _isIpv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    for (final o in parts) {
      if (o.isEmpty) return false;
      if (o.length > 1 && o.startsWith('0')) return false;
      final n = int.tryParse(o);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// 主机名（单/多标签，可带结尾点；DNS 域名/DoH host 都走这里）
  bool _isHostname(String s) {
    if (s.isEmpty || s.length > 253 || s.contains('..')) return false;
    return RegExp(
            r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.?$')
        .hasMatch(s);
  }

  /// 单个 DNS 服务器是否合法：IPv4 / IPv6 / 域名 / DoH·DoT 带协议 URL
  bool _isValidDnsServer(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    // https://dns.alidns.com/dns-query、tls://dns.google 等带协议地址
    if (t.contains('://')) {
      final u = Uri.tryParse(t);
      return u != null && u.host.isNotEmpty;
    }
    if (t.contains(':')) {
      // IPv6（可带 [ ]）
      final v6 = t.replaceAll('[', '').replaceAll(']', '');
      if (RegExp(r'^[0-9a-fA-F:]+$').hasMatch(v6) &&
          (v6.contains('::') || ':'.allMatches(v6).length >= 2)) {
        return true;
      }
      return false; // host:port 形式的内核 nameserver 不支持
    }
    return _isIpv4(t) || _isHostname(t);
  }

  /// 主 DNS 列表编辑（逗号/换行分隔文本），合法才保存
  Future<void> _pickDnsList() async {
    final v = await _askText(
      title: AppStrings.t('settings_dns'),
      initial: _dnsList().join(', '),
      hint: AppStrings.t('dns_list_hint'),
      keyboardType: TextInputType.url,
      minLines: 2,
      maxLines: 5,
      validate: (raw) {
        final servers = _splitServerText(raw);
        if (servers.isEmpty) return AppStrings.t('dns_list_required');
        for (var i = 0; i < servers.length; i++) {
          if (!_isValidDnsServer(servers[i])) {
            return AppStrings.t('dns_list_invalid', {'n': '${i + 1}'});
          }
        }
        return null;
      },
    );
    if (v == null) return; // 取消
    await _set('dnsNameservers', _splitServerText(v));
  }

  /// 规范化 fake-ip 过滤条目：小写，可选 `*.` 前缀，须为合法域名
  String? _normalizeFakeIpPattern(String raw) {
    var p = raw.trim().toLowerCase();
    var wildcard = false;
    if (p.startsWith('*.')) {
      wildcard = true;
      p = p.substring(2);
    }
    if (p.startsWith('.')) p = p.substring(1);
    if (!_isHostname(p)) return null;
    return wildcard ? '*.$p' : p;
  }

  /// fake-ip 过滤追加域名编辑（每行一个；域名保留真实解析）
  /// 用户追加的「必须走代理」域名（内置默认名单在生成器里，这里只存追加项）
  List<String> _forceProxyExtra() {
    final l = _s['forceProxyDomains'];
    return l is List ? List<String>.from(l.whereType<String>()) : const <String>[];
  }

  /// 编辑「必须走代理」域名：一行一个，写入 forceProxyDomains（保存后重连生效）
  Future<void> _pickForceProxyDomains() async {
    final v = await _askText(
      title: AppStrings.t('settings_force_proxy'),
      initial: _forceProxyExtra().join('\n'),
      hint: AppStrings.t('settings_force_proxy_hint'),
      keyboardType: TextInputType.multiline,
      minLines: 4,
      maxLines: 8,
      style: TextStyle(color: MFColors.txt, fontSize: 13),
      validate: (raw) {
        // 只校验"每行不是空、不含空格"——域名清单允许用户随意试，
        // 真正的匹配由内核按 DOMAIN-SUFFIX 做，写错了最多少生效一条
        for (final it in _splitServerText(raw)) {
          if (it.contains(' ')) return AppStrings.t('settings_force_proxy_hint');
        }
        return null;
      },
    );
    if (v == null) return; // 取消
    final out = <String>[];
    for (final it in _splitServerText(v)) {
      final d = it.trim().toLowerCase();
      if (d.isEmpty) continue;
      out.add(d);
    }
    await _set('forceProxyDomains', out);
    if (!mounted) return;
    _toast(AppStrings.t('settings_force_proxy_saved', {'n': '${out.length}'}));
  }

  Future<void> _pickFakeIpFilter() async {
    final v = await _askText(
      title: AppStrings.t('settings_fakeip_extra'),
      initial: _fakeIpExtra().join('\n'),
      hint: AppStrings.t('fakeip_extra_hint'),
      keyboardType: TextInputType.multiline,
      minLines: 3,
      maxLines: 6,
      style: TextStyle(color: MFColors.txt, fontSize: 13),
      validate: (raw) {
        final items = _splitServerText(raw);
        for (var i = 0; i < items.length; i++) {
          if (_normalizeFakeIpPattern(items[i]) == null) {
            return AppStrings.t('fakeip_invalid', {'line': '${i + 1}'});
          }
        }
        return null; // 全部清空 = 合法（允许用户清掉整个列表）
      },
    );
    if (v == null) return; // 取消
    final out = <String>[];
    for (final it in _splitServerText(v)) {
      final norm = _normalizeFakeIpPattern(it);
      if (norm != null) out.add(norm);
    }
    await _set('fakeIpFilterExtra', out);
  }

  Future<void> _pickTunMode() async {
    final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    final options = [AppStrings.t('tun_auto'), AppStrings.t('tun_force'), AppStrings.t('tun_off')];
    // 当前模式（与行内展示同一份映射）→ 该行打勾，用户能看出现在选的是哪个
    final currentLabel = _tunModeValue();
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('tun_title'), style: TextStyle(fontSize: 15)),
        children: [
          if (isDesktop)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MFColors.amber.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: MFColors.amber.withValues(alpha: .3)),
                ),
                child: Text(
                  Platform.isWindows
                      ? AppStrings.t('tun_win_hint')
                      : AppStrings.t('tun_mac_hint'),
                  style: TextStyle(fontSize: 11, color: MFColors.txt2, height: 1.6),
                ),
              ),
            ),
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Row(
                children: [
                  if (o == currentLabel) ...[
                    Icon(Icons.check, size: 16, color: MFColors.brandLight),
                    const SizedBox(width: 8),
                  ],
                  // 标签/说明都要能压缩：Row 里非 flex 的 Text 按无限宽测量，
                  // 窄对话框（380 最小窗口）下会直接 RenderFlex overflow
                  Expanded(
                    child: Text(o,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      o == AppStrings.t('tun_off') ? AppStrings.t('tun_only_proxy') : (o == AppStrings.t('tun_force') ? AppStrings.t('tun_full_intercept') : AppStrings.t('tun_dual')),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(fontSize: 10.5, color: MFColors.txt3),
                    ),
                  ),
                ],
              ),
            ),
          // UDP/游戏提示：系统代理（HTTP）不承载 UDP，Steam/游戏需 TUN
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: MFColors.amber.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: MFColors.amber.withValues(alpha: .3)),
              ),
              child: Text(
                AppStrings.t('tun_game_tip'),
                style: TextStyle(fontSize: 11, color: MFColors.txt2, height: 1.6),
              ),
            ),
          ),
        ],
      ),
    );
    if (v != null) {
      final mode = v == AppStrings.t('tun_force') ? 'force' : (v == AppStrings.t('tun_off') ? 'off' : 'auto');
      await _set('tunMode', mode);
      // TUN 是**建连期参数**：内核只在启动时读它。旧实现只落盘、不重连也不提示，
      // 用户切到 TUN 后当前连接其实还是系统代理（或反之），界面却毫无反馈。
      final conn = ConnectionController.instance;
      if (conn.status == ConnStatus.connected) {
        _toast(AppStrings.t('setting_reconnect_applied'));
        unawaited(() async {
          await conn.disconnect();
          await conn.connect();
        }());
      } else {
        _toast(AppStrings.t('setting_saved_next_connect'));
      }
    }
  }

  /// 语言切换：简体中文 / English（立即生效）
  Future<void> _pickLanguage() async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        // 标题必须走 l10n：项目默认中文，旧实现写死英文 'Language'
        title: Text(AppStrings.t('settings_language'), style: TextStyle(fontSize: 15)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'zh'),
            child: Row(children: [
              Text(AppStrings.t('zh'), style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
              if (AppStrings.lang == 'zh') ...[
                const Spacer(),
                Icon(Icons.check, size: 16, color: MFColors.brandLight),
              ],
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'en'),
            child: Row(children: [
              Text(AppStrings.t('en'), style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
              if (AppStrings.lang == 'en') ...[
                const Spacer(),
                Icon(Icons.check, size: 16, color: MFColors.brandLight),
              ],
            ]),
          ),
        ],
      ),
    );
    if (v != null && v != AppStrings.lang) {
      await LocaleController.instance.setLang(v);
    }
  }


  /// 清除本地数据（订阅配置缓存 / 节点 / 运行日志）：
  /// 断开连接 → 清内存与磁盘订阅缓存 → 清日志。保留登录状态，
  /// 下次进入节点页会重新拉取最新订阅（配合到期/禁用后强制刷新，
  /// 避免旧配置残留；卸载前清空也用它）。
  Future<void> _clearLocalData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_clear_data'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(AppStrings.t('clear_data_confirm'),
            style: TextStyle(fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('confirm'),
                style: TextStyle(color: MFColors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final conn = ConnectionController.instance;
      if (conn.status == ConnStatus.connected ||
          conn.status == ConnStatus.connecting ||
          conn.status == ConnStatus.reconnecting) {
        await conn.disconnect();
      }
      // 清订阅缓存（内存 + 磁盘）
      SubscriptionService.instance.clearCache();
      // 清内存节点展示（下次进入节点页/首页会自动重新拉取）
      await conn.loadNodes(const []);
      // 清运行日志
      await AppLog.clear();
      if (mounted) _toast(AppStrings.t('clear_data_done'));
    } catch (_) {
      if (mounted) _toast(AppStrings.t('clear_data_failed'));
    }
  }

  /// 软件升级：读后端软件库 → 比对版本 → 弹更新对话框
  String _closeActionLabel() {
    return switch (_s['closeAction']?.toString()) {
      'hide' => AppStrings.t('close_action_hide'),
      'quit' => AppStrings.t('close_action_quit'),
      _ => AppStrings.t('close_action_ask'),
    };
  }

  Future<void> _pickCloseAction() async {
    final labels = <String, String>{
      AppStrings.t('close_action_ask'): 'ask',
      AppStrings.t('close_action_hide'): 'hide',
      AppStrings.t('close_action_quit'): 'quit',
    };
    await _picker(labels.keys.toList(), (label) {
      final v = labels[label];
      if (v != null) unawaited(_set('closeAction', v));
    }, current: _closeActionLabel());
  }

  /// 单选列表弹窗。 [current] 传当前值 → 该行右侧显示勾选（审计 P2：本文件的
  /// 选择器都不标当前值，而节点页 / 内核页都有，用户看不出现在选的是哪个）。
  Future<void> _picker(List<String> options, ValueChanged<String> onSelected,
      {String? current}) async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('pick_option'), style: TextStyle(fontSize: 15)),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Row(
                children: [
                  // Expanded + 省略号：选项文案在窄对话框里必须能压缩，否则
                  // Row 内无界测量的 Text 会直接溢出（Ahem 测试字体更宽）
                  Expanded(
                    child: Text(o,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
                  ),
                  if (o == current) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check, size: 16, color: MFColors.brandLight),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    if (v != null) onSelected(v);
  }

void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 设置页的一个条目 + 它的搜索关键词。
///
/// 设置项搜索（本页顶部搜索框）用：关键词既匹配 i18n key（英文/拼音友好，
/// 如 `tun`、`speed_mode`），也匹配当前语言下的真实文案（`测速`、`Speed`）——
/// 用户不需要知道 key 叫什么，按界面上看到的字搜就行。
class _SettingItem {
  const _SettingItem(this.keys, this.child);

  final List<String> keys;
  final Widget child;

  bool matches(String q) {
    for (final k in keys) {
      if (k.toLowerCase().contains(q)) return true;
      if (AppStrings.t(k).toLowerCase().contains(q)) return true;
    }
    return false;
  }
}

/// 对话框输入框装饰：错误常驻在输入框下方（审计 P1：旧实现先 pop 再校验，
/// 错误只能靠 4 秒 snackbar 闪一下、输入还被丢掉）。
/// 现在 [mfInput] 自己就支持 `errorText`（含错误边框），不再需要就地补一份。
InputDecoration _mfInputErr({String? hint, String? helper, String? error}) =>
    mfInput(hint: hint, helper: helper, errorText: error);
