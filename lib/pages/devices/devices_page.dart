import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/user_agent.dart';
import '../../core/models/models.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/services/account_service.dart';
import '../../core/services/app_log.dart';
import '../../core/services/subscription_service.dart';
import '../../core/services/device_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_skeleton.dart';
import '../../widgets/mf_empty.dart';
import '../package/upgrade_devices_page.dart';

/// 设备管理：列表（全量）/ 删除（踢下线）/ 备注编辑 / 在线状态。
///
/// 顶部常驻「升级设备数量」入口（无论是否超限都可点：客户可增加设备名额并
/// 顺带延长到期时间）；设备在线状态以后端按最近活跃窗口计算的 online 为准
/// （不再用只增不减的 is_active 显示「永久在线」）。
///
/// **删除按钮由后台开关决定**（`allow_delete_device`，随设备列表接口实时下发）：
///   - 允许 → 每台设备显示「删除」（踢下线）；
///   - 不允许 → 不渲染删除入口，改为「升级设备数量」按钮 + 顶部原因说明，
///     引导用户升级名额去接新设备（后台 `DELETE /devices/:id` 同源拦截，
///     客户端不显示入口是为了不给用户「点了才被 403 拒绝」的坏体验）。
/// 开关字段缺失（旧后端）按不可删除处理，详见 `parseAllowDeleteDevice`。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

/// 设备列表里哪一条是「本机」。
///
/// 为什么重要：删除设备 = 踢下线，**删掉本机就等于把自己踢掉**（用户 2026-09-21
/// 真实工单：到期后把设备全删了，续费一年仍然拿不到节点，因为本机已被移除）。
/// 之前列表里不区分本机，用户根本不知道自己删的是正在用的这台。
///
/// 判定口径与后端识别设备的口径一致，**优先用硬件指纹**：
///  ① 后端下发 `device_hw_fp`（= 本机上报的 `X-MF-Device-Fp`）时按它精确比对 ——
///     同型号两台电脑的机型/品牌完全一样，只靠机型会把别人的机器误标成本机；
///  ② 旧后端不发该字段、或本机读不到硬件指纹时，退回机型 + 品牌的启发式判断。
bool isCurrentDeviceEntry(DeviceInfo d, Map<String, String> headers) {
  final fp = (headers['X-MF-Device-Fp'] ?? '').trim().toLowerCase();
  final dFp = d.deviceHwFp.trim().toLowerCase();
  if (fp.isNotEmpty && dFp.isNotEmpty) return fp == dFp;

  final model = (headers['X-MF-Device-Model'] ?? '').trim().toLowerCase();
  final brand = (headers['X-MF-Device-Brand'] ?? '').trim().toLowerCase();
  final dModel = d.deviceModel.trim().toLowerCase();
  final dBrand = d.deviceBrand.trim().toLowerCase();
  if (model.isEmpty && brand.isEmpty) return false;
  final modelHit = model.isNotEmpty && dModel.isNotEmpty && dModel == model;
  final brandHit = brand.isNotEmpty && dBrand.isNotEmpty && dBrand == brand;
  // 机型命中就够了（同名机型在不同品牌下也会被品牌条件误筛掉）
  if (modelHit) return true;
  // 机型拿不到（部分平台为空）时退化为品牌 + 在线 判定，避免完全认不出本机
  return brandHit && model.isEmpty;
}

class _DevicesPageState extends State<DevicesPage> {
  List<DeviceInfo> _devices = [];
  bool _loading = true;
  int? _deletingId;
  int? _savingRemarkId;
  String? _error; // 加载失败原因（失败≠没设备：错误态与空态分流）

  /// 是否允许删除设备（后台开关，随列表实时下发）。初值 false = 安全默认：
  /// 首屏还没拿到响应时绝不会先闪一个删除按钮出来。
  bool _allowDelete = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉取列表。[spinner] = true 时整页转圈（首屏 / 用户主动刷新）；
  /// 删除、改备注等 mutation 之后用 `spinner: false` 静默刷新：
  /// 旧实现每次都把列表换成居中 CircularProgressIndicator → 操作一次整页闪白、
  /// 滚动位置丢失、看着像卡死。
  Future<void> _load({bool spinner = true}) async {
    if (!mounted) return;
    setState(() {
      if (spinner) _loading = true;
      _error = null;
    });
    try {
      final result = await DeviceService.instance.listWithPolicy();
      // 列表与开关同一次 setState 落地：避免「列表已渲染、开关还没生效」时
      // 删除按钮闪一下再消失
      if (mounted) {
        setState(() {
          _devices = result.devices;
          _allowDelete = result.allowDelete;
        });
      }
    } catch (e) {
      if (!mounted) return;
      // 首屏/主动刷新失败 → 错误态（带重试），不要显示成「暂无设备」
      if (spinner) {
        setState(() => _error = ApiClient.errorMsg(e));
      } else {
        // 静默刷新失败：列表原样保留，只弹提示
        _toast(ApiClient.errorMsg(e));
      }
    } finally {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  Future<void> _deleteDevice(DeviceInfo device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('delete_device'), style: const TextStyle(fontSize: 16)),
        content: Text(
            isCurrentDeviceEntry(device, UserAgent.deviceHeaders)
                ? AppStrings.t('delete_self_device_body',
                    {'name': device.displayName})
                : AppStrings.t('delete_device_body',
                    {'name': device.displayName}),
            style: TextStyle(
                fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('delete'), style: TextStyle(color: MFColors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deletingId = device.id);
    try {
      await DeviceService.instance.delete(device.id);
      final wasCurrent = isCurrentDeviceEntry(device, UserAgent.deviceHeaders);
      await _load(spinner: false);
      if (!mounted) return;
      _toast(AppStrings.t('device_deleted'));
      // 删掉的如果是本机：本机已进入「已被移除」状态，拿不到订阅也连不上，
      // 唯一恢复路径是重新登录（重新登记本机）—— 当场告诉用户，别让他
      // 自己去猜为什么「更新订阅没有节点」
      if (wasCurrent) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: MFColors.card2,
            title: Text(AppStrings.t('self_deleted_title'),
                style: const TextStyle(fontSize: 16)),
            content: Text(AppStrings.t('self_deleted_body'),
                style: TextStyle(
                    fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppStrings.t('ok_btn')),
              ),
            ],
          ),
        );
      }
      // 删设备会改变设备数/名额：立刻刷新账号状态与订阅，
      // 否则「设备已达上限」的横幅与门禁会停留在旧判定上（用户删完还是连不上）
      unawaited(_refreshAccountAndSub());
    } catch (e) {
      if (mounted) {
        _toast(ApiClient.errorMsg(e));
        // 403 = 后台在我们拉完列表之后把开关关掉了（页面上的开关只是拉取时的
        // 快照）。立刻重新拉一次，把开关同步成「不可删除」：删除入口换成升级
        // 入口，别让用户对着一个已经失效的按钮反复点。
        final code = e is DioException ? e.response?.statusCode : null;
        if (code == 403) await _load(spinner: false);
      }
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  /// 删设备后刷新账号状态 + 订阅节点（设备名额释放要立刻体现出来）
  Future<void> _refreshAccountAndSub() async {
    try {
      await AccountService.instance.refresh(force: true);
      final nodes = await SubscriptionService.instance.fetchNodes(force: true);
      // 名额释放后节点可能立刻可用：同步给连接器，用户回到首页就能连
      await ConnectionController.instance.applySubscriptionNodes(nodes);
    } catch (e) {
      AppLog.error('refresh after device change failed: $e');
    }
  }

  /// 编辑设备备注（输入框；可清空）
  Future<void> _editRemark(DeviceInfo device) async {
    final controller = TextEditingController(text: device.remark);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('edit_remark'), style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 200,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: AppStrings.t('remark_hint'),
            hintStyle: TextStyle(fontSize: 13, color: MFColors.txt3),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(AppStrings.t('save'),
                style: TextStyle(color: MFColors.brandLight, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (saved == null) return; // 取消
    setState(() => _savingRemarkId = device.id);
    try {
      await DeviceService.instance.updateRemark(device.id, saved);
      await _load(spinner: false);
      if (mounted) _toast(AppStrings.t('remark_saved'));
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _savingRemarkId = null);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 加载失败态（失败 ≠ 没设备）：带「重试」的空态。
  /// 外层可滚动，后端原始错误再长也不会在 380×620 的最小窗口里顶破布局；
  /// MFEmpty 的 hint 无法限行，所以这里把原文截断（不截断的话几十行错误会把
  /// 「重试」按钮顶到屏幕外，用户连重试都点不到）。
  Widget _buildError() => LayoutBuilder(
        builder: (_, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                minHeight: box.maxHeight.isFinite ? box.maxHeight : 0),
            child: MFEmpty(
              icon: Icons.cloud_off,
              title: AppStrings.t('load_failed'),
              hint: _briefError,
              actionLabel: AppStrings.t('retry'),
              onAction: () => _load(),
            ),
          ),
        ),
      );

  /// 错误原文（截断到一行能读完的长度，避免按钮被顶出可视区）
  String get _briefError {
    final e = _error ?? '';
    return e.length > 100 ? '${e.substring(0, 100)}…' : e;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('device_manage')),
        actions: [
          TextButton(onPressed: _load, child: Text(AppStrings.t('refresh'), style: TextStyle(color: MFColors.brandLight))),
        ],
      ),
      body: SafeArea(
        child: _loading
            // 首屏用骨架屏而不是裸转圈：转圈→内容的跳变比骨架明显得多
            ? const MFListSkeleton()
            : _error != null
                ? _buildError()
                : ListView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                children: [
                  _buildUpgradeEntry(),
                  // 删除被后台关闭时补一句原因说明：让用户知道「不是按钮坏了，
                  // 是这个套餐不支持自助删除」，并给出可执行的下一步。
                  if (!_allowDelete) ...[
                    const SizedBox(height: 10),
                    _buildDeleteDisabledNotice(),
                  ],
                  const SizedBox(height: 12),
                  if (_devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 90),
                      child: MFEmpty(
                        title: AppStrings.t('no_devices'),
                        hint: AppStrings.t('no_devices_hint'),
                      ),
                    )
                  else
                    for (var i = 0; i < _devices.length; i++) ...[
                      if (i > 0) const SizedBox(height: 10),
                      _buildDeviceCard(_devices[i]),
                    ],
                ],
              ),
      ),
    );
  }

  /// 进入既有的「升级设备数量」页（顶部卡片与每台设备的按钮共用）
  void _openUpgradeDevices() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const UpgradeDevicesPage()));
  }

  /// 删除被后台关闭时的原因说明（未开启删除 → 设备卡片上只有「升级设备数量」）。
  /// 明确写清「当前套餐不支持删除设备」+ 出路，避免用户以为软件出故障。
  Widget _buildDeleteDisabledNotice() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: MFColors.amber.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MFColors.amber.withValues(alpha: .38)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 15, color: MFColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppStrings.t('device_delete_disabled_notice'),
                style:
                    TextStyle(fontSize: 11.5, color: MFColors.txt2, height: 1.5),
              ),
            ),
          ],
        ),
      );

  /// 常驻「升级设备数量」入口：无论是否超限都显示。
  /// 副文案展示当前 已用/上限 + 到期时间（升级可顺带加时长）。
  Widget _buildUpgradeEntry() {
    final sub = AccountService.instance.sub;
    final used = sub?.currentDevices ?? 0;
    final limit = sub?.deviceLimit ?? 0;
    final expire = sub?.expireTime;
    final expireText = expire == null
        ? '—'
        : formatDateYmd(expire); // 统一日期口径（见 app_theme.dart）
    final full = limit > 0 && used >= limit;
    // 删除被关闭时，这个入口就是用户换设备的唯一出路 → 用品牌色高亮强调，
    // 不再因「名额已满」切成琥珀色（否则页面里最强的视觉信号变成了告警色，
    // 而真正要引导用户点的地方反而被弱化）。
    final emphasize = !_allowDelete;
    final accent = (full && !emphasize) ? MFColors.amber : MFColors.brand;
    return GestureDetector(
      onTap: _openUpgradeDevices,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [
                accent,
                MFColors.brand.withValues(alpha: .06),
              ].map((c) => c.withValues(alpha: emphasize ? .20 : (full ? .18 : .12))).toList()),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: accent.withValues(alpha: emphasize ? .70 : .5)),
        ),
        child: Row(
          children: [
            Text(full ? '📈' : '➕', style: const TextStyle(fontSize: 17)),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.t('upgrade_devices_card'),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: MFColors.txt),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    full
                        ? AppStrings.t('device_full_upgrade_banner',
                            {'used': '$used', 'limit': '$limit'})
                        : AppStrings.t('upgrade_devices_card_sub',
                            {'used': '$used', 'limit': '$limit', 'expire': expireText}),
                    style: TextStyle(
                        fontSize: 11.5, color: MFColors.txt2, height: 1.4),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: MFColors.txt3),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCard(DeviceInfo d) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: MFColors.card, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MFColors.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                    color: MFColors.card2, borderRadius: BorderRadius.circular(11)),
                alignment: Alignment.center,
                child: Text(d.osName.isNotEmpty ? d.osName.substring(0, 1).toUpperCase() : '📱',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                              d.remark.isNotEmpty ? d.remark : d.displayName,
                              style: const TextStyle(
                                  fontSize: 14.5, fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (isCurrentDeviceEntry(d, UserAgent.deviceHeaders)) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: MFColors.brand.withValues(alpha: .14),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: MFColors.brand.withValues(alpha: .38)),
                            ),
                            child: Text(AppStrings.t('this_device'),
                                style: TextStyle(
                                    fontSize: 10,
                                    color: MFColors.brandLight,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [d.osName, d.deviceModel].where((e) => e.isNotEmpty).join(' · '),
                      style:  TextStyle(fontSize: 11, color: MFColors.txt3),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (d.online ? MFColors.green : MFColors.txt3)
                      .withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: (d.online ? MFColors.green : MFColors.txt3)
                          .withValues(alpha: .3)),
                ),
                child: Text(d.online ? AppStrings.t('online') : AppStrings.t('offline'),
                    style: TextStyle(
                        fontSize: 10,
                        color: d.online ? MFColors.green : MFColors.txt3,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              if (d.ipAddress.isNotEmpty)
                _meta('IP', d.ipAddress),
              if (d.location.isNotEmpty)
                _meta(AppStrings.t('location'), d.location),
              if (d.softwareVersion.isNotEmpty)
                _meta(AppStrings.t('version'), d.softwareVersion),
              _meta(AppStrings.t('access'), '${d.accessCount}'),
              if (d.lastSeen.isNotEmpty)
                _meta(AppStrings.t('recent'), d.lastSeen),
            ],
          ),
          const SizedBox(height: 12),
          // Wrap 而非 Row：删除入口换成「升级设备数量」后文案更长，最小窗口
          // （380 宽）下允许换行，避免 RenderFlex overflow。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ActionBtn(
                icon: Icons.edit_outlined,
                label: AppStrings.t('edit_remark_btn'),
                color: MFColors.brandLight,
                loading: _savingRemarkId == d.id,
                onTap: () => _editRemark(d),
              ),
              // 后台开关决定这里的入口：允许删除 → 删除（踢下线）；
              // 不允许 → 整个删除入口不渲染，换成「升级设备数量」。
              // 不做「禁用置灰」：灰按钮点了没反应，用户同样会以为软件坏了，
              // 而且删除是破坏性操作，宁可彻底不暴露。
              if (_allowDelete)
                _ActionBtn(
                  icon: Icons.delete_outline,
                  label: AppStrings.t('delete'),
                  color: MFColors.red,
                  loading: _deletingId == d.id,
                  onTap: () => _deleteDevice(d),
                )
              else
                _ActionBtn(
                  icon: Icons.add_circle_outline,
                  label: AppStrings.t('upgrade_devices_btn'),
                  color: MFColors.brand,
                  onTap: _openUpgradeDevices,
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 元信息一项：`键 值`。
  /// 值必须有宽度上限 + 省略号：IPv6 / 长的地理位置串在 380 宽的最小窗口里
  /// 无法换行也无法省略，会把整张卡片顶出 RenderFlex overflow（审计 P2）。
  Widget _meta(String k, String v) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 168),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$k ', style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
            Flexible(
              child: Text(v,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: MFColors.txt2,
                      fontFamily: kNumFont)),
            ),
          ],
        ),
      );
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    // InkWell + 命中区 ≥40：旧实现是 height: 34 的裸 GestureDetector ——
    // 「删除设备」这类破坏性操作的命中区偏小且没有按压反馈
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: loading ? null : onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: .3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: color))
            else
              Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
          ],
        ),
            ),
          ),
        ),
      ),
    );
  }
}
