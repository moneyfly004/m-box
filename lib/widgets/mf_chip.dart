import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// MBox 统一的小控件（筛选/分段/行内操作按钮）。
///
/// ## 为什么要有它
/// UI 审计发现全项目 13 处小控件都是 `GestureDetector` + 只有 5~9px 垂直内边距的
/// 小 `Container`：命中区普遍 20~36px（低于 40px 的可点下限），而且**没有任何
/// 按压反馈**（没有 ink ripple）。它们里面包含「删除设备」「取消订单」「删除
/// bypass 条目」「单节点测速」这类破坏性或状态性操作 —— 触屏笔记本和手机上误触
/// 代价很高。
///
/// ## 约定
/// - 视觉大小由 [dense] / 内边距决定，**可点区域恒 ≥40px 高**
///   （用 [ConstrainedBox] 撑开，多余部分透明）；
/// - 一律用 `InkWell`，有按压反馈；
/// - 禁用态必须看得出来（[enabled] = false → card2 底 + txt3 字 + 无边框高亮）。
class MBChip extends StatelessWidget {
  const MBChip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.selected = false,
    this.enabled = true,
    this.dense = false,
    this.color,
    this.tooltip,
    this.busy = false,
  });

  /// 文案（已本地化）
  final String label;

  /// 可选前置图标
  final IconData? icon;

  /// 点击回调；为 null 或 [enabled] = false 时不可点
  final VoidCallback? onTap;

  /// 选中态（品牌色高亮）
  final bool selected;

  /// 是否可用（false 时明显置灰且不可点）
  final bool enabled;

  /// 紧凑尺寸（视觉更小，命中区仍是 40px）
  final bool dense;

  /// 自定义主色（默认品牌色）
  final Color? color;

  final String? tooltip;

  /// 进行中（刷新/测速）：前置位置显示小转圈，配合 [enabled] = false 防连点
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = color ?? MBColors.brand;
    final active = enabled && selected;
    final fg = !enabled
        ? MBColors.txt3
        : (active ? c : MBColors.txt2);
    final visual = Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 9 : 11, vertical: dense ? 5 : 7),
      decoration: BoxDecoration(
        color: active ? c.withValues(alpha: .18) : (enabled ? MBColors.card2 : MBColors.card2.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(dense ? 9 : 11),
        border: Border.all(
            color: active ? c.withValues(alpha: .65) : MBColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            SizedBox(
              width: dense ? 13 : 15,
              height: dense ? 13 : 15,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: fg),
            ),
            const SizedBox(width: 5),
          ] else if (icon != null) ...[
            Icon(icon, size: dense ? 13 : 15, color: fg),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: dense ? 11.5 : 12.5,
                    fontWeight: FontWeight.w600,
                    color: fg)),
          ),
        ],
      ),
    );
    // 命中区撑到 40px 高（视觉不变）；InkWell 提供按压反馈
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Center(widthFactor: 1, heightFactor: 1, child: visual),
    );
    final tappable = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(dense ? 9 : 11),
        onTap: enabled ? onTap : null,
        child: content,
      ),
    );
    return tooltip == null ? tappable : Tooltip(message: tooltip!, child: tappable);
  }
}

/// 列表行里的文字操作按钮（取消订单 / 再次支付 / 删除设备 / 重试 等）。
/// 与 [MBChip] 的区别：没有底色边框，像链接式按钮，但命中区同样 ≥40px。
class MBActionButton extends StatelessWidget {
  const MBActionButton({
    super.key,
    required this.label,
    this.onTap,
    this.enabled = true,
    this.filled = false,
    this.color,
  });

  final String label;
  final VoidCallback? onTap;
  final bool enabled;

  /// true = 品牌渐变实心按钮；false = 文字按钮
  final bool filled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? MBColors.brand;
    final fg = enabled ? (filled ? Colors.white : c) : MBColors.txt3;
    final visual = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        gradient: filled && enabled ? MBColors.brandGradient : null,
        // 非实心：用主色的极淡底（原「取消订单」按钮就是这个观感）；禁用时置灰
        color: filled && enabled
            ? null
            : (enabled ? c.withValues(alpha: .08) : MBColors.card2),
        borderRadius: BorderRadius.circular(10),
        border: filled
            ? null
            : Border.all(
                color: enabled ? c.withValues(alpha: .3) : MBColors.line),
      ),
      child: Text(label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg)),
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Center(widthFactor: 1, heightFactor: 1, child: visual),
        ),
      ),
    );
  }
}
