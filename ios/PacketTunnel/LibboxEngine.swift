import Foundation
#if canImport(Libbox)
import Libbox

/// sing-box 内核（libbox）在 iOS 网络扩展里的运行容器。
///
/// 平台接口 / CommandServerHandler / CommandClientHandler 三个协议实现在
/// `LibboxPlatform.m`（Objective-C）里 —— gomobile 生成的框架同时导出同名
/// @protocol 与 @class，Swift 侧无法干净区分，且部分方法会被 Swift 自动重命名；
/// ObjC 里方法名与头文件逐字对应，没有这些歧义。
///
/// 本类只做编排：setup → 建 CommandServer → 起日志通道 → 启动/热重载 → 停止。
final class MBoxLibboxEngine {

    private let platform = MBoxPlatformImpl()
    private let serverHandler = MBoxServerHandlerImpl()
    private let clientHandler = MBoxClientHandlerImpl()
    private var server: LibboxCommandServer?
    private var client: LibboxCommandClient?

    /// 交给内核的隧道 fd（openTun 时回给内核）
    func setTunnelFd(_ fd: Int32) { platform.tunnelFd = fd }

    /// 物理出口接口（仅用于日志；防自环靠配置里的 route.default_interface）
    func setPhysicalInterface(_ name: String?) {
        if let name { TunnelDiag.log("物理出口接口=\(name)") }
    }

    static func version() -> String { LibboxVersion() }

    /// 启动内核：configContent 是 sing-box JSON，home 是扩展可写目录。
    func start(home: String, configContent: String) throws {
        platform.logger = { TunnelDiag.log($0) }
        serverHandler.logger = { TunnelDiag.log("[app] \($0)") }
        serverHandler.onStop = { TunnelDiag.log("[app] 内核请求停止服务") }
        serverHandler.onReload = { TunnelDiag.log("[app] 内核请求重载配置") }
        clientHandler.onLogLines = { TunnelDiag.appendKernel($0) }

        let options = LibboxSetupOptions()
        options.basePath = home
        options.workingPath = home
        options.tempPath = NSTemporaryDirectory()
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        options.appVersion = ver
        options.appMarketingVersion = ver
        var err: NSError?
        guard LibboxSetup(options, &err) else {
            throw err ?? NSError(domain: "mbox", code: -2,
                                 userInfo: [NSLocalizedDescriptionKey: "LibboxSetup 失败"])
        }
        TunnelDiag.log("LibboxSetup ok（内核 \(MBoxLibboxEngine.version())）")

        guard let server = LibboxNewCommandServer(serverHandler, platform, &err) else {
            throw err ?? NSError(domain: "mbox", code: -3,
                                 userInfo: [NSLocalizedDescriptionKey: "CommandServer 创建失败"])
        }
        self.server = server
        try server.start()

        // 日志通道：CommandClient + CommandLog（失败不影响内核运行）
        let clientOptions = LibboxCommandClientOptions()
        clientOptions.addCommand(LibboxCommandLog)
        if let client = LibboxNewCommandClient(clientHandler, clientOptions) {
            do {
                try client.connect()
                self.client = client
            } catch {
                TunnelDiag.log("日志通道连接失败: \(error.localizedDescription)")
            }
        }

        // 阻塞直到配置解析完成/失败
        try server.startOrReloadService(configContent, options: nil)
        TunnelDiag.log("✓ startOrReloadService 返回，内核已启动")
    }

    func reload(configContent: String) throws {
        try server?.startOrReloadService(configContent, options: nil)
    }

    func stop() {
        try? client?.disconnect()
        client = nil
        try? server?.closeService()
        server?.close()
        server = nil
    }
}

#endif
