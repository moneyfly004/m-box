import 'package:flutter/material.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/kernel_manager.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_row.dart';

/// 内核管理页：显示当前内置 mihomo 版本、官方最新版本；
/// 桌面端可直接下载官方预编译内核并替换（FlClash 同款能力）。
class KernelPage extends StatefulWidget {
  const KernelPage({super.key});

  @override
  State<KernelPage> createState() => _KernelPageState();
}

class _KernelPageState extends State<KernelPage> {

  String? _current;
  String? _latest;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  String? _error;
  bool _supportsVariant = false;
  bool _hasUserKernel = false;
  bool _restoring = false; // 恢复内置是本地删除,不显示「下载中」
  KernelVariant _variant = KernelVariant.compatible;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cur = await KernelManager.instance.detectCurrent();
    final supports = await KernelManager.supportsVariant;
    final variant = await KernelManager.instance.currentVariant();
    final hasUser = await KernelManager.hasUserKernel();
    if (!mounted) return;
    setState(() {
      _current = cur;
      _supportsVariant = supports;
      _variant = variant;
      _hasUserKernel = hasUser;
    });
    if (KernelManager.isDesktop) {
      await _check();
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final latest = await KernelManager.instance.fetchLatest();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _latest = latest;
      if (latest == null) {
        _error = AppStrings.t('kernel_fetch_latest_fail', {'err': 'network'});
      }
    });
  }

  bool get _hasNewer {
    final c = _current, l = _latest;
    if (c == null || l == null) return false;
    return KernelManager.compare(l, c) > 0;
  }

  Future<void> _update() async {
    final latest = _latest;
    if (latest == null || _downloading) return;
    await _downloadAndApply(latest, null,
        doneMsg: () => AppStrings.t('kernel_download_done', {'ver': latest}),
        onApplied: () => setState(() => _current = latest));
  }

  /// 下载 + 替换 二阶段统一流程（更新版本与切换变体共用）：
  /// 1) 下载到缓存 —— **连接中也可以**（KernelManager 已连接时经隧道下载，
  ///    内核托管在 GitHub，国内直连拉不动，「先连上再更新」才是主路径）；
  /// 2) 替换生效 —— 必须内核已停止：未连接直接替换；连接中询问用户
  ///    「立即断开替换并自动重连」或「稍后手动断开再来」。
  Future<void> _downloadAndApply(String version, KernelVariant? variant,
      {required String Function() doneMsg, VoidCallback? onApplied}) async {
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    final dl = await KernelManager.instance
        .downloadToCache(version, variant: variant, onProgress: (p) {
      if (mounted) setState(() => _progress = p);
    });
    if (!mounted) return;
    if (dl.isNotEmpty) {
      setState(() => _downloading = false);
      _toast(AppStrings.t('kernel_update_fail', {'err': dl}));
      return;
    }

    // 已下载完毕。连接中 → 询问是否断开替换并自动重连
    final conn = ConnectionController.instance;
    var reconnectAfter = false;
    if (conn.status == ConnStatus.connected) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: MFColors.card2,
          title: Text(AppStrings.t('kernel_apply_now_title'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: Text(AppStrings.t('kernel_apply_now_text'),
              style:
                  TextStyle(fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(AppStrings.t('kernel_apply_later'))),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.t('kernel_apply_now'),
                  style: TextStyle(
                      color: MFColors.brandLight, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice != true) {
        // 稍后替换：缓存已就位，用户手动断开后再来本页秒切
        setState(() => _downloading = false);
        _toast(AppStrings.t('kernel_apply_later_tip'));
        return;
      }
      reconnectAfter = true;
      await conn.disconnect();
      if (!mounted) return;
    }

    final err =
        await KernelManager.instance.activateCached(version, variant: variant);
    if (!mounted) return;
    setState(() => _downloading = false);
    if (err.isEmpty) {
      onApplied?.call();
      _toast(doneMsg());
      if (reconnectAfter) {
        // 用新内核自动重连（失败由连接层的错误引导兜底）
        await conn.connect();
      }
    } else if (err == 'kernel_running') {
      _toast(AppStrings.t('kernel_update_desc'));
    } else {
      _toast(AppStrings.t('kernel_update_fail', {'err': err}));
    }
  }

  /// 切换内核变体(兼容版<->标准版)：下载「当前版本」的另一变体并替换。
  /// 缓存命中(该 变体×版本 已下载过) → 本地直接生效,不再下载。
  /// 连接中允许发起：下载走隧道,替换前询问断开(与更新版本同一流程)。
  Future<void> _switchVariant(KernelVariant v) async {
    if (_downloading || v == _variant) return;
    final ver = _current;
    if (ver == null) {
      _toast(AppStrings.t('kernel_version_unknown'));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('kernel_switch_title'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(AppStrings.t('kernel_switch_confirm', {
          'label': _variantLabel(v),
        }), style: TextStyle(fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('confirm'),
                style: TextStyle(color: MFColors.brandLight, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _downloadAndApply(ver, v,
        doneMsg: () =>
            AppStrings.t('kernel_switch_done', {'label': _variantLabel(v)}),
        onApplied: () {
          // 变体偏好仅在真正替换成功后才落盘：替换失败时保持旧偏好,
          // 避免「偏好=标准版、实际生效=兼容版」的错位
          KernelManager.instance.setVariant(v);
          setState(() {
            _variant = v;
            _hasUserKernel = true;
          });
        });
  }

  String _variantLabel(KernelVariant v) => v == KernelVariant.compatible
      ? AppStrings.t('kernel_variant_compatible')
      : AppStrings.t('kernel_variant_standard');

  /// 点击「内核变体」→ 下拉选择：兼容版 / 标准版 / (有用户副本时)恢复内置
  Future<void> _pickVariant() async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MFColors.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Text(AppStrings.t('kernel_variant_title'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _sheetOption(
              label: _variantLabel(KernelVariant.compatible),
              desc: AppStrings.t('kernel_variant_compatible_desc'),
              selected: _variant == KernelVariant.compatible,
              value: 'compatible',
            ),
            _sheetOption(
              label: _variantLabel(KernelVariant.standard),
              desc: AppStrings.t('kernel_variant_standard_desc'),
              selected: _variant == KernelVariant.standard,
              value: 'standard',
            ),
            if (_hasUserKernel) ...[
              Divider(height: 1, color: MFColors.line),
              _sheetOption(
                label: AppStrings.t('kernel_restore_builtin'),
                desc: AppStrings.t('kernel_restore_builtin_desc'),
                selected: false,
                value: 'restore',
                danger: true,
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (pick == null || !mounted) return;
    if (pick == 'compatible') {
      await _switchVariant(KernelVariant.compatible);
    } else if (pick == 'standard') {
      await _switchVariant(KernelVariant.standard);
    } else if (pick == 'restore') {
      await _restoreKernel();
    }
  }

  Widget _sheetOption({
    required String label,
    required String desc,
    required bool selected,
    required String value,
    bool danger = false,
  }) {
    return InkWell(
      onTap: () => Navigator.pop(context, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: danger ? MFColors.red : MFColors.txt)),
                  const SizedBox(height: 2),
                  Text(desc,
                      style: TextStyle(
                          fontSize: 11, color: MFColors.txt3, height: 1.4)),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, size: 18, color: MFColors.brandLight),
          ],
        ),
      ),
    );
  }

  /// 恢复安装包内置内核（删除用户副本，无需下载）。
  /// 连接中不允许：正在运行的就是用户副本，macOS 删除后重连即失败、
  /// Windows 文件被锁删除静默失败 —— 都会造成状态错乱，必须先断开。
  Future<void> _restoreKernel() async {
    if (_downloading) return;
    if (ConnectionController.instance.status != ConnStatus.disconnected) {
      _toast(AppStrings.t('kernel_update_desc'));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('kernel_restore_builtin'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(AppStrings.t('kernel_restore_confirm'),
            style: TextStyle(fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('confirm'),
                style: TextStyle(color: MFColors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _restoring = true);
    final done = await KernelManager.restoreBuiltin();
    final builtinV = await KernelManager.builtinVariantForPlatform();
    await KernelManager.instance.setVariant(builtinV);
    final cur = await KernelManager.instance.detectCurrent();
    if (!mounted) return;
    setState(() {
      _restoring = false;
      _hasUserKernel = false;
      _variant = builtinV;
      _current = cur;
    });
    _toast(done
        ? AppStrings.t('kernel_restore_done')
        : AppStrings.t('kernel_update_fail', {'err': 'restore'}));
  }

  void _toast(String msg) {
    if (!mounted) return;
    // 只留文案：背景/圆角/浮动样式统一由 ThemeData.snackBarTheme 提供
    // （旧实现这里自己又写了一套 floating + card2，和主题重复且容易走偏）
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('kernel_title')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
          children: [
            _section(AppStrings.t('settings_kernel')),
            _row(
              icon: '🧩',
              title: AppStrings.t('kernel_current'),
              value: _current == null
                  ? AppStrings.t('kernel_version_unknown')
                  : 'v$_current',
            ),
            // 「运行中 / 未连接」必须跟随连接状态刷新：旧实现直接读
            // ConnectionController.instance.status 的快照，连上或断开后
            // 这一行不会更新（只有这一行需要重建，所以只包这一行，
            // 不让整页跟着通知抖动）
            ListenableBuilder(
              listenable: ConnectionController.instance,
              builder: (context, _) {
                final running = ConnectionController.instance.status ==
                    ConnStatus.connected;
                return _row(
                  icon: '⚡',
                  title: AppStrings.t('kernel_running_state'),
                  value: running
                      ? AppStrings.t('kernel_running')
                      : AppStrings.t('kernel_stopped'),
                );
              },
            ),
            if (KernelManager.isDesktop) ...[
              _section('sing-box'),
              if (_checking)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                )
              else ...[
                _row(
                  icon: '🆕',
                  title: AppStrings.t('kernel_latest'),
                  value: _latest == null
                      ? AppStrings.t('kernel_version_unknown')
                      : 'v$_latest',
                  onTap: _check,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
                    child: Text(_error!,
                        style: TextStyle(
                            fontSize: 11, color: MFColors.red)),
                  ),
                if (_hasNewer)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    child: _row(
                      icon: '⬇️',
                      title: AppStrings.t('kernel_new_found', {'ver': '$_latest'}),
                      desc: AppStrings.t('kernel_update_desc'),
                      onTap: _downloading ? null : _update,
                    ),
                  )
                else if (_current != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                    child: Text(
                        AppStrings.t('kernel_up_to_date', {'ver': '$_current'}),
                        style: TextStyle(
                            fontSize: 12, color: MFColors.txt2)),
                  ),
                if (_downloading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            AppStrings.t('kernel_downloading',
                                {'pct': (_progress * 100).round().toString()}),
                            style: TextStyle(
                                fontSize: 12, color: MFColors.txt2)),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: _progress,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                          backgroundColor: MFColors.card2,
                        ),
                      ],
                    ),
                  ),
              ],
              if (_restoring)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Text(AppStrings.t('kernel_restoring'),
                          style: TextStyle(fontSize: 12, color: MFColors.txt2)),
                    ],
                  ),
                ),
              if (_supportsVariant)
                _row(
                  icon: '🔀',
                  title: AppStrings.t('kernel_variant_title'),
                  desc: AppStrings.t('kernel_variant_desc'),
                  // 行尾本来就由 MFRow 追加 chevron_right 箭头；
                  // 以前值里再拼一个 ' ▾'，同一行出现两个互相打架的指示符
                  value: _variantLabel(_variant),
                  onTap: _downloading ? null : _pickVariant,
                ),
            ] else ...[
              // Android：内核随 App 发布
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                child: Text(
                  AppStrings.t('kernel_android_ver',
                      {'ver': _current == null ? '?' : 'v$_current'}),
                  style: TextStyle(fontSize: 13, color: MFColors.txt),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Text(
                  AppStrings.t('kernel_android_update_tip'),
                  style: TextStyle(fontSize: 11.5, color: MFColors.txt3),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(AppStrings.t('kernel_source'),
                style: TextStyle(
                    fontSize: 10.5, color: MFColors.txt3)),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Text(title,
          style: TextStyle(
              fontSize: 11,
              color: MFColors.txt3,
              fontWeight: FontWeight.w700,
              letterSpacing: 2)),
    );
  }

  /// 统一行组件（原实现固定 height: 52，最小窗口下描述会被裁切并抛 overflow）
  Widget _row({
    required String icon,
    required String title,
    String? desc,
    String? value,
    VoidCallback? onTap,
  }) {
    return MFRow(icon: icon, title: title, desc: desc, value: value, onTap: onTap);
  }
}
