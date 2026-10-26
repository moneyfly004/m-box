import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 平台权限服务（Android 走原生 MethodChannel；桌面端返回默认可用）
/// 对应 MainActivity.kt 的 top.mbox/vpn_permissions 通道
class PermissionService {
  PermissionService._();
  static final PermissionService instance = PermissionService._();

  static const _channel = MethodChannel('top.mbox/vpn_permissions');

  static bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 请求 VPN 授权（Android 弹系统授权框），返回是否已就绪
  Future<bool> prepareVpn() async {
    if (!_isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('prepareVpn')
          .timeout(const Duration(seconds: 45), onTimeout: () => null);
      if (res != null) return res;
      // 原生回调超时（极少数 ROM 弹框被吞 / Activity 被系统强杀导致 result
      // 未回传）时，用 isVpnPrepared 兜底判定，避免连接流程永久挂起：
      // 弹框期间被静默拒绝 → prepare()!=null → false；已授权但回调丢失 → true。
      return await isVpnPrepared();
    } catch (_) {
      return false;
    }
  }

  Future<bool> isVpnPrepared() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isVpnPrepared') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 是否已获得电池优化豁免（保留原生查询能力，不再用于自动引导）
  Future<bool> isBatteryOptimizationIgnored() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isBatteryOptimizationIgnored') ?? false;
    } catch (_) {
      return true;
    }
  }

  /// 请求电池优化豁免（v1.0.19 起不再自动调用 —— 产品要求不做省电提醒；
  /// 保留方法供未来可选的手动入口使用）
  Future<void> requestIgnoreBatteryOptimization() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimization');
    } catch (_) {}
  }

  /// 打开系统电池设置页（同上：不再自动调用，仅保留能力）
  Future<void> openBatterySettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openBatterySettings');
    } catch (_) {}
  }

  /// 打开系统 VPN 设置页：授权失败引导用 —— 常见于其他 VPN 应用开启了
  /// 「始终开启的 VPN」导致系统授权框弹不出来，需用户手动关闭后重试
  Future<void> openVpnSettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openVpnSettings');
    } catch (_) {}
  }

  /// 厂商名（MIUI/EMUI/ColorOS… 用于后台白名单引导）
  Future<String> getVendor() async {
    if (!_isAndroid) return 'desktop';
    try {
      return await _channel.invokeMethod<String>('getVendor') ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<bool> requestNotificationPermission() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission')
          .timeout(const Duration(seconds: 20), onTimeout: () => null) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 连接前引导：VPN 授权（必需，前置）+ 通知。
  /// 返回 false 表示用户拒绝 VPN 授权（不继续连接）。
  ///
  /// 设计说明：不再做电池优化豁免引导（v1.0.19 起彻底移除）——
  /// 1) 电池弹窗会打开系统界面把 App 切后台，曾导致「点连接自动缩小、不生效」
  ///    （Android 12+ 后台启动前台服务受限）；
  /// 2) 产品要求：不做任何省电提醒，连接后让 App 后台挂起稳定运行即可
  ///    （前台服务 + 看门狗保活，功耗交给系统自行处理）。
  Future<bool> ensureAllForConnect() async {
    final vpnOk = await prepareVpn();
    if (!vpnOk) return false;
    await requestNotificationPermission();
    return true;
  }
}
