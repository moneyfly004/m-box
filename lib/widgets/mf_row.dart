import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// MBox 设置类页面统一的「一行」：图标 + 标题 +（可选）值/箭头/开关 +（可选）描述。
///
/// ## 为什么要有这个组件（而不是每页各写一份）
/// 这个「一行」在 `settings_page.dart` / `kernel_page.dart` / `geo_update_page.dart`
/// 里被复制了三份，而且都写成 `Container(height: 52)` —— **固定高度 + 内部可换行
/// 的标题/描述**。在应用允许的最小窗口（380×620）下实测：
///   · 一行里「值」最多占 150px、图标 28px、箭头 17px，留给「标题 + 描述」的
///     宽度只有 ~94px；
///   · 英文描述（如 DNS / 订阅 UA 说明）在 94px 里要折成十几行 → 一次设置页
///     停留就抛出 **37 次 RenderFlex overflow**（中文也会，不只是英文）；
///   · `geo_update_page.dart` 的那份连值的宽度上限和省略号都没有，更糟。
///
/// ## 现在的约定
///   · 行高是**最小高度**（52），内容多就自己长高，不裁切、不溢出；
///   · 标题单行省略；描述**独占一整行**（不再和值挤同一行），最多两行省略；
///   · 值最多 [valueMaxWidth]，必要时可被压缩，箭头位置保持稳定。
///
/// 新增设置项请直接用它，不要再复制粘贴一份固定高度的 Row。
class MBRow extends StatelessWidget {
  const MBRow({
    super.key,
    required this.icon,
    required this.title,
    this.desc,
    this.value,
    this.trailing,
    this.danger = false,
    this.showDot = false,
    this.onTap,
    this.valueMaxWidth = 150,
  });

  /// 左侧图标字符（emoji / 符号）
  final String icon;

  /// 主标题（单行省略）
  final String title;

  /// 描述：独占一行，最多两行（可选）
  final String? desc;

  /// 右侧值（可选）
  final String? value;

  /// 行尾自定义控件（如 Switch）
  final Widget? trailing;

  /// 危险项（红色图标/标题）
  final bool danger;

  /// 值前面是否显示红点（有新内容提示）
  final bool showDot;

  final VoidCallback? onTap;

  /// 值的宽度上限；有描述时建议传小一点（默认 150，带描述的行会被压到 110）
  final double valueMaxWidth;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    final hasDesc = desc != null && desc!.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: MBColors.card,
        borderRadius: radius,
        border: Border.all(color: MBColors.line),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          child: LayoutBuilder(builder: (context, c) {
            // 行尾控件（分段开关等）必须能被压缩：旧实现里 trailing 是非 flex 子项，
            // 会被按「无限宽」测量 —— 英文标签下它实测占 284px，把标题挤成 **0 宽**
            // （整行溢出 19px，标题完全看不见）。这里给出上限：最多吃 55%，
            // 标题永远至少留 45%。
            final maxTrailing = (c.maxWidth - 39) * .55;
            return ConstrainedBox(
              // 单行行 = 24 + 28 = 52（与旧版视觉一致）；有描述时自然长高，不再溢出
              constraints: const BoxConstraints(minHeight: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                            color: danger
                                ? MBColors.red.withValues(alpha: .12)
                                : MBColors.card2,
                            borderRadius: BorderRadius.circular(9)),
                        alignment: Alignment.center,
                        child: Text(icon, style: const TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: danger ? MBColors.red : MBColors.txt)),
                      ),
                      if (value != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                                maxWidth:
                                    hasDesc ? valueMaxWidth * .73 : valueMaxWidth),
                            child: Text(value!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                                textAlign: TextAlign.end,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: MBColors.txt3,
                                    fontFamily: kNumFont)),
                          ),
                        ),
                      ],
                      if (showDot) ...[
                        const SizedBox(width: 5),
                        const RedDot(size: 7),
                      ],
                      if (value != null || onTap != null) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, size: 17, color: MBColors.txt3),
                      ],
                      if (trailing != null) ...[
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: maxTrailing),
                          child: trailing!,
                        ),
                      ],
                    ],
                  ),
                  if (hasDesc)
                    Padding(
                      // 左对齐到标题（图标 28 + 间距 11）
                      padding: const EdgeInsets.only(left: 39, top: 4),
                      child: Text(desc!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10, height: 1.35, color: MBColors.txt3)),
                    ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}
