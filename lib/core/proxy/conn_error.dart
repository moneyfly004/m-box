/// 连接失败类型与 UI 指引（纯 Dart，无 Flutter 依赖，可单测）。
///
/// 背景：安卓端"连不上"的原因五花八门（缺 VPN 授权 / 通知被拒 / Android 12+
/// 后台启动前台服务受限 / 内核未就绪…），如果只给一串字符串，用户和客服都
/// 说不清是什么问题。把失败**类型化**后，UI 可以按类型给出不同的引导按钮
/// 与文案（如"去授权 VPN"、"允许通知"、"保持前台重试"）。
library;

enum ConnErrorKind {
  /// 无错误（正常/未连接）
  none,

  /// 未分类的普通错误（沿用通用"重试"）
  unknown,

  /// Android：VPN 授权缺失或已被撤销（VpnService.prepare 需要重新授权）
  noVpnPermission,

  /// Android 13+：通知权限被拒绝（前台服务通知被系统抑制）
  noNotificationPermission,

  /// Android 12+：后台启动前台服务受限（点连接瞬间 App 被挤到后台）
  backgroundStartBlocked,

  /// 内核启动后 Clash API 未在限定时间内就绪
  kernelTimeout,

  /// 看门狗判定内核死亡 / 内核异常退出
  kernelExited,

  /// 本地端口被别的进程占用（`bind: address already in use`）。
  ///
  /// 典型来源：上一次没退干净的内核、另一个 App 实例、或别的代理软件占着
  /// 2080/9090。**这类失败重试多少次都一样** —— 必须让用户能「换端口」。
  portInUse,

  /// Android：多用户 / 应用分身 / 工作资料空间下，系统拒绝建立 VPN —— 框架在
  /// 解析跨用户包 UID 时要求 INTERACT_ACROSS_USERS，普通 App 不可能持有。
  /// 详见 native_start_failure.dart 的文件头注释。
  androidMultiUserBlocked,
}

/// 携带类型的连接异常（内核/平台层上抛，ConnectionController 捕获后落位
/// [ConnectionController.error] 与 [ConnectionController.errorKind]）
class TypedConnError implements Exception {
  final ConnErrorKind kind;
  final String message;
  const TypedConnError(this.kind, this.message);

  @override
  String toString() => message;
}

/// 按失败类型给出 UI 指引（纯函数，供首页错误区渲染，便于单测）：
/// - [showGrantVpn]：显示"授权 VPN 权限"按钮（授权成功后再重连）
/// - [showGrantNotify]：显示"允许通知"按钮（允许后再重连）
/// - [showRetry]：显示普通"重试"按钮
/// - [showFixPort]：显示"换端口并重连"按钮（端口被占用时的唯一有效动作）
/// - [foregroundHint]：是否提示"请保持 App 在前台后重试"
class ConnErrorUi {
  const ConnErrorUi({
    required this.showGrantVpn,
    required this.showGrantNotify,
    required this.showRetry,
    required this.foregroundHint,
    this.showFixPort = false,
  });

  final bool showGrantVpn;
  final bool showGrantNotify;
  final bool showRetry;
  final bool foregroundHint;

  /// 端口被占用：给「换端口并重连」（换端口才是真正能解决的动作）
  final bool showFixPort;
}

ConnErrorUi guideForConnError(ConnErrorKind kind) => switch (kind) {
      // 无错误态：不显示任何引导按钮
      ConnErrorKind.none => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: false, showRetry: false, foregroundHint: false),
      ConnErrorKind.noVpnPermission => const ConnErrorUi(
          showGrantVpn: true, showGrantNotify: false, showRetry: false, foregroundHint: false),
      ConnErrorKind.noNotificationPermission => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: true, showRetry: false, foregroundHint: false),
      ConnErrorKind.backgroundStartBlocked => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: false, showRetry: true, foregroundHint: true),
      // 端口被占用：换端口才是解法；同时保留「重试」（占用者刚退出时可直接连上）
      ConnErrorKind.portInUse => const ConnErrorUi(
          showGrantVpn: false,
          showGrantNotify: false,
          showRetry: true,
          foregroundHint: false,
          showFixPort: true),
      // 多用户/分身拦截：授权按钮没用（不是没授权，是系统权限不可能拿到），
      // 保留「重试」—— 用户关掉分身/切回主空间后点一下就能连上。
      ConnErrorKind.androidMultiUserBlocked => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: false, showRetry: true, foregroundHint: false),
      _ => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: false, showRetry: true, foregroundHint: false),
    };
