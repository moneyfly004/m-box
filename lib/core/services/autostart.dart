import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'app_log.dart';

/// 与操作系统交互的抽象（生产实现走 launch_at_startup 插件；单测注入假实现）
abstract class AutostartBackend {
  void setup({required String appName, required String appPath});
  Future<bool> enable();
  Future<bool> disable();
  Future<bool> isEnabled();
}

class _PluginBackend implements AutostartBackend {
  @override
  void setup({required String appName, required String appPath}) =>
      launchAtStartup.setup(appName: appName, appPath: appPath);

  @override
  Future<bool> enable() => launchAtStartup.enable();

  @override
  Future<bool> disable() => launchAtStartup.disable();

  @override
  Future<bool> isEnabled() => launchAtStartup.isEnabled();
}

/// 开机自启（Windows / macOS / Linux）。
///
/// 为什么需要这一层包装（旧实现是设置页直接调 `launchAtStartup.enable()`）：
///
/// 1. **必须先 setup**：launch_at_startup 内部的 launcher 字段初值是
///    `AppAutoLauncherImplNoop`，它的 enable/disable **抛 `UnsupportedError`**。
///    没调 setup 就永远是 Noop —— 旧代码「先写设置、再 `unawaited(enable())`」，
///    异常被 unawaited 吞掉，结果**开关显示「已开启」而系统里什么都没注册**，
///    用户完全看不出来（这是实测确认的 bug）。
/// 2. **失败必须让上层知道**：调用方要能决定「设置项到底落不落盘」，所以这里
///    统一返回 bool、绝不抛，异常写进日志中心。
/// 3. **路径会变**：Windows 写的是 `HKCU\...\CurrentVersion\Run\MoneyFly = <exe
///    绝对路径>`，应用被换目录安装/手动移动后这条就失效了 —— 启动时用
///    [syncOnStartup] 自愈。
class AutostartService {
  AutostartService._();

  /// 注册名（Windows 是注册表值名，Linux 是 .desktop 文件名的一部分）
  ///
  /// 注意：品牌改为 MBox 后这里是新注册名。老版本（MoneyFly）留下的自启动项
  /// 不会自动清理 —— 升级用户若之前开着自启动，需要在系统里手动删掉旧项
  /// （Windows：任务管理器→启动；macOS：系统设置→通用→登录项）。
  static const appName = 'MBox';

  @visibleForTesting
  static AutostartBackend? debugBackend;

  static final AutostartBackend _plugin = _PluginBackend();
  static AutostartBackend get _backend => debugBackend ?? _plugin;

  static bool _inited = false;

  /// 仅桌面三平台支持（移动端启动项由系统管理，没有「开机自启」开关）
  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 要注册的可执行文件路径。
  ///
  /// - Windows / Linux：exe 本体（Windows 注册表值就是它）
  /// - macOS：**App bundle**（`/Applications/MoneyFly.app`）—— 启动项要拉起的是
  ///   整个 app，而不是 bundle 内的二进制。
  @visibleForTesting
  static String resolveLaunchPath({String? resolvedExecutable, bool? isMacOS}) {
    final exe = resolvedExecutable ?? Platform.resolvedExecutable;
    final mac = isMacOS ?? (!kIsWeb && Platform.isMacOS);
    if (!mac) return exe;
    // …/MoneyFly.app/Contents/MacOS/MoneyFly → …/MoneyFly.app
    //
    // 两种分隔符都认：喂进来的既然是 macOS 路径（语义上恒为 POSIX '/'），
    // 就不该取决于**宿主平台** —— 否则同一段逻辑在 Windows 上跑单测会失败
    // （实测：CI 的 Windows job 就是这么红掉的），也会让「跨平台构造路径」的
    // 调用方踩坑。谁先出现用谁。
    final slash = exe.indexOf('/Contents/');
    final backslash = exe.indexOf(r'\Contents\');
    final i = switch ((slash, backslash)) {
      (< 0, < 0) => -1,
      (< 0, _) => backslash,
      (_, < 0) => slash,
      _ => slash < backslash ? slash : backslash,
    };
    return i > 0 ? exe.substring(0, i) : exe;
  }

  static String get launchPath => resolveLaunchPath();

  /// 注册到插件（幂等）。必须在 enable/disable/isEnabled 之前调用一次。
  static void _ensureInit() {
    if (_inited) return;
    _inited = true;
    _backend.setup(appName: appName, appPath: launchPath);
  }

  /// 开启开机自启。返回 false = 未生效（调用方**不应**把设置落盘）。
  static Future<bool> enable() async {
    if (!supported) {
      AppLog.log('APP', 'autostart: 当前平台不支持');
      return false;
    }
    try {
      _ensureInit();
      final ok = await _backend.enable();
      AppLog.log('APP',
          ok ? 'autostart: 已注册（$launchPath）' : 'autostart: 注册未生效');
      return ok;
    } catch (e) {
      // macOS 侧的原生通道由 macos/Runner/MainFlutterWindow.swift 提供
      // （SMAppService，macOS 13+）。这里若真抛 MissingPluginException /
      // PlatformException，说明原生通道没挂上或系统版本过低 —— 必须留痕，
      // 而不是像旧实现那样被 unawaited 静默吞掉。
      AppLog.error('autostart enable failed: $e');
      return false;
    }
  }

  /// 关闭开机自启。返回 false = 未生效。
  static Future<bool> disable() async {
    if (!supported) return false;
    try {
      _ensureInit();
      final ok = await _backend.disable();
      AppLog.log('APP', ok ? 'autostart: 已取消注册' : 'autostart: 取消注册未生效');
      return ok;
    } catch (e) {
      AppLog.error('autostart disable failed: $e');
      return false;
    }
  }

  /// 系统里当前是否已注册。null = 取不到（平台不支持 / 插件不可用）。
  static Future<bool?> isEnabled() async {
    if (!supported) return null;
    try {
      _ensureInit();
      return await _backend.isEnabled();
    } catch (e) {
      AppLog.error('autostart isEnabled failed: $e');
      return null;
    }
  }

  /// 启动时自愈：让系统里的注册与设置项一致。
  ///
  /// - 设置开着、系统里没有（升级换目录、被安全软件/任务管理器清掉）→ 重新注册；
  /// - 设置关着、系统里却有（旧版本残留）→ 清掉，避免「关了还自启」；
  /// - 取不到系统状态（macOS 插件不可用等）→ 什么都不做，只记日志。
  static Future<void> syncOnStartup({required bool prefEnabled}) async {
    if (!supported) return;
    final osEnabled = await isEnabled();
    if (osEnabled == null) return;
    if (!prefEnabled) {
      if (osEnabled) {
        AppLog.log('APP', 'autostart: 设置已关闭但系统里仍注册着 → 清理');
        await disable();
      }
      return;
    }
    if (osEnabled) return;
    AppLog.log('APP',
        'autostart: 设置已开启但系统里没有 → 重新注册（换目录安装/被清理后自愈）');
    await enable();
  }

  /// 仅测试：清掉初始化标记与注入的后端
  @visibleForTesting
  static void resetForTest() {
    _inited = false;
    debugBackend = null;
  }
}
