import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// MBox 统一空态组件：图标 + 主文案 +（可选）次要文案 +（可选）操作按钮。
///
/// 深色/浅色主题都适用（颜色取 [MBColors]，随 ThemeController 自动切换）。
/// 典型用法（列表页无数据）：
/// ```dart
/// MBEmpty(title: AppStrings.t('no_orders'), hint: AppStrings.t('no_orders_hint'))
/// ```
/// 需要引导操作时（如错误态带「重试」）：
/// ```dart
/// MBEmpty(
///   icon: Icons.cloud_off,
///   title: '...',
///   actionLabel: AppStrings.t('retry'),
///   onAction: _load,
/// )
/// ```
class MBEmpty extends StatelessWidget {
  const MBEmpty({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.title,
    this.hint,
    this.actionLabel,
    this.onAction,
  });

  /// 空态主图标（默认收件箱）
  final IconData icon;

  /// 主文案（如「暂无订单」）
  final String title;

  /// 次要说明文案
  final String? hint;

  /// 操作按钮文案（与 [onAction] 同时给出才渲染按钮）
  final String? actionLabel;

  /// 操作按钮点击回调（如「重试」触发重新加载）
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final showAction = actionLabel != null && onAction != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: MBColors.txt3),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: MBColors.txt3),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: MBColors.txt3),
              ),
            ],
            if (showAction) ...[
              const SizedBox(height: 20),
              GestureDetector(
                onTap: onAction,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 11),
                  decoration: BoxDecoration(
                    gradient: MBColors.brandGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    actionLabel!,
                    style: const TextStyle(
                        fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
