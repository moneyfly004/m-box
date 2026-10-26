import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/app_log.dart';
import '../../core/services/settings_store.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_skeleton.dart';
import '../../widgets/mf_input.dart';

/// 按 App 分流/排除（Android AccessControl）：
/// 控制哪些应用走代理（VpnService allowed/disallowed）。
/// 三种模式：全部走代理 / 仅勾选应用 / 排除勾选应用。
/// 更改即时保存；重连（或下次连接）后生效 —— 因为 TUN 路由在连接时建立。
class AccessPage extends StatefulWidget {
  const AccessPage({super.key});

  @override
  State<AccessPage> createState() => _AccessPageState();
}

class _AccessPageState extends State<AccessPage> {
  static const _channel = MethodChannel('top.mbox/vpn_core');

  List<Map<String, String>> _apps = [];
  String _mode = 'all';
  Set<String> _selected = {};
  String _query = '';
  bool _loading = true;

  /// 平台通道读取失败（区分于「读到了，但列表是空的」）。
  /// 旧实现用 `catch (_) {}` 把两类情况都吞掉，界面统一显示
  /// 「未能读取应用列表…请去系统设置开权限」—— 明明是真出错也引导用户去改权限。
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    var apps = <Map<String, String>>[];
    String? error;
    try {
      final s = await SettingsStore.instance.load();
      _mode = s['accessControlMode']?.toString() ?? 'all';
      _selected = Set<String>.from(
          (s['accessControlApps'] as List?)?.cast<String>() ?? const <String>[]);
      final raw = await _channel.invokeListMethod<Map>('getInstalledApps') ?? [];
      apps = raw
          .map((m) => {
                'package': m['package']?.toString() ?? '',
                'label': m['label']?.toString() ?? m['package']?.toString() ?? '',
              })
          .where((m) => m['package']!.isNotEmpty)
          .toList();
    } catch (e) {
      // 读取真的失败了：保留错误（页面给「读取失败 + 重试」，
      // 而不是引导用户去改权限），同时落一条日志便于排障
      error = AppStrings.t('access_load_error');
      AppLog.error('读取已安装应用列表失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loadError = error;
      _loading = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    // 只留文案：背景/圆角/浮动样式统一由 ThemeData.snackBarTheme 提供
    // （旧实现这里自己又写了一套 floating + card2，和主题重复且容易走偏）
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    try {
      await SettingsStore.instance.update((s) {
        s['accessControlMode'] = _mode;
        s['accessControlApps'] = _selected.toList();
      });
    } catch (_) {
      _toast(AppStrings.t('save_failed'));
    }
  }

  void _setMode(String m) {
    setState(() => _mode = m);
    _save();
  }

  void _toggle(String pkg) {
    setState(() {
      if (!_selected.add(pkg)) _selected.remove(pkg);
    });
    _save();
  }

  List<Map<String, String>> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _apps;
    return _apps
        .where((a) =>
            a['label']!.toLowerCase().contains(q) ||
            a['package']!.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _reconnect() async {
    final conn = ConnectionController.instance;
    if (conn.status != ConnStatus.connected) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MBColors.card2,
        title: Text(AppStrings.t('access_reconnect_btn'),
            style: const TextStyle(fontSize: 16)),
        content: Text(AppStrings.t('access_saved_tip'),
            style: TextStyle(fontSize: 13.5, color: MBColors.txt2)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('access_reconnect_btn'),
                style: TextStyle(color: MBColors.brand)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await conn.disconnect();
    await conn.connect();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('access_title')),
        actions: [
          // 「重连生效」必须跟随连接状态刷新：旧实现在 build 里直接读
          // ConnectionController.instance.status 的快照，连上/断开后这一格
          // 一直是旧值（该亮的灰着、该灰的亮着）。只包这一个动作，
          // 不让整页跟着控制器的其它通知（测速/流量）重建。
          ListenableBuilder(
            listenable: ConnectionController.instance,
            builder: (context, _) {
              final connected =
                  ConnectionController.instance.status == ConnStatus.connected;
              // 动作必须**限宽**：英文文案（Saved · applies after reconnect or
              // next connection）在 380 宽的最小窗口下会把 AppBar 的 actions
              // 撑出 RenderFlex overflow（Ahem 下实测 224px）。这里限到 132，
              // 超出省略 —— 完整说明本来就写在下方统计行里。
              return SizedBox(
                width: 132,
                child: TextButton(
                  // 未连接时无事可做：不可点，而不是点了没反应的按钮
                  onPressed: connected ? _reconnect : null,
                  child: Text(
                      connected
                          ? AppStrings.t('access_reconnect_btn')
                          : AppStrings.t('access_saved_tip'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: connected ? MBColors.brand : MBColors.txt3)),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(AppStrings.t('access_desc'),
                  style: TextStyle(
                      fontSize: 11.5, color: MBColors.txt3, height: 1.6)),
            ),
            const SizedBox(height: 10),
            // 模式选择：外层用 Material（而不是实色 Container）承接 Ink 的
            // 渐变与按压水波纹 —— 否则它们会被实色底盖住，看着像没反应
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Material(
                color: MBColors.card2,
                borderRadius: BorderRadius.circular(11),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Row(
                    children: [
                      _modeBtn('all', AppStrings.t('access_mode_all')),
                      _modeBtn('selected', AppStrings.t('access_mode_selected')),
                      _modeBtn('denied', AppStrings.t('access_mode_denied')),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: MBColors.brand.withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: MBColors.brand.withValues(alpha: .18)),
                ),
                child: Text(
                  switch (_mode) {
                    'selected' => AppStrings.t('access_hint_selected'),
                    'denied' => AppStrings.t('access_hint_denied'),
                    _ => AppStrings.t('access_hint_all'),
                  },
                  style: TextStyle(
                      fontSize: 11,
                      color: MBColors.txt2,
                      height: 1.5),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Text(
                '${AppStrings.t('access_sel_count', {'n': '${_selected.length}'})}'
                ' · ${AppStrings.t('access_saved_tip')}',
                style: TextStyle(fontSize: 10.5, color: MBColors.txt3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: SizedBox(
                height: 44,
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(fontSize: 13.5, color: MBColors.txt),
                  decoration: mfInput(hint: AppStrings.t('access_search_hint'))
                      .copyWith(
                    prefixIcon: Icon(Icons.search,
                        size: 17, color: MBColors.txt3),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  ),
                ),
              ),
            ),
            Expanded(child: _listArea()),
          ],
        ),
      ),
    );
  }

  /// 列表区：加载中 / 读取失败（可重试）/ 空（无应用或搜索无结果）/ 应用列表
  Widget _listArea() {
    if (_loading) {
      // 骨架屏而不是裸转圈：转圈→内容的跳变比骨架明显得多（与其它列表页统一）
      return const MBListSkeleton(rows: 4);
    }
    final err = _loadError;
    if (err != null) {
      // 真·读取失败 → 可重试（与「读到了但列表为空」区分开）
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('⚠️', style: TextStyle(fontSize: 24)),
              const SizedBox(height: 10),
              Text(err,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12, color: MBColors.txt2, height: 1.7)),
              const SizedBox(height: 6),
              TextButton(onPressed: _init, child: Text(AppStrings.t('retry'))),
            ],
          ),
        ),
      );
    }
    if (_filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Text(
            _apps.isEmpty
                ? AppStrings.t('access_empty_perm')
                : AppStrings.t('access_none'),
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 12, color: MBColors.txt3, height: 1.7),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
      itemCount: _filtered.length,
      itemBuilder: (context, i) {
        final app = _filtered[i];
        final pkg = app['package']!;
        final label = app['label']!;
        final checked = _mode == 'selected' || _mode == 'denied'
            ? _selected.contains(pkg)
            : false;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
              color: checked
                  ? MBColors.brand.withValues(alpha: .06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10)),
          child: CheckboxListTile(
            value: checked,
            activeColor: MBColors.brand,
            dense: true,
            controlAffinity: ListTileControlAffinity.trailing,
            onChanged: _mode == 'all' ? null : (_) => _toggle(pkg),
            title: Text(label,
                style: TextStyle(fontSize: 13.5, color: MBColors.txt)),
            subtitle: Text(pkg,
                style: TextStyle(fontSize: 9.5, color: MBColors.txt3)),
          ),
        );
      },
    );
  }

  /// 模式按钮：命中区至少 40 高 + InkWell 按压反馈
  /// （旧实现是 GestureDetector + 内边距 8 的 Container ≈ 30 高：没有按压反馈、
  /// 命中区偏小；这里用 Ink 把渐变画在 Material 上，水波纹才看得见）
  Widget _modeBtn(String mode, String label) {
    final active = _mode == mode;
    final radius = BorderRadius.circular(8);
    return Expanded(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Ink(
          decoration: BoxDecoration(
            gradient: active ? MBColors.brandGradient : null,
            borderRadius: radius,
          ),
          child: InkWell(
            onTap: () => _setMode(mode),
            borderRadius: radius,
            child: Center(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : MBColors.txt3),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
