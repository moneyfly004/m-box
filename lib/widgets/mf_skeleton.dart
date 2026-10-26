import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 列表页/详情页统一的「骨架屏」占位块（配色与套餐页的骨架一致）。
///
/// 背景：审计发现加载态两种风格混用 —— 只有套餐页有骨架屏，订单/设备/通知/
/// 升级设备/日志中心都是裸的居中转圈。裸转圈的问题是「转圈 → 内容」的跳变比
/// 骨架屏明显得多，页面看起来在闪。
///
/// 用法（列表页）：
/// ```dart
/// if (_loading) return const MBListSkeleton(rows: 4);
/// ```
class MBSkeletonBlock extends StatelessWidget {
  const MBSkeletonBlock({super.key, this.width, this.height = 12, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: MBColors.card2,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 通用「一行卡片」骨架：左侧两行文字 + 右侧一个小方块（与真实列表行同高同圆角）
class MBSkeletonRow extends StatelessWidget {
  const MBSkeletonRow({super.key, this.trailingWidth = 54});

  final double trailingWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        color: MBColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MBColors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                MBSkeletonBlock(width: 120, height: 15),
                SizedBox(height: 8),
                MBSkeletonBlock(width: 180, height: 11),
              ],
            ),
          ),
          const SizedBox(width: 12),
          MBSkeletonBlock(width: 54, height: 22),
        ],
      ),
    );
  }
}

/// 列表页骨架（[rows] 行卡片 + 可选顶部标题占位），不可滚动（加载中不需要滚动）
class MBListSkeleton extends StatelessWidget {
  const MBListSkeleton({super.key, this.rows = 4, this.padding = const EdgeInsets.fromLTRB(18, 12, 18, 24)});

  final int rows;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      children: [
        for (var i = 0; i < rows; i++) const MBSkeletonRow(),
      ],
    );
  }
}
