import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  /// 注销/关机清理用的生命周期通道（AppDelegate 在 applicationShouldTerminate 时使用）
  private static var lifecycleChannel: FlutterMethodChannel?
  /// 是否已经通知过 Dart 侧（避免重复通知；让超时与回包只生效一次）
  private static var shutdownNotified = false

  /// 通知 Dart 侧做退出清理（恢复系统代理 + 停内核）。
  ///
  /// Dart 侧只做有时限的两件事（见 main.dart 的 _cleanupBeforeSystemExit）。
  /// 这里额外加 2 秒兜底：系统不会无限等，超时也必须放行退出 ——
  /// 「关机卡住」比「代理残留」更糟（残留还有下次启动巡检兜底）。
  static func notifyShutdown(completion: @escaping () -> Void) {
    guard !shutdownNotified, let channel = lifecycleChannel else {
      completion()
      return
    }
    shutdownNotified = true
    var done = false
    let finish = {
      if done { return }
      done = true
      completion()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { finish() }
    channel.invokeMethod("systemShutdown", arguments: nil) { _ in
      DispatchQueue.main.async { finish() }
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 竖版窗口（420×780），与手机端比例一致
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let w: CGFloat = 420, h: CGFloat = 780
    let x = screenFrame.midX - w / 2
    let y = screenFrame.midY - h / 2
    let frame = NSRect(x: x, y: y, width: w, height: h)
    self.setFrame(frame, display: true)
    self.minSize = NSSize(width: 360, height: 640)

    RegisterGeneratedPlugins(registry: flutterViewController)

    MainFlutterWindow.lifecycleChannel = FlutterMethodChannel(
      name: "top.mbox/lifecycle",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    MainFlutterWindow.setupLaunchAtStartupChannel(
      flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// 「开机自启」：实现 launch_at_startup 插件在 macOS 侧要求的平台通道。
  ///
  /// launch_at_startup 是 **Dart-only** 包：它的 macOS 实现只往 `launch_at_startup`
  /// 这个 MethodChannel 发消息，原生实现必须由 App 自己提供（插件 README 的
  /// 「macOS Support → Setup」一节正是要求把这段代码加进 MainFlutterWindow.swift）。
  /// 缺了它，Dart 侧 `enable()/isEnabled()` 一律抛 MissingPluginException —— 这就是
  /// 此前 macOS 上「开关拨了没反应」的根因，且与插件版本无关（0.3.1 与 0.5.1 的
  /// macOS Dart 实现逐字相同，包内都没有原生代码）。
  ///
  /// 用系统自带的 SMAppService（macOS 13+）：注册项会出现在
  /// 「系统设置 → 通用 → 登录项」，用户可见可控。更老的系统返回明确错误，
  /// Dart 侧转成失败提示（不再静默假装成功）。
  private static func setupLaunchAtStartupChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "launch_at_startup", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard #available(macOS 13.0, *) else {
        result(FlutterError(
          code: "launch_at_startup_unsupported",
          message: "开机自启需要 macOS 13 或更新版本",
          details: nil))
        return
      }
      let service = SMAppService.mainApp
      switch call.method {
      case "launchAtStartupIsEnabled":
        result(service.status == .enabled)
      case "launchAtStartupSetEnabled":
        // 参数名与插件 Dart 侧一致：{'setEnabledValue': true/false}
        let enable = (call.arguments as? [String: Any])?["setEnabledValue"] as? Bool ?? false
        do {
          if enable {
            if service.status != .enabled { try service.register() }
          } else {
            if service.status == .enabled { try service.unregister() }
          }
          result(nil)
        } catch {
          result(FlutterError(
            code: "launch_at_startup_failed",
            message: error.localizedDescription,
            details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
