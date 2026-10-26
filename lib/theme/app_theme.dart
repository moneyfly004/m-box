import 'package:flutter/material.dart';

import 'theme_controller.dart';

/// 完整「外观模式」：一套完整配色（背景/卡片/文字/品牌/边框）。
/// 每个模式自带明暗属性（isDark）：浅色模式用浅色卡片 + 深色文字，
/// 深色模式用深色卡片 + 浅色文字 —— 6 套模式整套切换，而非只换品牌色。
class MBTheme {
  const MBTheme({
    required this.isDark,
    required this.bg,
    required this.bg2,
    required this.card,
    required this.card2,
    required this.txt,
    required this.txt2,
    required this.txt3,
    required this.brand,
    required this.brandLight,
    required this.brandDeep,
    required this.line,
    required this.line2,
  });
  final bool isDark;
  final Color bg;
  final Color bg2;
  final Color card;
  final Color card2;
  final Color txt;
  final Color txt2;
  final Color txt3;
  final Color brand;
  final Color brandLight;
  final Color brandDeep;
  final Color line;
  final Color line2;
}

/// 6 套外观模式（key → 完整配色），颜色严格对应 design/theme_design.html：
/// ①浅色 ②暖白 ③浅灰（浅色系） ④深灰 ⑤深蓝 ⑥纯黑（深色系）。
const Map<String, MBTheme> _mfThemes = {
  'light': MBTheme(
      isDark: false,
      bg: Color(0xFFF5F6FA), bg2: Color(0xFFFFFFFF),
      card: Color(0xFFFFFFFF), card2: Color(0xFFF0F2F8),
      txt: Color(0xFF1A2233), txt2: Color(0xFF4A5568), txt3: Color(0xFF8A94A6),
      brand: Color(0xFF455FE9), brandLight: Color(0xFF6C7BFF), brandDeep: Color(0xFF3346C4),
      line: Color(0xFFE5E8F0), line2: Color(0xFFD6DBE6)),
  'warm': MBTheme(
      isDark: false,
      bg: Color(0xFFFAF6F1), bg2: Color(0xFFFFFFFF),
      card: Color(0xFFFFFFFF), card2: Color(0xFFF5EDE3),
      txt: Color(0xFF2A2118), txt2: Color(0xFF5C5344), txt3: Color(0xFF948A79),
      brand: Color(0xFFE8862E), brandLight: Color(0xFFF0A35C), brandDeep: Color(0xFFC96E1E),
      line: Color(0xFFEDE4D8), line2: Color(0xFFE0D4C4)),
  'gray': MBTheme(
      isDark: false,
      bg: Color(0xFFEEF0F4), bg2: Color(0xFFFFFFFF),
      card: Color(0xFFFFFFFF), card2: Color(0xFFE8EBF0),
      txt: Color(0xFF22262E), txt2: Color(0xFF4B5058), txt3: Color(0xFF82868E),
      brand: Color(0xFF5B7CFA), brandLight: Color(0xFF7D97FB), brandDeep: Color(0xFF4560D8),
      line: Color(0xFFDFE3EA), line2: Color(0xFFCFD4DD)),
  'darkgray': MBTheme(
      isDark: true,
      bg: Color(0xFF1B1E24), bg2: Color(0xFF20232A),
      card: Color(0xFF242830), card2: Color(0xFF2E333D),
      txt: Color(0xFFF2F4F8), txt2: Color(0xFFB6BEC8), txt3: Color(0xFF8A929C),
      brand: Color(0xFF5B8DEF), brandLight: Color(0xFF7DA6F2), brandDeep: Color(0xFF4370CC),
      line: Color(0xFF343A45), line2: Color(0xFF3E4552)),
  'darkblue': MBTheme(
      isDark: true,
      bg: Color(0xFF0F1626), bg2: Color(0xFF141C2E),
      card: Color(0xFF182036), card2: Color(0xFF222B44),
      txt: Color(0xFFF2F5FB), txt2: Color(0xFFB4BFD2), txt3: Color(0xFF8A97AC),
      brand: Color(0xFF4E7CF6), brandLight: Color(0xFF729AF8), brandDeep: Color(0xFF3A5FD0),
      line: Color(0xFF2A3550), line2: Color(0xFF35415F)),
  'black': MBTheme(
      isDark: true,
      bg: Color(0xFF0A0A0C), bg2: Color(0xFF101216),
      card: Color(0xFF16181D), card2: Color(0xFF20232A),
      txt: Color(0xFFF5F6F8), txt2: Color(0xFFB0B6C0), txt3: Color(0xFF848A94),
      brand: Color(0xFF6C7BFF), brandLight: Color(0xFF8B9BFF), brandDeep: Color(0xFF5560D8),
      line: Color(0xFF2A2D34), line2: Color(0xFF363A43)),
};

/// 全部外观模式 key（设置页遍历顺序）
const List<String> mfThemeKeys = [
  'light', 'warm', 'gray', 'darkgray', 'darkblue', 'black',
];

/// 外观模式 key → 展示名 i18n key
const Map<String, String> mfThemeLabels = {
  'light': 'appearance_light',
  'warm': 'appearance_warm',
  'gray': 'appearance_gray',
  'darkgray': 'appearance_darkgray',
  'darkblue': 'appearance_darkblue',
  'black': 'appearance_black',
};

/// 取某外观模式（设置页色卡预览用）
MBTheme mfThemeOf(String key) => _mfThemes[key] ?? _mfThemes['light']!;

/// MBox 设计令牌（与 design/theme_design.html 一致）
/// 颜色为动态 getter：随 ThemeController.appearance 整套切换，
/// 页面里 `MBColors.xxx` 的写法不用改，切外观模式自动生效。
class MBColors {
  MBColors._();

  /// 当前选中的外观模式（key → 完整配色）
  static MBTheme get _theme =>
      _mfThemes[ThemeController.instance.appearance] ?? _mfThemes['light']!;

  /// 当前是否为深色外观模式（模式 ④⑤⑥ 为深色）
  static bool get isDark => _theme.isDark;

  // 品牌（随所选外观模式动态变化）
  static Color get brand => _theme.brand;
  static Color get brandLight => _theme.brandLight;
  static Color get brandDeep => _theme.brandDeep;
  static LinearGradient get brandGradient => LinearGradient(
        colors: [brand, brandLight, brandDeep],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  // 背景 / 卡片（整套随模式切换：浅色模式浅底，深色模式深底）
  static Color get bg => _theme.bg;
  static Color get bg2 => _theme.bg2;
  static Color get card => _theme.card;
  static Color get card2 => _theme.card2;

  // 线条
  static Color get line => _theme.line;
  static Color get line2 => _theme.line2;

  // 文本
  static Color get txt => _theme.txt;
  static Color get txt2 => _theme.txt2;
  static Color get txt3 => _theme.txt3;

  // 语义（浅色模式用深一点的绿/红保证白底可读，深色模式用亮色）
  static Color get green => _theme.isDark ? const Color(0xFF2EE6A8) : const Color(0xFF0E9F6E);
  static Color get greenDeep => _theme.isDark ? const Color(0xFF1FA97E) : const Color(0xFF0E9F6E);
  static Color get red => _theme.isDark ? const Color(0xFFFF5A5F) : const Color(0xFFF04438);
  static const amber = Color(0xFFFFB020);
}

/// 数字字体（Chakra Petch 在桌面端可用；移动端回退 monospace）
const kNumFont = 'Chakra Petch';

// ── 输入框令牌（主题与 lib/widgets/mf_input.dart 共用一处）──────────────
// 历史问题：主题里写一套（fill=card2 / 圆角 14 / 内边距 16 / hint 14），
// mfInput 里写另一套（fill=card / 圆角 12 / 内边距 14,13 / hint 12.5），
// 于是「同一种输入框」在登录页和设置弹窗里填充色、圆角、内边距都不一样。
// 现在两边都引用这里的常量，只有「紧凑」尺寸为弹窗保留了更小的内边距。
const double kInputRadius = 14;
const double kInputHintFontSize = 13;
const EdgeInsets kInputPadding =
    EdgeInsets.symmetric(horizontal: 16, vertical: 16);
const EdgeInsets kInputPaddingDense =
    EdgeInsets.symmetric(horizontal: 14, vertical: 14);

ThemeData buildMBoxTheme({Brightness brightness = Brightness.dark}) {
  // 关键：颜色必须跟 brightness 参数绑定（MaterialApp 同时构建 light/dark 两套主题）。
  // 若选中深色外观，light 主题回退到默认浅色配色；反之亦然 —— 保证任意模式下
  // 被展示的那套主题颜色自洽（输入框底/文字不出现白底白字、黑底黑字错位）。
  final t = _paletteFor(brightness);
  final scheme = brightness == Brightness.dark
      ? ColorScheme.dark(
          primary: t.brand,
          secondary: t.brandLight,
          surface: t.card,
          onSurface: t.txt,
          error: t.isDark ? const Color(0xFFFF5A5F) : const Color(0xFFF04438),
        )
      : ColorScheme.light(
          primary: t.brand,
          secondary: t.brandLight,
          surface: t.card,
          onSurface: t.txt,
          error: t.isDark ? const Color(0xFFFF5A5F) : const Color(0xFFF04438),
        );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.bg,
    brightness: brightness,
    fontFamily: 'PingFang SC',
    textTheme: TextTheme(
      titleLarge: TextStyle(color: t.txt, fontWeight: FontWeight.w700, fontSize: 20),
      bodyMedium: TextStyle(color: t.txt, fontSize: 14),
      bodySmall: TextStyle(color: t.txt2, fontSize: 12),
      labelMedium: TextStyle(color: t.txt2, fontSize: 12.5, fontWeight: FontWeight.w500),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: t.bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: t.txt, fontSize: 18, fontWeight: FontWeight.w700),
      iconTheme: IconThemeData(color: t.txt),
    ),
    cardTheme: CardThemeData(
      color: t.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: t.line),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      // 关闭态轨道必须跟着明暗走：旧实现固定深蓝 `0xFF2A3242`，在 light /
      // warm / gray 这些浅色外观下「关闭」的开关看起来就是一个深色药丸 +
      // 白点 —— 和「打开」几乎一样，用户分不清 TUN/自动重连/证书校验到底开没开。
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? t.brand
            : (t.isDark ? const Color(0xFF2A3242) : t.line2),
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.transparent : t.line2,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.card2,
      hintStyle: TextStyle(color: t.txt3, fontSize: kInputHintFontSize),
      errorStyle: TextStyle(color: t.isDark ? const Color(0xFFFF5A5F) : const Color(0xFFF04438), fontSize: 11),
      contentPadding: kInputPadding,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide(color: t.line2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide(color: t.line2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide(color: t.brand, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide(
            color: t.isDark ? const Color(0xFFFF5A5F) : const Color(0xFFF04438),
            width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide(
            color: t.isDark ? const Color(0xFFFF5A5F) : const Color(0xFFF04438),
            width: 1.4),
      ),
    ),
    dividerTheme: DividerThemeData(color: t.line, thickness: 1, space: 1),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: t.bg,
      selectedItemColor: t.brandLight,
      unselectedItemColor: t.txt3,
      type: BottomNavigationBarType.fixed,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.card2,
      contentTextStyle: TextStyle(color: t.txt, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

/// 按请求的 brightness 取配色：选中外观的明暗与请求一致则用之，
/// 否则回退到该明暗的默认外观（保证被展示主题自洽）。
MBTheme _paletteFor(Brightness brightness) {
  final key = ThemeController.instance.appearance;
  final theme = _mfThemes[key] ?? _mfThemes['light']!;
  if (theme.isDark == (brightness == Brightness.dark)) return theme;
  return brightness == Brightness.dark
      ? _mfThemes['darkgray']!
      : _mfThemes['light']!;
}

/// 渐变主按钮
class MBPrimaryButton extends StatelessWidget {
  const MBPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.height = 54,
    this.loading = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final bool loading;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    // 禁用态必须有明显不同的视觉：旧实现 onPressed == null 时仍然是完整渐变 +
    // 白字 + 光晕，看起来完全可点 —— 用户点了没反应，会以为「按钮坏了」。
    // （loading 不算禁用：请求在飞，进度圈本身就是反馈，保留品牌渐变。）
    final disabled = onPressed == null && !loading;
    final labelColor = disabled ? MBColors.txt3 : Colors.white;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: disabled ? null : MBColors.brandGradient,
          color: disabled ? MBColors.card2 : null,
          border: disabled ? Border.all(color: MBColors.line) : null,
          borderRadius: BorderRadius.circular(16),
          boxShadow: disabled
              ? const []
              : [
                  BoxShadow(color: MBColors.brand.withValues(alpha: .35), blurRadius: 24, offset: const Offset(0, 10)),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onPressed,
            child: Center(
              child: loading
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[icon!, const SizedBox(width: 8)],
                        Text(label, style: TextStyle(color: labelColor, fontSize: 16, fontWeight: FontWeight.w600)),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 延迟色阶(全局唯一口径,列表/弹层/当前节点卡共用):
/// 离线→红;在线未测→txt3; <100ms 绿; <300ms 琥珀; 其余 红。
Color mfLatencyColor(int latencyMs, bool online) {
  if (!online) return MBColors.red;
  if (latencyMs < 0) return MBColors.txt3;
  if (latencyMs < 100) return MBColors.green;
  if (latencyMs < 300) return MBColors.amber;
  return MBColors.red;
}

/// 日期显示（统一口径）：`2026-09-19`。
/// 设备页/升级设备页/订单页各自手写过一遍，容易出现「2026/9/9」和「2026-09-09」
/// 两种格式并存。
String formatDateYmd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 金额显示：去掉无意义的尾零。
/// 0.02 → "0.02"；200 → "200"；200.5 → "200.5"；0 → "0"。
/// 修复「0.02 元套餐被 toStringAsFixed(0) 显示成 0 元」的问题。
String formatPrice(double v) {
  var s = v.toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    s = s.replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

/// 新版提示红点（8px 圆形，用于 tab 图标角标 / 设置行提示）
class RedDot extends StatelessWidget {
  const RedDot({super.key, this.size = 8});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration:
            BoxDecoration(color: MBColors.red, shape: BoxShape.circle),
      );
}
