import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/notification_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_skeleton.dart';
import '../../widgets/mf_empty.dart';

/// 通知中心：列表 / 已读 / 全部已读 / 删除
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  List<AppNotification> _items = [];
  bool _loading = true;
  String? _error; // 加载失败原因(失败≠没通知,展示错误+重试)

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉取列表。[spinner] = true 时整页转圈（首屏 / 用户主动刷新）；
  /// mutation 之后用 `spinner: false` 静默刷新：旧实现每次都把列表换成居中
  /// CircularProgressIndicator → 改一条就整页闪白、滚动位置丢失、看着像卡死。
  Future<void> _load({bool spinner = true}) async {
    if (!mounted) return;
    setState(() {
      if (spinner) _loading = true;
      _error = null;
    });
    try {
      final list = await NotificationService.instance.list();
      if (mounted) setState(() => _items = list);
    } catch (e) {
      if (!mounted) return;
      // 静默刷新失败：列表原样保留，只弹提示（不要用错误页顶掉已有内容）
      if (spinner) {
        setState(() => _error = ApiClient.errorMsg(e));
      } else {
        _toast(ApiClient.errorMsg(e));
      }
    } finally {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  Future<void> _markRead(AppNotification n) async {
    if (n.isRead) return;
    try {
      await NotificationService.instance.markRead(n.id);
      await _load(spinner: false);
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  Future<void> _markAll() async {
    try {
      await NotificationService.instance.markAllRead();
      await _load(spinner: false);
      if (mounted) _toast(AppStrings.t('marked_read'));
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  Future<void> _delete(AppNotification n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MBColors.card2,
        title: Text(AppStrings.t('delete_notify'), style: TextStyle(fontSize: 16)),
        content:  Text(AppStrings.t('delete_notify_body'), style: TextStyle(fontSize: 13.5, color: MBColors.txt2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('delete'), style: TextStyle(color: MBColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await NotificationService.instance.delete(n.id);
      await _load(spinner: false);
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  /// 兼容后端两种时间格式：RFC3339(带T) 与 "YYYY-MM-DD HH:mm:ss"
  static String _formatTime(String raw) {
    if (raw.isEmpty) return '';
    if (raw.contains('T')) {
      final dt = DateTime.tryParse(raw);
      if (dt != null) {
        final m = dt.month.toString().padLeft(2, '0');
        final d = dt.day.toString().padLeft(2, '0');
        final h = dt.hour.toString().padLeft(2, '0');
        final min = dt.minute.toString().padLeft(2, '0');
        return '$m-$d $h:$min';
      }
    }
    return raw.length > 16 ? raw.substring(5, 16) : raw;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 错误态（失败 ≠ 没通知）：外层可滚动 + 错误文本限行，
  /// 后端原始错误再长也不会在 380×620 的最小窗口里顶破布局。
  Widget _buildError() => LayoutBuilder(
        builder: (_, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                minHeight: box.maxHeight.isFinite ? box.maxHeight : 0),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 40, color: MBColors.txt3),
                    const SizedBox(height: 10),
                    Text(AppStrings.t('load_failed'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13.5, color: MBColors.txt2, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: MBColors.txt3, height: 1.5)),
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () => _load(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                        decoration: BoxDecoration(
                            gradient: MBColors.brandGradient,
                            borderRadius: BorderRadius.circular(12)),
                        child: Text(AppStrings.t('retry'),
                            style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('notify_center')),
        actions: [
          if (_items.any((n) => !n.isRead))
            TextButton(onPressed: _markAll, child: Text(AppStrings.t('mark_all_read'), style: TextStyle(color: MBColors.brandLight))),
        ],
      ),
      body: SafeArea(
        child: _loading
            // 首屏用骨架屏而不是裸转圈：转圈→内容的跳变比骨架明显得多
            ? const MBListSkeleton()
            : _error != null
                ? _buildError()
                : _items.isEmpty
                ? MBEmpty(title: AppStrings.t('no_notifications'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final n = _items[i];
                      return GestureDetector(
                        onTap: () => _markRead(n),
                        onLongPress: () => _delete(n), // 长按保留为快捷方式
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: n.isRead ? MBColors.card : MBColors.brand.withValues(alpha: .07),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                                color: n.isRead ? MBColors.line : MBColors.brand.withValues(alpha: .35)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (!n.isRead) ...[
                                    Container(
                                      width: 7, height: 7,
                                      decoration: BoxDecoration(color: MBColors.brandLight, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 7),
                                  ],
                                  Expanded(
                                    child: Text(n.title,
                                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600,
                                            color: n.isRead ? MBColors.txt2 : MBColors.txt)),
                                  ),
                                  Text(_formatTime(n.createdAt),
                                      style:  TextStyle(fontSize: 10, color: MBColors.txt3, fontFamily: kNumFont)),
                                  // 可见的删除入口：桌面端没有长按手势，
                                  // 只靠 onLongPress 等于藏起来（长按仍可用）。
                                  // 点击区做到 ~35×35，触屏仍可长按。
                                  Tooltip(
                                    message: AppStrings.t('delete_notify'),
                                    child: GestureDetector(
                                      // 内层接管点击 → 外层的「标记已读」不会连带触发
                                      onTap: () => _delete(n),
                                      behavior: HitTestBehavior.opaque,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                            left: 12, top: 9, bottom: 9, right: 6),
                                        child: Icon(Icons.delete_outline, size: 17, color: MBColors.txt3),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (n.content.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(n.content,
                                    style:  TextStyle(fontSize: 12.5, color: MBColors.txt2, height: 1.6)),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
