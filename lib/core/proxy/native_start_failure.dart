/// 原生侧内核启动失败的分类与文案映射（纯 Dart，无 Flutter 依赖，可单测）。
///
/// 背景（2026-09 线上日志，安卓 v2.2.16）：
/// ```
/// [ERROR] connect failed: 内核启动超时：getPackageUid: Neither user 10235
///         nor current process has android.permission.INTERACT_ACROSS_USERS.
/// ```
///
/// 这句话**不是**本 App、也不是内核打的（本仓库、APK 的 dex/原生库、
/// sing-box/libbox 里都搜不到 `getPackageUid` 这个串）。它是 Android 框架的
/// 跨用户权限校验：
///
/// ```java
/// // android14: services/core/java/com/android/server/pm/ComputerEngine.java
/// public int getPackageUid(String packageName, long flags, int userId) {
///     if (!mUserManager.exists(userId)) return -1;
///     final int callingUid = Binder.getCallingUid();
///     enforceCrossUserPermission(callingUid, userId, false, false, "getPackageUid");
///     ...
/// }
/// ```
/// 文案模板来自 `ContextImpl`：
/// `(message + ": ") + "Neither user " + uid + " nor current process has " + permission + "."`
///
/// 含义：处理「本 App（uid=10235，主用户）」的请求时，框架去解析**另一个
/// Android 用户**（工作资料 / 应用分身 / 多用户空间）里的包 UID，而普通 App
/// 拿不到 INTERACT_ACROSS_USERS（signature|privileged，只有系统签名应用有）。
///
/// 触发点在 `VpnService.Builder.establish()`：建立隧道时 system_server 的 Vpn
/// 服务要把「按应用分流」列表（addAllowedApplication / addDisallowedApplication）
/// 解析成**每个 profile 用户**的 UID 区间，设备上存在额外用户（分身/工作资料/
/// 多用户）时就会撞上上面这条跨用户校验 → SecurityException → 隧道建不起来
/// → 内核从未启动 → Dart 侧只看到「内核启动超时」。
///
/// App 侧能做与不能做的：
///  * 不能：普通 App 无法申请 INTERACT_ACROSS_USERS，改配置/换内核都没用；
///  * 能做：降级重试（放弃按应用分流，只保留「排除自身」的内核自环保护）、
///    把原因说成用户能执行的话、并且**不做无意义的自动重连**。
library;

import '../../l10n/app_strings.dart';
import 'conn_error.dart';

/// 原生侧上报的失败种类（与 Kotlin 侧 `classifyStartFailure` 的字符串一一对应）
enum NativeStartFailure {
  /// 不是失败（原生侧没有记录）
  none,

  /// Android 多用户 / 应用分身 / 工作资料：框架解析跨用户包 UID 被
  /// INTERACT_ACROSS_USERS 拒绝（见文件头注释）
  crossUserBlocked,

  /// VpnService 未授权 / 授权被撤销
  vpnNotPrepared,

  /// 分流列表里的应用在当前空间不存在（不该再中断连接，Kotlin 侧已降级处理）
  packageMissing,

  /// 其它原因（保留原文，走通用失败文案）
  unknown,
}

/// Kotlin 侧 `lastStartErrorKind` 的取值
const String kNativeKindCrossUser = 'cross_user';
const String kNativeKindVpnNotPrepared = 'vpn_not_prepared';
const String kNativeKindAppMissing = 'app_missing';

/// 判定失败种类：优先用原生侧的显式分类，缺失时回退解析异常原文
/// （老版本 App / iOS 扩展没有 kind 通道，只有 detail）。
NativeStartFailure classifyNativeStartFailure({String? kind, String? detail}) {
  final k = (kind ?? '').trim().toLowerCase();
  final d = (detail ?? '').toLowerCase();

  // 1) 原生侧显式分类优先（新版 App / 新版扩展）
  switch (k) {
    case kNativeKindCrossUser:
      return NativeStartFailure.crossUserBlocked;
    case kNativeKindVpnNotPrepared:
      return NativeStartFailure.vpnNotPrepared;
    case kNativeKindAppMissing:
      return NativeStartFailure.packageMissing;
  }

  // 2) 回退：解析异常原文（老版本原生侧没有 kind 通道，只有一句英文）
  if (d.contains('interact_across_users')) {
    return NativeStartFailure.crossUserBlocked;
  }
  if (d.contains('missing vpn permission') ||
      d.contains('not prepared or is revoked')) {
    return NativeStartFailure.vpnNotPrepared;
  }
  if (d.contains('namenotfound')) return NativeStartFailure.packageMissing;

  // 3) 什么都没记录 → 不是启动失败（原生侧还没写、或该平台没这个通道）
  return k.isEmpty && d.trim().isEmpty
      ? NativeStartFailure.none
      : NativeStartFailure.unknown;
}

/// 该原因是否值得自动重连。
/// 跨用户拦截是**确定性**的：只要用户还待在分身/工作资料空间，重试一百次
/// 也是同一个 SecurityException —— 自动重连只会把可执行的提示推迟 8~30 秒
/// （线上日志里连续 3 次失败就是这个原因）。
bool isRetryableNativeStartFailure(NativeStartFailure f) =>
    f != NativeStartFailure.crossUserBlocked;

/// 有专门文案的原因 → 对应的连接错误类型（UI 按类型给引导按钮）。
/// 返回 null 表示没有专门文案，调用方走通用失败路径。
ConnErrorKind? connErrorKindForNativeStartFailure(NativeStartFailure f) =>
    switch (f) {
      NativeStartFailure.crossUserBlocked => ConnErrorKind.androidMultiUserBlocked,
      NativeStartFailure.vpnNotPrepared => ConnErrorKind.noVpnPermission,
      _ => null,
    };

/// 有专门文案的原因 → 文案 key（AppStrings.t）
String? messageKeyForNativeStartFailure(NativeStartFailure f) => switch (f) {
      NativeStartFailure.crossUserBlocked => 'vpn_multiuser_blocked',
      NativeStartFailure.vpnNotPrepared => 'vpn_permission_needed',
      _ => null,
    };

/// 组给用户看的失败文案：有专门文案就用专门文案，否则回退「内核启动超时：<原文>」。
String nativeStartFailureMessage(
  NativeStartFailure failure,
  String fallbackDetail,
) {
  final key = messageKeyForNativeStartFailure(failure);
  if (key != null) {
    final msg = AppStrings.t(key);
    // 详情仍带上（客服/日志用），但只在非空且不是同一句时追加
    return fallbackDetail.trim().isEmpty ? msg : '$msg\n$fallbackDetail';
  }
  final base = AppStrings.t('kernel_timeout');
  return fallbackDetail.trim().isEmpty ? base : '$base：$fallbackDetail';
}
