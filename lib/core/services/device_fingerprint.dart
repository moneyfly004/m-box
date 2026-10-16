import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 硬件指纹（X-MF-Device-Fp）：**跨「重装 App / 清数据 / 安装包升级」不变**的机器标识。
///
/// 为什么需要它：
/// - `install_id`（[LocalPaths] 的安装标记）是**安装实例**标识，写在应用数据目录里。
///   Windows 安装包升级时旧版卸载程序会先跑一遍，一旦把应用数据目录删掉，
///   同一台电脑就换了 install_id → 后端当作新设备再登记一行，
///   用户设备列表里凭空多出一台「幽灵设备」，白占一个设备名额。
///   生产实证：老站用户 susanzhang1230 只有 iPhone + 一台 Windows，后台显示 3 台
///   （MoneyFly 2.2.25 与 2.2.28 是同一台 PC）。
/// - 硬件指纹从系统硬件/系统安装标识派生，不随 App 安装实例变化；
///   后端在「安装 ID 没命中」时用它把老行认回来（不新增设备、不占额外名额）。
///
/// 各平台取值（均无需提权、不涉及被系统屏蔽的隐私字段）：
/// - Windows：`HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`（注册表，普通用户可读）；
///   取不到时退回 `WindowsDeviceInfo.deviceId`。
/// - macOS：`IOPlatformUUID`（device_info_plus 的 systemGUID；取不到时读 ioreg）。
/// - Android：`Settings.Secure.ANDROID_ID`（Android 8+ 按「应用签名 + 用户」作用域，
///   重装不变化；经原生 MethodChannel 读取）。
/// - iOS：`identifierForVendor`（同一 vendor 的设备级稳定标识）。
///
/// **刻意不用** MAC 地址 / 序列号 / IMEI：MAC 可被随机化且有虚拟网卡，
/// IMEI/序列号在 Android 10+ 对普通应用直接返回空、macOS 读取需特权。
class DeviceFingerprint {
  DeviceFingerprint._();

  /// 原生通道：仅用于读取 Android 的 ANDROID_ID
  static const _channel = MethodChannel('top.moneyfly/device_id');

  static String? _cache;

  /// 测试注入点：直接提供「平台:原始值」串，跳过平台读取
  /// （用法与 [LocalPaths.debugSupportDir] 一致：仅在测试中设置）。
  @visibleForTesting
  static Future<String> Function()? debugRawValue;

  /// 解析本机硬件指纹（失败返回空串，调用方应跳过该请求头、保持原有行为）
  static Future<String> resolve() async {
    if (kIsWeb) return '';
    if (_cache != null) return _cache!;
    String raw = '';
    try {
      raw = await _rawValue();
    } catch (_) {
      raw = '';
    }
    _cache = raw.isEmpty ? '' : _digest(raw);
    return _cache!;
  }

  /// 测试用：清空内存缓存（同一进程内硬件不会变，正常无需调用）
  @visibleForTesting
  static void resetCache() => _cache = null;

  static String _digest(String raw) {
    // 加固定前缀避免与其它哈希用途混淆；截断 32 位十六进制足够唯一，
    // 且稳稳落在后端 device_hw_fp varchar(64) 内。
    final hex = sha256.convert(utf8.encode('moneyfly-hwfp:$raw')).toString();
    return hex.substring(0, 32);
  }

  static Future<String> _rawValue() async {
    if (debugRawValue != null) {
      try {
        return await debugRawValue!();
      } catch (_) {
        return '';
      }
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return await _windowsRaw();
      case TargetPlatform.macOS:
        return await _macosRaw();
      case TargetPlatform.android:
        return await _androidRaw();
      case TargetPlatform.iOS:
        return await _iosRaw();
      default:
        return '';
    }
  }

  // ---------- Windows ----------

  static Future<String> _windowsRaw() async {
    final guid = await _queryMachineGuid();
    if (guid.isNotEmpty) return 'win:$guid';
    try {
      final w = await DeviceInfoPlugin().windowsInfo;
      if (w.deviceId.trim().isNotEmpty) return 'win-sqm:${w.deviceId.trim()}';
    } catch (_) {}
    return '';
  }

  /// 读 `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`。
  /// 用 reg.exe 而不是原生插件：普通用户可读、无需管理员，且不引入新的插件依赖。
  static Future<String> _queryMachineGuid() async {
    try {
      final r = await Process.run(
        'reg.exe',
        ['query', r'HKLM\SOFTWARE\Microsoft\Cryptography', '/v', 'MachineGuid'],
        runInShell: false,
      ).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return '';
      final out = '${r.stdout}';
      for (final line in out.split('\n')) {
        if (!line.contains('MachineGuid')) continue;
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 3) {
          final v = parts.last.trim();
          if (v.isNotEmpty) return v;
        }
      }
    } catch (_) {}
    return '';
  }

  // ---------- macOS ----------

  static Future<String> _macosRaw() async {
    try {
      final m = await DeviceInfoPlugin().macOsInfo;
      final g = (m.systemGUID ?? '').trim();
      if (g.isNotEmpty) return 'mac:$g';
    } catch (_) {}
    try {
      final r = await Process.run(
        'ioreg',
        ['-rd1', '-c', 'IOPlatformExpertDevice'],
        runInShell: false,
      ).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return '';
      final m = RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"').firstMatch('${r.stdout}');
      final v = (m?.group(1) ?? '').trim();
      if (v.isNotEmpty) return 'mac:$v';
    } catch (_) {}
    return '';
  }

  // ---------- Android ----------

  static Future<String> _androidRaw() async {
    try {
      final v = await _channel.invokeMethod<String>('getAndroidId');
      final id = (v ?? '').trim();
      // 出厂/异常环境下 ANDROID_ID 可能是空或 "9774d56d682e549c"（旧版全 0 值）
      if (id.isNotEmpty && id != '9774d56d682e549c') return 'android:$id';
    } catch (_) {}
    return '';
  }

  // ---------- iOS ----------

  static Future<String> _iosRaw() async {
    try {
      final i = await DeviceInfoPlugin().iosInfo;
      final v = (i.identifierForVendor ?? '').trim();
      if (v.isNotEmpty) return 'ios:$v';
    } catch (_) {}
    return '';
  }
}
