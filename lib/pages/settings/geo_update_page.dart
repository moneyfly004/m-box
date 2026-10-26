import 'package:flutter/material.dart';

import '../../core/proxy/geo_assets.dart';
import '../../core/services/geo_update_service.dart';
import '../../core/services/update_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_row.dart';

/// 分流数据管理页（sing-box 规则集 geosite-cn.srs / geoip-cn.srs）。
///
/// 说明：两份数据随 App 构建时内置（安装包自带最新版），启动/连接全程从
/// 本地读取、零联网；本页提供「手动检查更新」——显式从官方源下载最新版
/// 存为本地副本，下次连接内核即用副本（优先级高于内置）。
class GeoUpdatePage extends StatefulWidget {
  const GeoUpdatePage({super.key});

  @override
  State<GeoUpdatePage> createState() => _GeoUpdatePageState();
}

class _GeoUpdatePageState extends State<GeoUpdatePage> {

  bool _updating = false;
  int _doneFiles = 0;
  int _totalFiles = GeoUpdateService.files.length;
  bool _hasCopy = false;
  DateTime? _updatedAt;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final copy = await GeoUpdateService.hasManualCopy(GeoUpdateService.files.first);
    final at = await GeoAssets.manualUpdatedAt();
    if (!mounted) return;
    setState(() {
      _hasCopy = copy;
      _updatedAt = at;
    });
  }

  Future<void> _update() async {
    if (_updating) return;
    setState(() {
      _updating = true;
      _doneFiles = 0;
    });
    final r = await GeoUpdateService.instance.update(onFile: (done, total) {
      if (mounted) {
        setState(() {
          _doneFiles = done;
          _totalFiles = total;
        });
      }
    });
    if (!mounted) return;
    setState(() => _updating = false);
    await _loadStatus();
    if (r.errors.isEmpty) {
      _toast(AppStrings.t('geo_update_done'));
    } else {
      _toast(AppStrings.t('geo_update_fail', {'err': r.errors.join('；')}));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    // 只留文案：背景/圆角/浮动样式统一由 ThemeData.snackBarTheme 提供
    // （旧实现这里自己又写了一套 floating + card2，和主题重复且容易走偏）
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmt(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('geo_title')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
          children: [
            _section(AppStrings.t('geo_status')),
            _row(
              icon: '🧠',
              title: AppStrings.t('geo_country_lib'),
              value: 'geoip-cn.srs',
            ),
            _row(
              icon: '🧭',
              title: AppStrings.t('geo_rules'),
              value: 'geosite-cn.srs',
            ),
            _row(
              icon: '📦',
              title: AppStrings.t('geo_builtin'),
              value: 'v${UpdateInfo.currentVersion}',
            ),
            _row(
              icon: _hasCopy ? '🟢' : '⚪',
              title: AppStrings.t('geo_manual_copy'),
              value: _updatedAt == null
                  ? AppStrings.t('geo_none')
                  : _fmt(_updatedAt!),
            ),
            const SizedBox(height: 12),
            Text(AppStrings.t('geo_tip'),
                style: TextStyle(fontSize: 11.5, color: MFColors.txt3, height: 1.6)),
            const SizedBox(height: 16),
            // 更新按钮
            GestureDetector(
              onTap: _updating ? null : _update,
              child: Container(
                height: 46,
                decoration: BoxDecoration(
                    gradient: MFColors.brandGradient,
                    borderRadius: BorderRadius.circular(13)),
                alignment: Alignment.center,
                child: _updating
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white)),
                          const SizedBox(width: 8),
                          Text(
                            AppStrings.t('geo_downloading',
                                {'pct': '$_doneFiles/$_totalFiles'}),
                            style: const TextStyle(
                                fontSize: 13,
                                color: Colors.white,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      )
                    : Text(AppStrings.t('geo_check_update'),
                        style: const TextStyle(
                            fontSize: 13.5,
                            color: Colors.white,
                            fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 12),
            Text(AppStrings.t('geo_source'),
                style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
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

  /// 统一行组件（原实现固定 height: 52，且「值」没有宽度上限和省略号，最易溢出）
  Widget _row({
    required String icon,
    required String title,
    String? desc,
    String? value,
  }) {
    return MFRow(icon: icon, title: title, desc: desc, value: value);
  }
}
