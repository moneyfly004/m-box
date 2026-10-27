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
    /// 注入「openTun 时刻再取一次真实 utun fd」的钩子（返回 <=2 表示拿不到）。
    /// 实现由扩展提供（它能访问 packetFlow / 用户态桥）。
    func setFdResolver(_ resolver: @escaping () -> Int32) {
        platform.fdResolver = resolver
    }

    func setPhysicalInterface(_ name: String?) {
        if let name { TunnelDiag.log("物理出口接口=\(name)") }
    }

    static func version() -> String { LibboxVersion() }

    /// 挑一个当前空闲的本地 TCP 端口给命令服务用（0 = 用 unix socket）。
    ///
    /// 为什么要 TCP：libbox 的 unix socket 路径受 Darwin `sun_path`(104B) 限制，
    /// iOS 扩展容器路径已经 80+ 字节，加 `/command.sock` 极易越界（实测 bind
    /// 直接 `invalid argument`，内核起不来）。TCP 回环没有这个限制。
    static func pickCommandServerPort() -> Int32 {
        for _ in 0..<8 {
            let port = Int32.random(in: 40000...60000)
            if isTCPPortFree(port) { return port }
        }
        return 0
    }

    private static func isTCPPortFree(_ port: Int32) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// 给内核 unix socket 用的**短**目录。
    ///
    /// 为什么必须短：libbox 的 CommandServer 把监听地址固定写成
    /// `<basePath>/command.sock`（experimental/libbox/command_server.go），而 Darwin 的
    /// `sun_path` 只有 104 字节。iOS 扩展的数据容器路径本来就有 ~81 字节
    /// （`/var/mobile/Containers/Data/PluginKitPlugin/<36 字符 UUID>`），再拼上
    /// `Library/Application Support/singbox/command.sock`（46 字节）必然超限 ——
    /// 实测报错：`listen command server: listen unix …: bind: invalid argument`，
    /// 隧道进程一起来就退出，App 侧只看到「内核启动超时」。
    ///
    /// 所以 basePath 取「扩展数据容器根目录」（长度固定 ~81），
    /// workingPath 仍然是原来的完整工作目录（缓存/数据库/规则集都放那里）。
    static func shortBasePath(for home: String) -> String {
        let socketName = "/command.sock"
        let limit = 103 - socketName.count // sun_path[104] 含结尾 NUL
        let parts = home.split(separator: "/")
        if let idx = parts.firstIndex(of: "PluginKitPlugin"), idx + 1 < parts.count {
            let containerRoot = "/" + parts[0...idx + 1].joined(separator: "/")
            if containerRoot.count <= limit { return containerRoot }
        }
        // 兜底：逐级上溯到足够短（容器布局变化时不至于又 bind 失败）
        var path = home
        while path.count > limit {
            guard let slash = path.range(of: "/", options: .backwards) else { break }
            path = String(path[..<slash.lowerBound])
        }
        return path.isEmpty ? "/tmp" : path
    }

    /// 启动内核：configContent 是 sing-box JSON，home 是扩展可写目录。
    func start(home: String, configContent: String, apiPort: Int = 0) throws {
        platform.logger = { TunnelDiag.log($0) }
        serverHandler.logger = { TunnelDiag.log("[app] \($0)") }
        serverHandler.onStop = { TunnelDiag.log("[app] 内核请求停止服务") }
        serverHandler.onReload = { TunnelDiag.log("[app] 内核请求重载配置") }
        clientHandler.onLogLines = { TunnelDiag.appendKernel($0) }

        let options = LibboxSetupOptions()
        // basePath 只决定 unix socket 落点（libbox 固定拼 <basePath>/command.sock），
        // 必须足够短，见 shortBasePath(for:) 的注释。
        options.basePath = Self.shortBasePath(for: home)
        options.workingPath = home
        options.tempPath = NSTemporaryDirectory()
        // 命令服务优先走 **TCP 回环**：libbox 的 unix socket 路径是
        // `<basePath>/command.sock`，而 Darwin 的 sun_path 只有 104 字节，
        // iOS 扩展容器路径本身就 80+ 字节 —— 稍微长一点就 `bind: invalid argument`
        // （真机实测的第一个坑）。TCP 只受端口占用影响，端口自己挑、挑不到再退回 unix。
        let cmdPort = Self.pickCommandServerPort()
        options.commandServerListenPort = cmdPort
        TunnelDiag.log("命令服务监听: " + (cmdPort == 0 ? "unix socket（短路径）"
            : "TCP 127.0.0.1:\(cmdPort)"))
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        options.appVersion = ver
        options.appMarketingVersion = ver
        var err: NSError?
        guard LibboxSetup(options, &err) else {
            throw err ?? NSError(domain: "mbox", code: -2,
                                 userInfo: [NSLocalizedDescriptionKey: "LibboxSetup 失败"])
        }
        TunnelDiag.log("✓ [1/6] LibboxSetup ok（内核 \(MBoxLibboxEngine.version())）")

        guard let server = LibboxNewCommandServer(serverHandler, platform, &err) else {
            throw err ?? NSError(domain: "mbox", code: -3,
                                 userInfo: [NSLocalizedDescriptionKey: "CommandServer 创建失败"])
        }
        self.server = server
        TunnelDiag.log("✓ [2/6] CommandServer 已创建（传输=\(cmdPort == 0 ? "unix" : "tcp")）")
        let tServer = Date()
        do {
            try server.start()
            TunnelDiag.log("✓ [3/6] 命令服务已启动（\(Int(Date().timeIntervalSince(tServer) * 1000))ms）")
        } catch {
            let firstError = error
            TunnelDiag.log("✗ 命令服务启动失败: \(error.localizedDescription)")
            guard cmdPort != 0 else { throw firstError }
            // TCP 端口被占/被系统拒绝时退回 unix socket（短 basePath）
            TunnelDiag.log("退回 unix socket 重试 …")
            options.commandServerListenPort = 0
            var retryErr: NSError?
            guard LibboxSetup(options, &retryErr) else {
                throw retryErr ?? firstError
            }
            guard let server2 = LibboxNewCommandServer(serverHandler, platform, &retryErr) else {
                throw retryErr ?? firstError
            }
            self.server = server2
            try server2.start()
            TunnelDiag.log("✓ [3/6] 命令服务已启动（unix socket 兜底）")
        }

        // ---- [4/6] 真正启动内核（先服务、后日志客户端，顺序不能颠倒）----
        //
        // 踩过的坑：以前是「先连 CommandClient、再 startOrReloadService」，
        // 真机日志里就出现 `get default log level: rpc error: code = Unknown
        // desc = invalid argument` —— 服务还没起来，客户端就去查默认日志级别。
        // 官方用法（SFI）也是先起服务再连客户端，这里按同样顺序。
        let tStart = Date()
        var startError: Error?
        // ⚠️ options 绝对不能传 nil：sing-box 1.14.4 的
        // libbox.CommandServer.StartOrReloadService 第一行就无条件解引用
        // options.AutoRedirect / options.IncludePackage（command_server.go:203），
        // 传 nil 直接空指针崩溃 —— 真机日志就是
        // `SIGSEGV ... libbox.(*CommandServer).StartOrReloadService ... command_server.go:204`，
        // 扩展瞬间被杀，App 只看到「内核启动超时」。默认值（不重定向、不按应用分流）
        // 正好就是我们要的语义。
        let overrideOptions = LibboxOverrideOptions()
        overrideOptions.autoRedirect = false
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.startOrReloadService(configContent, options: overrideOptions)
            } catch {
                startError = error
            }
            done.signal()
        }
        let waited = done.wait(timeout: .now() + .seconds(15))
        let elapsed = Int(Date().timeIntervalSince(tStart) * 1000)
        if waited == .timedOut {
            TunnelDiag.log("✗ [4/6] 内核 Start 15s 未返回（卡在启动阶段）")
            TunnelDiag.dumpKernelLogTail(home: home)
            stop()
            throw NSError(domain: "mbox", code: -5, userInfo: [
                NSLocalizedDescriptionKey:
                    "内核启动超时（Start 15s 未返回）。诊断：\(TunnelDiag.kernelLogTail(home: home))"
            ])
        }
        if let startError {
            TunnelDiag.log("✗ [4/6] startOrReloadService 抛错（\(elapsed)ms）: "
                + "\(startError.localizedDescription)")
            TunnelDiag.dumpKernelLogTail(home: home)
            stop()
            throw startError
        }
        TunnelDiag.log("✓ [4/6] startOrReloadService 返回（\(elapsed)ms）")

        // ---- [5/6] 自查内核是否**真的在监听** Clash API ----
        //
        // 「Start 返回了」不等于「内核能转发」：真机上出现过 Start 正常返回、
        // 但 tun/dns 初始化有问题导致 API 一直不可用，最后 App 侧只看到
        // 「内核启动超时」。这里在扩展内自己探一次 /version（回环，不需要
        // 隧道），给出一条明确结论。
        let (coreUp, coreDetail) = probeCoreAPI(port: apiPort)
        if coreUp {
            TunnelDiag.log("✓ [5/6] 内核 API 就绪（\(coreDetail)）")
        } else {
            TunnelDiag.log("✗ [5/6] 内核 API 不可用（\(coreDetail)）—— 内核可能已起但监听失败")
            TunnelDiag.dumpKernelLogTail(home: home)
        }

        // ---- [6/6] 日志通道（放到最后：服务起来之后才连得上）----
        let clientOptions = LibboxCommandClientOptions()
        clientOptions.addCommand(LibboxCommandLog)
        if let client = LibboxNewCommandClient(clientHandler, clientOptions) {
            do {
                try client.connect()
                self.client = client
                TunnelDiag.log("✓ [6/6] 日志通道已连接")
            } catch {
                // 日志通道失败不影响内核运行（诊断仍能从 kernel.log 拿到）
                TunnelDiag.log("日志通道连接失败: \(error.localizedDescription)")
            }
        }

        guard coreUp else {
            stop()
            throw NSError(domain: "mbox", code: -6, userInfo: [
                NSLocalizedDescriptionKey:
                    "内核已启动但 API 不可用（\(coreDetail)）。诊断：\(TunnelDiag.kernelLogTail(home: home))"
            ])
        }
    }

    /// 扩展内自查内核 Clash API（127.0.0.1:<port>/version）。
    ///
    /// 判定：拿到 HTTP 响应（含 401/403 —— secret 不一致只影响热切换/测速）
    /// 就算内核活着；连不上/超时才算失败。
    private func probeCoreAPI(port: Int, timeout: TimeInterval = 6) -> (Bool, String) {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/version") else {
            return (false, "apiPort=\(port) 无效")
        }
        let sem = DispatchSemaphore(value: 0)
        var code = 0
        var note = "无响应"
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { _, resp, error in
            if let e = error { note = e.localizedDescription }
            if let http = resp as? HTTPURLResponse {
                code = http.statusCode
                note = "HTTP \(code)"
            }
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + timeout + 1) == .timedOut {
            return (false, "自查超时（\(Int(timeout))s）")
        }
        return (code > 0 && code < 500, note)
    }

    func reload(configContent: String) throws {
        let overrideOptions = LibboxOverrideOptions()
        overrideOptions.autoRedirect = false
        try server?.startOrReloadService(configContent, options: overrideOptions)
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
