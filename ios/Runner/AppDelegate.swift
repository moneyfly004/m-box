import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // VPN 控制通道：与 Android 的 top.mbox/vpn_core 同名同参
    // （内核跑在 PacketTunnel 扩展进程里，本通道只负责起停隧道与读日志）
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VpnCorePlugin") {
      VpnCorePlugin.register(with: registrar.messenger())
    }
  }
}
