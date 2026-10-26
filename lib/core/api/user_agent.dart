import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../services/device_fingerprint.dart';
import '../services/local_paths.dart';

/// MBox User-Agent + 设备信息头
///
/// UA 规范：`MBox/<应用版本> (<操作系统特征串>)`
///
/// 额外通过 X-MF-* 自定义头向后端传递设备详情（型号/品牌/OS/类型），
/// 即使 UA 被截断或解析不全，后端也能准确识别设备。
///
/// **客户端身份**：后端是从 UA 前缀反查「软件名称」的（`software_name` 字段），
/// 不认识的前缀会记成 `Unknown`。换成 MBox 之后如果后台仍显示 Unknown，
/// 说明后端那份软件名映射表还没加 MBox —— 两种办法任选其一：
///   1) 推荐：后端把 `MBox` 加进映射表（一行配置，之后所有平台都对）；
///   2) 临时：构建时 `--dart-define=MBOX_UA_PREFIX=MoneyFly`，UA 就退回旧前缀，
///      后台立刻认得（品牌名只影响 UA 这一处，界面仍是 MBox）。
class UserAgent {
  UserAgent._();

  /// UA 前缀（品牌）。默认 MBox；可用 --dart-define=MBOX_UA_PREFIX=... 覆盖，
  /// 用于「后端软件名映射表还没更新」的临时兼容。
  static const String brand = String.fromEnvironment(
    'MBOX_UA_PREFIX',
    defaultValue: 'MBox',
  );

  /// 设备详情头（resolve 后填充），由 ApiClient 拦截器注入每个请求
  static Map<String, String> deviceHeaders = {};

  static String build({required String version, String? osSection}) {
    final v = version.trim();
    final os = osSection?.trim() ?? '';
    if (os.isEmpty) return '$brand/$v';
    return '$brand/$v ($os)';
  }

  // ---------- 各平台特征串 ----------

  static String androidSection(String release, String model, String buildId) {
    final buf = StringBuffer('Linux; Android ${release.trim()}');
    if (model.trim().isNotEmpty && buildId.trim().isNotEmpty) {
      buf.write('; ${model.trim()} Build/${buildId.trim()}');
    }
    return buf.toString();
  }

  static String windowsSection(int major, int minor) =>
      'Windows NT $major.$minor';

  static String macosSection(int major, int minor) =>
      'Macintosh; Mac OS X ${major}_$minor';

  /// iOS 特征串。
  ///
  /// `utsname.machine` 本身就以 iPhone/iPad/iPod 开头（如 `iPhone14,3`），
  /// 早期实现又拼了一个 `iPhone` 前缀 → UA 里出现 `iPhoneiPhone14,3`，
  /// 后端按 UA 解析机型时会得到错误的型号串。
  static String iosSection(String machine, String systemVersion) {
    final m = machine.trim();
    final prefix = (m.startsWith('iPhone') ||
            m.startsWith('iPad') ||
            m.startsWith('iPod'))
        ? ''
        : 'iPhone';
    return '$prefix$m; iOS $systemVersion';
  }

  // ---------- 运行时解析 ----------

  static Future<String> resolveOsSection() async {
    if (kIsWeb) return '';
    try {
      final plugin = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await plugin.androidInfo;
          return androidSection(a.version.release, a.model, a.id);
        case TargetPlatform.windows:
          final w = await plugin.windowsInfo;
          return windowsSection(w.majorVersion, w.minorVersion);
        case TargetPlatform.macOS:
          final m = await plugin.macOsInfo;
          return macosSection(m.majorVersion, m.minorVersion);
        case TargetPlatform.iOS:
          final i = await plugin.iosInfo;
          return iosSection(i.utsname.machine, i.systemVersion);
        default:
          return '';
      }
    } catch (_) {
      return '';
    }
  }

  /// 采集设备详情（填充 deviceHeaders），resolve() 内部调用
  static Future<void> _collectDeviceHeaders() async {
    if (kIsWeb) return;
    try {
      final plugin = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await plugin.androidInfo;
          deviceHeaders = {
            'X-MF-Device-Model': a.model,
            'X-MF-Device-Brand': a.brand,
            'X-MF-OS': 'Android ${a.version.release}',
            'X-MF-Device-Type': 'mobile',
          };
        case TargetPlatform.windows:
          final w = await plugin.windowsInfo;
          deviceHeaders = {
            'X-MF-Device-Model': w.productName,
            'X-MF-Device-Brand': 'PC',
            'X-MF-OS': 'Windows ${w.majorVersion}.${w.minorVersion}',
            'X-MF-Device-Type': 'desktop',
          };
        case TargetPlatform.macOS:
          final m = await plugin.macOsInfo;
          deviceHeaders = {
            'X-MF-Device-Model': m.model,
            'X-MF-Device-Brand': 'Apple',
            'X-MF-OS': 'macOS ${m.majorVersion}.${m.minorVersion}',
            'X-MF-Device-Type': 'desktop',
          };
        case TargetPlatform.iOS:
          final i = await plugin.iosInfo;
          deviceHeaders = {
            'X-MF-Device-Model': i.utsname.machine,
            'X-MF-Device-Brand': 'Apple',
            'X-MF-OS': 'iOS ${i.systemVersion}',
            'X-MF-Device-Type': i.utsname.machine.toLowerCase().contains('ipad') ? 'tablet' : 'mobile',
          };
        default:
          break;
      }
      // 过滤空值
      deviceHeaders.removeWhere((_, v) => v.isEmpty);
    } catch (_) {}

    // 稳定设备 ID：安装级唯一、写入后不再变化（只有重装/清数据才换）。
    //
    // 后端用它做设备身份，而不是像过去那样按 UA（**含 App 版本号**）识别 ——
    // 旧算法下用户每次升级 App/系统都会被当成「新设备」重复登记，旧行变成永久
    // 占名额的幽灵设备，还会让「删除设备 = 踢下线」的判定错位（升级一次就绕过）。
    //
    // 刻意放在平台信息采集的 try 之外：设备信息插件失败也不能丢掉这个头。
    try {
      var installId = await LocalPaths.readMarker();
      if (installId.isEmpty) {
        await LocalPaths.writeMarker(); // 首次运行/标记缺失时补写
        installId = await LocalPaths.readMarker();
      }
      if (installId.isNotEmpty) {
        deviceHeaders['X-MF-Device-Id'] = installId;
      }
    } catch (_) {}

    // 硬件指纹：跨「重装/清数据/安装包升级删了应用数据」不变的机器标识。
    //
    // install_id 会随安装实例变化（Windows 安装包升级时旧卸载程序若删了
    // %APPDATA%\top.mbox\MBox，install_id 就丢了），后端会因此把同一台
    // 电脑登记成新设备（幽灵设备、白占设备名额）。后端在「安装 ID 没命中」时会用
    // 这个指纹把同一订阅下的老行认回来，所以同一台机器重装后仍只占一个名额。
    //
    // 同样刻意放在平台信息采集的 try 之外：读不到就是不加这个头（后端行为不变）。
    try {
      final hwFp = await DeviceFingerprint.resolve();
      if (hwFp.isNotEmpty) {
        deviceHeaders['X-MF-Device-Fp'] = hwFp;
      }
    } catch (_) {}
  }

  /// 解析完整 UA + 设备详情头（启动时由 main() await 调用）
  static Future<String> resolve({required String version}) async {
    final os = await resolveOsSection();
    await _collectDeviceHeaders();
    // 客户端身份头：后端可以直接用它判断「这是哪个软件、哪个版本」，
    // 不必再去正则解析 UA 前缀（换品牌名时就不会出现 software_name=Unknown）。
    deviceHeaders['X-MF-Client-Name'] = brand;
    deviceHeaders['X-MF-Client-Version'] = version.trim();
    return build(version: version, osSection: os);
  }
}
