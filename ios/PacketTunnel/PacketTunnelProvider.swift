import Darwin
import Foundation
import Network
import NetworkExtension
import ObjectiveC
import UIKit
import os.log

#if canImport(Libbox)
import Libbox
#endif

/// 直写 fd 的原始输出：不经 stdio / FileHandle 缓冲。
///
/// 为什么必须这样：内核静默死亡时（进程被 jetsam 杀掉 / Go fatal error 直接
/// abort），任何「排队等会儿再写」的日志都留在内存里一起消失 —— 真机踩到的
/// 现象就是轨迹永远停在最后一条、后面什么都没有。这里每次都是 write()，
/// 写进内核页缓存，别的进程（App）立刻能读到。
enum RawIO {
    static func write(_ fd: Int32, _ text: String) {
        guard fd >= 0 else { return }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                if n > 0 {
                    off += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                break
            }
        }
    }
}

/// 隧道启动诊断轨迹。
///
/// 为什么需要：扩展跑在独立进程里，它的 os_log 用户看不到；而「内核日志」
/// 只有在内核成功启动之后才会产出。一旦失败（扩展没起来 / 配置没拿到 /
/// fd 取不到 / 内核启动报错 / 进程被杀），App 侧只能看到一个干巴巴的
/// 「内核启动超时」，完全无法定位。这里把启动过程的每一步都记下来：
///   1) 内存环形缓冲 → App 通过 sendProviderMessage("diag") 实时取（扩展活着时）
///   2) App Group 的 tunnel.log → **每条同步直写**，扩展被杀也留得住
///   3) App Group 的 go-stderr.log → 内核（Go）的 stdout/stderr 全接管到这里，
///      Go 的 fatal error / panic 崩溃转储、logrus 输出都在里面
///   4) 心跳 → 死亡时间点（配合 RSS：能直接区分「被内存杀掉」与「卡死」）
enum TunnelDiag {
    private static let lock = NSLock()
    private static var memory: [String] = []
    private static let maxMemory = 400
    private static let appGroupId = "group.top.mbox.app"
    private static let start = Date()

    private static let diagFd = openShared("tunnel.log")
    private static let kernelFd = openShared("kernel.log")

    private static func openShared(_ name: String) -> Int32 {
        guard let container = sharedContainer() else { return -1 }
        return open(container.appendingPathComponent(name).path,
                    O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    private static func sharedContainer() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    static func log(_ message: String) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let line = "[\(ms)ms] \(message)"
        lock.lock()
        memory.append(line)
        if memory.count > maxMemory { memory.removeFirst(memory.count - maxMemory) }
        lock.unlock()
        RawIO.write(diagFd, line + "\n")
    }

    /// 心跳：只在启动窗口内落盘（20 次 ≈ 10s），之后只进内存环 ——
    /// 足够覆盖「内核启动期被杀」这个场景，又不会把轨迹文件撑爆。
    private static var beatsOnDisk = 0

    static func heartbeat(seq: Int, rssMB: Double) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let line = "[\(ms)ms] ♥ 心跳 #\(seq) 进程存活 RSS=\(String(format: "%.1f", rssMB))MB"
        lock.lock()
        memory.append(line)
        if memory.count > maxMemory { memory.removeFirst(memory.count - maxMemory) }
        let onDisk = beatsOnDisk < 20
        if onDisk { beatsOnDisk += 1 }
        lock.unlock()
        if onDisk { RawIO.write(diagFd, line + "\n") }
    }

    /// 当前轨迹（供 App 查询）。附上内核日志尾部 —— App Group 若失效，
    /// 内核日志文件写不进去，这是唯一的获取途径。
    static var trace: String {
        lock.lock()
        defer { lock.unlock() }
        var out = memory.joined(separator: "\n")
        if !kernelRing.isEmpty {
            out += "\n[内核日志尾部]\n" + kernelRing.joined(separator: "\n")
        }
        return out
    }

    /// 内核日志尾部（内存保留，避免 App Group 失效时完全看不到内核输出）
    private static var kernelRing: [String] = []
    private static let maxKernelRing = 120
    private static var kernelBytes = 0
    private static let maxKernelBytes = 1024 * 1024

    static func appendKernel(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        lock.lock()
        kernelRing.append(contentsOf: lines)
        if kernelRing.count > maxKernelRing {
            kernelRing.removeFirst(kernelRing.count - maxKernelRing)
        }
        kernelBytes += text.utf8.count
        let rotate = kernelBytes > maxKernelBytes
        if rotate { kernelBytes = 0 }
        lock.unlock()
        if rotate { _ = ftruncate(kernelFd, 0) }
        RawIO.write(kernelFd, text.hasSuffix("\n") ? text : text + "\n")
    }

    /// sing-box 自己写的日志（`log.output` 指向 `<home>/kernel.log`）尾部。
    ///
    /// 和上面的 kernelRing 不是一回事：kernelRing 是 libbox 通过 CommandClient
    /// 推给扩展的日志；这条路径是**内核直接写文件**，在 `Start` 卡死/CommandClient
    /// 通道还没建立时，只有这个文件里有内容（内核启动失败的真正原因通常在这里）。
    static func kernelLogTail(home: String, maxBytes: Int = 6000) -> String {
        let path = (home as NSString).appendingPathComponent("kernel.log")
        guard let fh = FileHandle(forReadingAtPath: path) else { return "（无 kernel.log）" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? "（kernel.log 为空）" : text
    }

    /// 把内核日志尾部写进诊断轨迹（同时进内存环与落盘文件，App 能直接看到）
    static func dumpKernelLogTail(home: String) {
        log("内核 kernel.log 尾部:\n" + kernelLogTail(home: home))
    }

    /// App Group 容器是否可用（不可用意味着共享配置/kernel.log 都拿不到）
    static var appGroupPath: String? { sharedContainer()?.path }

    /// 内核（Go）stdout/stderr 的落盘路径（供 App 事后读取崩溃转储）
    static var stderrPath: String? {
        sharedContainer()?.appendingPathComponent("go-stderr.log").path
    }

    /// 把本进程的 stdout/stderr 接管到 App Group 文件。
    ///
    /// Go 的 fatal error（runtime throw / OOM / 建线程失败）、goroutine panic、
    /// logrus 输出**全部走 fd 2**，在扩展进程里没人接 → 现场直接蒸发。
    /// 接管后这些内容会落盘，App 侧可读；顺带把「内核往 stdout 写」这件事
    /// 变成写普通文件（永不阻塞），排除日志通道卡死的可能。
    private static var stdioCaptured = false

    static func captureStdio() {
        guard !stdioCaptured else { return }
        stdioCaptured = true
        guard let container = sharedContainer() else { return }
        let path = container.appendingPathComponent("go-stderr.log").path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 512 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, 1)
        dup2(fd, 2)
        if fd > 2 { close(fd) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        RawIO.write(2, "\n=== 隧道进程启动 pid=\(getpid()) \(stamp) ===\n")
        log("内核 stdout/stderr 已接管 → go-stderr.log（Go 崩溃转储也会落这里）")
    }

    /// 内核 stderr 文件尾部（崩溃转储 / 致命错误现场）
    static func stderrTail(lines: Int = 80) -> String {
        guard let path = stderrPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.count <= lines { return text }
        return all.suffix(lines).joined(separator: "\n")
    }
}

/// **用户态桥**：把 `packetFlow`（文档 API）与内核要读写的 fd 对接起来。
///
/// 为什么需要它（真机实测结论，v2.2.13 / iOS 16.6.1 / iPhone14,3）：
///   `NEPacketTunnelFlow` 的 `_socket` ivar 类型是 `NSFileHandle` 且**恒为 nil**，
///   也就是说这个 iOS 版本上 flow 走的是新的 `NEVirtualInterface` 后端，
///   **根本不暴露 utun 的 fd** —— 社区常见的
///   `packetFlow.value(forKeyPath: "socket.fileDescriptor")` 在这里无解
///   （我们把 keyPath 扩到 13 条、轮询 49 次、还 kick 了 readPackets，全是 nil）。
///
/// 桥的做法：`socketpair(AF_UNIX, SOCK_DGRAM)` 造一对 fd，把其中一端交给内核，
/// 另一端由本类在两个方向上搬运数据包：
///   App → 隧道：`packetFlow.readPackets` → 加 4 字节地址族头 → `send()` 给内核
///   内核 → App：`recv()` 到 4 字节头 + IP 包 → 去头 → `packetFlow.writePackets`
/// 4 字节头是 sing-tun 在 Darwin 上的既定格式（`tun_darwin.go`：
/// `packetHeader4 = {0,0,0,AF_INET}`、`PacketOffset = 4`），已核对源码。
///
/// 好处：只用**文档 API + BSD socket**，不再依赖任何会随 iOS 版本变化的私有结构。
/// 代价：多一次用户态拷贝（实测吞吐仍远高于隧道本身带宽需求）。
final class PacketBridge {
    private let flow: NEPacketTunnelFlow
    /// 交给内核读写的那一端
    let kernelFd: Int32
    /// 桥自己这一端
    private let bridgeFd: Int32
    private var running = true

    private let queue = DispatchQueue(label: "top.mbox.tunnel.bridge")
    private var outPackets = 0   // App → 内核
    private var inPackets = 0    // 内核 → App
    private var dropped = 0
    /// 内核就绪前只排空 packetFlow、不投喂数据包。
    ///
    /// 两个目的：
    /// 1) 内核起来之前它自己的收发环还没跑，投进去只是白占 socketpair 缓冲；
    /// 2) 关键：**内核第一条数据包必须发生在「出站已绑定物理接口」的配置生效之后**，
    ///    否则内核可能对着自己的隧道发起出站连接 → 自环（真机实测过静默暴毙）。
    private var gateOpen = false

    func openGate() { gateOpen = true }

    init?(flow: NEPacketTunnelFlow) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            TunnelDiag.log("✗ socketpair 创建失败 errno=\(errno)")
            return nil
        }
        self.flow = flow
        self.bridgeFd = fds[0]
        self.kernelFd = fds[1]
        // 桥这侧用 poll 等数据，非阻塞写；内核侧由 sing-tun 自己 SetNonblock(false)
        _ = fcntl(bridgeFd, F_SETFL, O_NONBLOCK)
        TunnelDiag.log("✓ 用户态桥就绪：内核 fd=\(kernelFd) 桥 fd=\(bridgeFd)")
    }

    func start() {
        queue.async { [weak self] in self?.bridgeLoop() }
        pumpFromFlow()
    }

    func stop() {
        running = false
        close(bridgeFd)
        close(kernelFd)
    }

    var stats: String {
        "桥统计：App→内核 \(outPackets) 包 / 内核→App \(inPackets) 包 / 丢弃 \(dropped)"
    }

    /// 内核 → App：从桥这一端读「4 字节头 + IP 包」，去头后写回隧道
    private func bridgeLoop() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while running {
            var pfd = pollfd(fd: bridgeFd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            if ready <= 0 { continue }
            let n = recv(bridgeFd, &buf, buf.count, 0)
            if n > PacketBridge.headerLength {
                let af = Int32(buf[3])
                let packet = Data(buf[PacketBridge.headerLength..<Int(n)])
                inPackets += 1
                flow.writePackets([packet], withProtocols: [NSNumber(value: af)])
                if inPackets % 50 == 0 { TunnelDiag.log(stats) }
            } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                TunnelDiag.log("✗ 桥 recv 失败 errno=\(errno)")
                break
            }
        }
    }

    /// App → 内核：读隧道里的包，加 4 字节地址族头后交给内核
    private func pumpFromFlow() {
        flow.readPackets { [weak self] packets, protocols in
            guard let self, self.running else { return }
            for (i, packet) in packets.enumerated() {
                // 内核还没起来：照样把 flow 排空（不排空会让隧道看起来僵死），
                // 但不投喂内核 —— 见 gateOpen 的说明
                if !self.gateOpen {
                    self.dropped += 1
                    continue
                }
                let af: Int32 = i < protocols.count ? protocols[i].int32Value : AF_INET
                var framed = Data([0, 0, 0, UInt8(truncatingIfNeeded: af)])
                framed.append(packet)
                let sent = framed.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return send(self.bridgeFd, base, framed.count, 0)
                }
                if sent < 0 { self.dropped += 1 } else { self.outPackets += 1 }
                if self.outPackets % 50 == 0 { TunnelDiag.log(self.stats) }
            }
            if self.running { self.pumpFromFlow() }
        }
    }

    /// sing-tun 在 Darwin 上每个包前面都带 4 字节地址族头
    static let headerLength = 4
}

/// iOS 上的 sing-box 宿主：Packet Tunnel Provider 扩展。
///
/// 为什么必须在这里跑内核：iOS 沙箱禁止 App 建 utun 接口，只有拥有
/// `packet-tunnel-provider` entitlement 的 NetworkExtension 才能拿到隧道。
/// 所以内核以 gomobile 静态库（Libbox.xcframework，sing-box 官方核心）跑在本扩展进程内，
/// TUN fd 由 `packetFlow` 提供 —— sing-tun（sing-box 的 TUN 层）在 `FileDescriptor != 0`
/// 时会直接复用该 fd（sing-tun/tun_darwin.go），无需 root、无需自建接口。
///
/// 与 App 的分工：
/// - App：生成 config.json（sing-box 配置）→ 写入 App Group 共享目录 → 起隧道；
/// - 扩展：读 config.json → 下发网络参数 → 取 fd → 启动内核 → 抽日志到共享文件；
/// - 控制面（切节点/测速/流量）：App 直连扩展内内核的 Clash API 127.0.0.1:<apiPort>。
class PacketTunnelProvider: NEPacketTunnelProvider {

    /// sing-box 内核（libbox）引擎（旧的进程内库引擎已整体移除）
    private var engine: MBoxLibboxEngine?
    /// 本次启动用到的隧道 fd（openTun 时回给内核）
    private var tunnelFd: Int32 = -1


    private let log = OSLog(subsystem: "top.mbox.app.tunnel", category: "tunnel")

    /// 用户态桥（直连 fd 拿不到时启用；stopTunnel 时要关掉，否则 fd 泄漏）
    private var bridge: PacketBridge?
    private let appGroupId = "group.top.mbox.app"

    private var logPump: DispatchSourceTimer?
    private let logQueue = DispatchQueue(label: "top.mbox.tunnel.logpump")

    /// 网络路径监控：换网（WiFi↔蜂窝）时热更新内核的出站绑定接口。
    /// 不做这件事的话，绑定会停留在旧网卡上，换网后内核直接连不出去。
    private var pathMonitor: NWPathMonitor?
    private var boundInterface: String?
    private var apiPort = 9090
    private var apiSecret = ""

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        // 第一件事：接管 stdout/stderr。Go 的致命错误/崩溃转储全在 fd 2 上，
        // 扩展进程里没人接就永远查不到（真机「内核静默暴毙」只有这一条取证路）。
        TunnelDiag.captureStdio()
        TunnelDiag.log("=== startTunnel 进入 ===")
        TunnelDiag.log("系统=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            + " 机型=\(Self.hardwareModel())")
        TunnelDiag.log("App Group 容器: \(TunnelDiag.appGroupPath ?? "<不可用>")")
        TunnelDiag.log("启动前 RSS=\(Self.rssText())")
        TunnelDiag.log("系统物理路径: status=\(defaultPath?.status.rawValue ?? -1)")
        TunnelDiag.log("物理接口候选: \(Self.interfaceCandidates().joined(separator: ","))")
        startHeartbeat()

        // 立刻把「扩展已被系统拉起」这件事写进共享文件：即使后面任何一步失败，
        // App 侧也能凭这条区分「扩展根本没起来」和「扩展起来了但某步失败」。
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            TunnelDiag.log("✗ protocolConfiguration 类型不对")
            completionHandler(tunnelError("缺少隧道配置（protocolConfiguration）"))
            return
        }
        let conf = proto.providerConfiguration ?? [:]
        TunnelDiag.log("providerConfiguration keys: \(conf.keys.sorted())")
        let apiPortValue = (conf["apiPort"] as? NSNumber)?.intValue ?? 9090
        TunnelDiag.log("apiPort=\(apiPortValue)")

        // 配置正文：优先 App Group 共享文件（订阅可能很大，不适合塞进
        // providerConfiguration），回退内联字符串。
        var configText: String?
        var configSource = "none"
        if let path = conf["configPath"] as? String, !path.isEmpty {
            if let s = try? String(contentsOfFile: path, encoding: .utf8), !s.isEmpty {
                configText = s
                configSource = "file:\(path)"
            } else {
                TunnelDiag.log("✗ 共享配置文件不可读: \(path)")
            }
        }
        if configText == nil, let inline = conf["configInline"] as? String, !inline.isEmpty {
            configText = inline
            configSource = "inline"
        }
        guard let configJson = configText, !configJson.isEmpty else {
            TunnelDiag.log("✗ 没有可用配置（App Group 与内联都为空）")
            completionHandler(tunnelError("缺少内核配置（config.json 不可读）"))
            return
        }
        TunnelDiag.log("配置来源=\(configSource) 字节=\(configJson.utf8.count)")

        // 关键修复：把内核出站流量**钉在物理接口上**。
        //
        // iOS 上隧道一起来，系统的默认路由就指向我们自己的隧道；旧内核的
        // `auto-detect-interface` 会探到「默认接口 = 我们的隧道」，于是把自己
        // 的出站 socket 绑到隧道上 → 出站包被自己的隧道抓回来 → 内核再把它们
        // 转出去 → 无限自环。真机表现：内核刚起就静默死亡（内存/CPU 爆掉被系统
        // 杀掉），没有任何日志。
        //
        // 而旧内核里「同名才拦」的自环守卫（default interface == tun name）
        // 在 fd 注入场景下永远不会命中：socketpair 没有 utun 名字，tunName 只能
        // 是兜底值 "Meta"，和真实的隧道接口名对不上。
        //
        //        `interface-name` 的优先级高于 auto-detect（dialer.go：先看
        // DefaultInterface，为空才问 finder），所以这里显式写入物理接口名即可。
        apiPort = apiPortValue
        apiSecret = Self.extractSecret(from: configJson)
        var effectiveConfig = configJson
        if let iface = Self.pickPhysicalInterface() {
            effectiveConfig = Self.injectingInterfaceName(configJson, iface)
            boundInterface = iface
            TunnelDiag.log("内核出站绑定 interface-name=\(iface)（防自环）")
        } else {
            TunnelDiag.log("⚠ 取不到物理接口名（defaultPath.availableInterfaces 为空）"
                + " → 内核出站不绑定接口，存在自环风险")
        }
        // 工作目录（可写）：扩展自己的 Application Support。
        let home = ensureHomeDir()
        TunnelDiag.log("homeDir=\(home)")
        seedGeoFiles(into: home)

        // 规则集路径绝对化（关键：见 absolutizeRuleSetPaths 注释），
        // 同时把内核日志落到工作目录，启动 FATAL 才有据可查。
        effectiveConfig = Self.absolutizeRuleSetPaths(effectiveConfig, home: home)
        TunnelDiag.log("内核关键配置: \(Self.summarizeConfig(effectiveConfig))")

        // 下发 tunnel 网络参数。
        // IPv4 用 fake-ip 网段 198.18.0.0/16（与生成配置里的
        // fake-ip-range 198.18.0.1/16 一致）；DNS 指向 198.18.0.2，
        // 内核用 dns-hijack any:53 接管。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // 接口地址/MTU **取自配置里的 tun inbound**，不能手写常量。
        //
        // 为什么（参考 Hiddify 的 ExtensionPlatformInterface.openTun）：它直接用
        // libbox 给的 TunOptions（getInet4Address/getInet6Address/getMTU）去建
        // NEPacketTunnelNetworkSettings。如果这里写死 198.18.0.1/16、而配置里
        // tun.address 是 172.19.0.1/30，那么系统给应用分配的源地址与内核 gvisor
        // 栈自认的地址就不一致 —— 内核起来了也转发不通（包被当成「非本机」丢掉）。
        let tunSpec = Self.parseTunSpec(from: effectiveConfig)
        TunnelDiag.log("tun 规格: v4=\(tunSpec.ipv4) v6=\(tunSpec.ipv6) mtu=\(tunSpec.mtu)")
        let ipv4 = NEIPv4Settings(addresses: [tunSpec.ipv4Address],
                                  subnetMasks: [tunSpec.ipv4Mask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = Self.localExcludedRoutes
        settings.ipv4Settings = ipv4
        if tunSpec.ipv6Address != nil, let prefix = tunSpec.ipv6Prefix {
            let ipv6 = NEIPv6Settings(addresses: [tunSpec.ipv6Address!],
                                      networkPrefixLengths: [NSNumber(value: prefix)])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }
        // matchDomains=[""] + noSearch：让**所有** DNS 查询都进隧道（否则系统可能
        // 走自己的解析器，fake-ip 就失效了）。参考 Hiddify 的 ExtensionProvider 设置。
        // 服务器地址**不能用 fake-ip 段内的地址**（见 parseTunSpec 里的排查记录）。
        TunnelDiag.log("系统 DNS 下发: \(tunSpec.dnsServers.joined(separator: ","))")
        let dns = NEDNSSettings(servers: tunSpec.dnsServers)
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: tunSpec.mtu)

        TunnelDiag.log("调用 setTunnelNetworkSettings …")
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                TunnelDiag.log("✗ setTunnelNetworkSettings 失败: \(error.localizedDescription)")
                os_log("setTunnelNetworkSettings 失败: %{public}@", log: self.log,
                       type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            TunnelDiag.log("setTunnelNetworkSettings 成功")
            // 关键设计：**隧道参数下发成功即报告就绪**，内核随后异步启动。
            //
            // 之前是在内核 Start 返回后才 completionHandler —— 一旦 Start 卡住或
            // 失败，NE 会话会一直停在 connecting：App 既拿不到「已连接」，也无法用
            // sendProviderMessage 向扩展索取诊断（会话未就绪时该调用不可用），
            // 现场就变成「20 秒后内核启动超时」且**没有任何线索**（真机实测）。
            //
            // 现在语义清晰分层：
            //  - NE 状态 connected = 隧道接口与路由就绪（这是系统关心的）
            //  - App 侧「已连接」= Clash API 可达（由 Dart 就绪探测决定，逻辑不变）
            // 内核启动失败时用 cancelTunnelWithError 主动拿下隧道，并把原因写进轨迹。
            completionHandler(nil)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let acquired = try self.acquireKernelFd()
                    let fd = acquired.fd
                    self.bridge = acquired.bridge
                    TunnelDiag.log("取得隧道 fd=\(fd)"
                        + (acquired.bridge == nil ? "（直连）" : "（用户态桥）")
                        + " 类型=\(Self.socketTypeDescription(fd))")
                    // 先起日志抽取：内核的 Logs() 用的是独立锁，
                    // Start 卡住/失败期间也能读到启动日志（含它卡在哪一步）
                    self.startLogPump()
                    // 兜底：内核里任何相对路径都按工作目录解析（配置里已绝对化，
                    // 这条是给 cache.db 之类内部相对路径用的）
                    if !FileManager.default.changeCurrentDirectoryPath(home) {
                        TunnelDiag.log("⚠ 切换工作目录失败：\(home)（相对路径可能解析错）")
                    }
                    // kernel.log 每次启动清空：只保留本次启动的内核自述
                    let kernelLog = (home as NSString).appendingPathComponent("kernel.log")
                    try? "".write(toFile: kernelLog, atomically: false, encoding: .utf8)
                    TunnelDiag.log("调用内核前 RSS=\(Self.rssText())")
                    let t0 = Date()
                    try self.startEngine(home: home, json: effectiveConfig, fd: fd,
                                         apiPort: apiPortValue)
                    TunnelDiag.log("✓ 内核启动完成（耗时 "
                        + "\(Int(Date().timeIntervalSince(t0) * 1000))ms）RSS=\(Self.rssText())")
                    // 内核已按配置起好（出站绑定已在解析阶段生效）→ 放行数据包
                    self.bridge?.openGate()
                    // 放行后做一次真实 HTTPS 自测：这条请求会走系统默认路由
                    // → 进我们自己的 TUN → 由内核出站到代理节点。成功即证明
                    // 「TUN + 路由 + 出站」整条链路在转发（不只是进程活着）。
                    self.probeThroughTunnel()
                    self.probeApi(port: apiPortValue)
                    self.startPathWatch()
                } catch {
                    TunnelDiag.log("✗ 内核启动失败: \(error.localizedDescription)")
                    self.attachCrashContext()
                    // 拿掉隧道，让 App 侧立刻看到 disconnected + 本次轨迹
                    self.cancelTunnelWithError(error)
                }
            }
        }
    }

    /// 失败时把「内核 stderr（含 Go 崩溃转储）」与内存数据接进轨迹 ——
    /// App 侧只能读到轨迹文件，这是把内核现场带出去的唯一途径。
    private func attachCrashContext() {
        TunnelDiag.log("失败时 RSS=\(Self.rssText())")
        let tail = TunnelDiag.stderrTail(lines: 80)
        if tail.isEmpty {
            TunnelDiag.log("内核 stderr: 空（内核没来得及输出任何东西 —— "
                + "更像进程被系统直接杀掉，而不是内核自己报错）")
        } else {
            TunnelDiag.log("内核 stderr 尾部（含 Go 崩溃转储）:\n\(tail)")
        }
    }

    // MARK: - 进程自检（内存 / 心跳 / 物理接口）

    /// 本进程常驻内存（MB）。这是 jetsam（iOS 的内存杀手）唯一看的东西：
    /// 扩展的内存上限远低于 App，内核几个大分配就能顶上去 → 静默被杀。
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    static func rssText() -> String {
        String(format: "%.1fMB", residentMB())
    }

    private var heartbeatThread: Thread?
    private var heartbeatStop = false

    /// 心跳线程：进程还活着就每 0.5s 往轨迹里写一条（带内存）。
    /// 一旦轨迹里心跳断了，就是「进程在那一刻消失」的铁证 —— 死因再看 RSS
    /// 是涨上去的（内存被杀）还是平的（崩溃/被系统判定无响应）。
    private func startHeartbeat() {
        guard heartbeatThread == nil else { return }
        heartbeatStop = false
        let t = Thread { [weak self] in
            var seq = 0
            while let self, !self.heartbeatStop {
                seq += 1
                let rss = Self.residentMB()
                if seq % 2 == 0 { TunnelDiag.heartbeat(seq: seq / 2, rssMB: rss) }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        t.name = "mbox-heartbeat"
        t.stackSize = 256 * 1024
        heartbeatThread = t
        t.start()
    }

    private func stopHeartbeat() {
        heartbeatStop = true
        heartbeatThread = nil
    }

    /// 物理接口候选：UP、有 IP 地址、且不是隧道/回环/虚拟网卡。
    ///
    /// 为什么必须自己找：iOS 扩展里系统默认路由指向**我们自己的隧道**，
    /// 内核（以及任何「连一下公网再看本地地址」的探测）都会认为自己该走隧道，
    /// 于是把出站绑到隧道上 → 自环。只有把真实网卡枚举出来才能知道该绑谁。
    /// 顺序：en*（WiFi/以太网）→ pdp_ip*（蜂窝）→ 其余。
    static func interfaceCandidates() -> [String] {
        var names: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return names }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = cur.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard !Self.isVirtualInterface(name), !names.contains(name) else { continue }
            names.append(name)
        }
        let en = names.filter { $0.hasPrefix("en") }.sorted()
        let cell = names.filter { $0.hasPrefix("pdp_ip") }.sorted()
        let rest = names.filter { !en.contains($0) && !cell.contains($0) }.sorted()
        return en + cell + rest
    }

    static func isVirtualInterface(_ name: String) -> Bool {
        let banned = ["utun", "ipsec", "lo", "gif", "stf", "awdl", "llw",
                      "bridge", "nan", "p2p", "vmenet"]
        return banned.contains { name.hasPrefix($0) }
    }

    /// 内核出站要绑定的**物理**接口名（en0 / pdp_ip0 …）。
    /// 先看 Network.framework 当前路径，再用 getifaddrs 兜底。
    /// 挑「真正在用的物理出口」接口名（内核出站绑这个，防自环）。
    ///
    /// 旧实现直接读 `NWPathMonitor().currentPath.availableInterfaces.first`：
    /// 那个 monitor 刚创建、还没收到第一次 path update，`currentPath` 往往是
    /// 初始值（在双卡 + Wi-Fi 的机器上常见是 `pdp_ip0` 排在第一位）。真机日志里就是
    /// `物理出口接口=pdp_ip0` —— 而当时设备走的是 Wi-Fi（en0）。内核出站被绑到
    /// 蜂窝口后，所有出站连接都没有可用路由 → **连上了但一条流量都没有**。
    ///
    /// 现在：等 path 变成 satisfied，再按「path 声称在用的类型」挑同名接口。
    static func pickPhysicalInterface(timeout: TimeInterval = 1.5) -> String? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "top.mbox.path.pick")
        monitor.start(queue: queue)
        defer { monitor.cancel() }

        let deadline = Date().addingTimeInterval(timeout)
        var result: String?
        while Date() < deadline {
            let path = monitor.currentPath
            if path.status == .satisfied {
                let candidates = path.availableInterfaces.filter { !isVirtualInterface($0.name) }
                let wanted: NWInterface.InterfaceType? =
                    path.usesInterfaceType(.wifi) ? .wifi
                    : path.usesInterfaceType(.cellular) ? .cellular
                    : path.usesInterfaceType(.wiredEthernet) ? .wiredEthernet
                    : nil
                if let wanted, let hit = candidates.first(where: { $0.type == wanted }) {
                    result = hit.name
                    break
                }
                if let first = candidates.first {
                    result = first.name
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // NWPath.status / NWInterface.InterfaceType 都没有 rawValue：
        // 用独立变量拼日志，避免编译器在长表达式上超时。
        let path = monitor.currentPath
        let statusText: String
        switch path.status {
        case .satisfied:     statusText = "satisfied"
        case .unsatisfied:   statusText = "unsatisfied"
        case .requiresConnection: statusText = "requiresConnection"
        @unknown default:    statusText = "unknown"
        }
        let typeText: (NWInterface) -> String = { iface in
            switch iface.type {
            case .wifi:           return "\(iface.name):wifi"
            case .cellular:       return "\(iface.name):cellular"
            case .wiredEthernet:  return "\(iface.name):wired"
            case .loopback:       return "\(iface.name):loopback"
            case .other:          return "\(iface.name):other"
            @unknown default:     return iface.name
            }
        }
        let names = path.availableInterfaces.map(typeText).joined(separator: ",")
        let onWifi = path.usesInterfaceType(.wifi)
        let onCell = path.usesInterfaceType(.cellular)
        TunnelDiag.log("物理路径: status=\(statusText) wifi=\(onWifi) cellular=\(onCell)"
            + " 候选=[\(names)] → 选中=\(result ?? "无")")

        if let result { return result }
        let fallback = interfaceCandidates().first
        if fallback != nil {
            TunnelDiag.log("⚠ 没等到 satisfied path，退回候选表第一个: \(fallback!)")
        }
        return fallback
    }

    /// 把内核出站钉在物理接口上（sing-box JSON 版）。
    ///
    /// 为什么必须：隧道一起来，系统默认路由就指向我们自己的隧道；若内核
    /// 自动探测出口接口，会探到「默认接口 = 自己的隧道」→ 出站包被自己的
    /// TUN 抓回来 → 自环（真机表现：内核刚起就被系统杀掉、零日志）。
    /// sing-box 的对应字段是 `route.default_interface` +
    /// `route.auto_detect_interface=false`。
    static func injectingInterfaceName(_ json: String, _ name: String) -> String {
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [String: Any] else { return json }
        var route = (obj["route"] as? [String: Any]) ?? [:]
        route["auto_detect_interface"] = false
        route["default_interface"] = name
        obj["route"] = route
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else {
            return json
        }
        return String(data: data, encoding: .utf8) ?? json
    }

    /// 只挑关键字段记进轨迹：出问题时能一眼看出内核到底吃到了什么配置
    /// （栈 / mtu / 出站接口 / 模式 / API 端口）。
    static func summarizeConfig(_ json: String) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [String: Any] else { return "<配置非合法 JSON>" }
        var parts: [String] = []
        if let log = obj["log"] as? [String: Any], let level = log["level"] {
            parts.append("log=\(level)")
        }
        if let inbounds = obj["inbounds"] as? [[String: Any]] {
            for ib in inbounds {
                let type = (ib["type"] as? String) ?? "?"
                if type == "tun" {
                    parts.append("tun(stack=\(ib["stack"] ?? "?") mtu=\(ib["mtu"] ?? "?") "
                        + "auto_route=\(ib["auto_route"] ?? "?"))")
                } else {
                    parts.append("\(type)(port=\(ib["listen_port"] ?? "?"))")
                }
            }
        }
        if let route = obj["route"] as? [String: Any] {
            parts.append("final=\(route["final"] ?? "?")")
            parts.append("default_if=\(route["default_interface"] ?? "-")")
            if let rs = route["rule_set"] as? [[String: Any]] {
                parts.append("rule_set=\(rs.count)")
            }
        }
        if let exp = obj["experimental"] as? [String: Any],
           let api = exp["clash_api"] as? [String: Any] {
            parts.append("api=\(api["external_controller"] ?? "?")")
            parts.append("mode=\(api["default_mode"] ?? "?")")
        }
        return parts.joined(separator: " ")
    }

    /// 从 sing-box 配置里抠出 Clash API 的 secret（网络切换时要带鉴权
    /// PATCH /configs）
    static func extractSecret(from json: String) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [String: Any],
            let exp = obj["experimental"] as? [String: Any],
            let api = exp["clash_api"] as? [String: Any],
            let secret = api["secret"] as? String else { return "" }
        return secret
    }

    /// 盯住网络路径：物理出口换了就热更新内核绑定（Clash API PATCH /configs，
    /// 内核侧直接改默认接口绑定，不断流、不重启内核）。
    private func startPathWatch() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            guard self.pathMonitor != nil else { return }
            let next = path.availableInterfaces
                .map(\.name)
                .first { !Self.isVirtualInterface($0) }
                ?? Self.interfaceCandidates().first
            guard let next, next != self.boundInterface else { return }
            TunnelDiag.log("网络切换：物理接口 \(self.boundInterface ?? "-") → \(next)，热更新内核出站绑定")
            self.boundInterface = next
            self.patchInterfaceName(next)
        }
        monitor.start(queue: DispatchQueue(label: "top.mbox.tunnel.pathwatch"))
        pathMonitor = monitor
        TunnelDiag.log("网络路径监控已启动（当前绑定 \(boundInterface ?? "-")）")
    }

    private func stopPathWatch() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func patchInterfaceName(_ name: String) {
        guard let url = URL(string: "http://127.0.0.1:\(apiPort)/configs") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiSecret.isEmpty {
            req.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["interface-name": name])
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err {
                TunnelDiag.log("接口热更新失败: \(err.localizedDescription)")
            } else {
                TunnelDiag.log("接口热更新 → \(name) HTTP "
                    + "\((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
        }.resume()
    }

    /// 从**扩展进程内**访问内核 Clash API —— 决定性自检：
    /// - 能连上（200/401 都算连上）→ 内核与 API 都正常，问题在 App↔扩展 的路径
    /// - 连不上 → 内核没起来或 API 没监听
    /// 这段结果会进诊断轨迹，App 侧失败时一并展示。
    private func probeApi(port: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/version") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                TunnelDiag.log("API 自检(扩展内) 失败: \(err.localizedDescription)")
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            TunnelDiag.log("API 自检(扩展内) HTTP \(code) \(body.prefix(80))")
        }.resume()
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        TunnelDiag.log("=== stopTunnel reason=\(reason.rawValue) === RSS=\(Self.rssText())")
        os_log("stopTunnel reason=%d", log: log, type: .info, reason.rawValue)
        stopHeartbeat()
        stopPathWatch()
        stopLogPump()
        engine?.stop()
        engine = nil
        tunnelFd = -1
        // 用户态桥必须显式关掉：否则 socketpair 的两个 fd 会留在扩展进程里
        if let bridge {
            TunnelDiag.log(bridge.stats)
            bridge.stop()
            self.bridge = nil
        }
        completionHandler()
    }

    /// App 通过 `NETunnelProviderSession.sendProviderMessage` 发来的消息
    override func handleAppMessage(_ messageData: Data,
                                  completionHandler: ((Data?) -> Void)?) {
        let cmd = String(data: messageData, encoding: .utf8) ?? ""
        switch cmd {
        case "status":
            let alive = (engine != nil)
            TunnelDiag.log("handleAppMessage(status) → \(alive ? "running" : "stopped")")
            completionHandler?(alive ? Data("running".utf8) : Data("stopped".utf8))
        case "version":
            #if canImport(Libbox)
            completionHandler?(Data(MBoxLibboxEngine.version().utf8))
            #else
            completionHandler?(Data("unknown".utf8))
            #endif
        case "diag":
            // 关键诊断通道：App 侧连接失败时拉取本扩展的启动轨迹
            TunnelDiag.log("handleAppMessage(diag) 被调用")
            completionHandler?(Data(TunnelDiag.trace.utf8))
        default:
            completionHandler?(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        TunnelDiag.log("sleep")
        completionHandler()
    }

    override func wake() {}

    /// openTun 时刻再取一次「真实 utun fd」。
    ///
    /// 返回 >2 表示拿到了：此时内核直接读写系统 utun，用户态桥立刻停掉
    /// （否则两个 reader 抢同一个 packetFlow，包会丢）。
    /// 返回 -1 表示拿不到，让平台接口继续用启动前准备好的桥 fd。
    private func resolveRealTunnelFdNow() -> Int32 {
        guard let hit = probeTunnelFd() else {
            TunnelDiag.log("openTun 时刻仍取不到真实 utun fd（来源探测全部为空）")
            return -1
        }
        TunnelDiag.log("✓ openTun 时刻拿到真实 utun fd=\(hit.fd)（来源=\(hit.source)）→ 停用用户态桥")
        bridge?.stop()
        bridge = nil
        return hit.fd
    }

    /// 端到端自测：隧道放行后从扩展里发一个真实 HTTPS 请求。
    ///
    /// 为什么放在扩展里：App 侧的就绪判定只看 Clash API（内核活着）。
    /// 但真机上出现过「内核活着、API 正常、却因为 TUN/路由问题转发不通」——
    /// 那条路径 App 侧表现为「连上了但没网」。这里直接打一次外网，
    /// 把结论写进诊断轨迹（失败不致命，只做记录）。
    private func probeThroughTunnel() {
        guard let url = URL(string: "https://www.gstatic.com/generate_204") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let e = err {
                TunnelDiag.log("△ 隧道自测失败（不影响内核运行）: \(e.localizedDescription)")
                return
            }
            if let http = resp as? HTTPURLResponse {
                TunnelDiag.log("✓ 隧道自测通过（HTTP \(http.statusCode)）—— TUN 与出站都在转发")
            } else {
                TunnelDiag.log("△ 隧道自测无响应")
            }
        }.resume()
    }

    /// 从生成好的 sing-box 配置里取出 tun inbound 的地址与 MTU。
    ///
    /// 与 Hiddify 用 libbox 的 `TunOptions` 取值是同一个目的：让「系统侧接口参数」
    /// 与「内核 gvisor 栈自认的参数」完全一致。缺省回退到 172.19.0.1/30（生成器
    /// 的默认值），保证解析失败也不会让隧道起不来。
    private struct TunSpec {
        var ipv4Address: String
        var ipv4Mask: String
        var ipv4: String
        var ipv6Address: String?
        var ipv6Prefix: Int?
        var ipv6: String
        var mtu: Int
        /// 下发给系统的 DNS 服务器地址（**必须落在 fake-ip 段之外**）
        var dnsServers: [String]
    }

    private static func parseTunSpec(from json: String) -> TunSpec {
        var spec = TunSpec(ipv4Address: "172.19.0.1", ipv4Mask: "255.255.255.252",
                           ipv4: "172.19.0.1/30", ipv6Address: nil, ipv6Prefix: nil,
                           ipv6: "无", mtu: 1500, dnsServers: ["223.5.5.5"])
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let inbounds = root["inbounds"] as? [[String: Any]] else { return spec }
        guard let tun = inbounds.first(where: { ($0["type"] as? String) == "tun" }) else {
            return spec
        }
        if let mtu = tun["mtu"] as? Int, mtu > 0 { spec.mtu = mtu }
        // 系统 DNS 用配置里**真实的上游解析器**（跳过 fakeip / local）：
        // 排查记录 —— 之前下发 198.18.0.2，而 fake-ip 段是 198.18.0.0/15，
        // 内核把「发往 198.18.0.2:53 的 DNS 包」当成 fake-ip 目标去查映射，
        // 查到没有就报 `router: missing fakeip record, try enable
        // experimental.cache_file`，DNS 永远解析不成功 → 连上但打不开网页。
        if let dns = root["dns"] as? [String: Any],
           let dnsServers = dns["servers"] as? [[String: Any]] {
            var real: [String] = []
            for srv in dnsServers {
                let type = (srv["type"] as? String) ?? "udp"
                if type == "fakeip" || type == "local" { continue }
                guard let host = srv["server"] as? String, !host.isEmpty else { continue }
                // 只要 IP 字面量（域名型 DoH 不能当系统 DNS 用）
                let ip = host.split(separator: ":").first.map(String.init) ?? host
                let isIP = ip.contains(".") ? ip.split(separator: ".").count == 4 : ip.contains(":")
                if isIP { real.append(ip) }
            }
            if !real.isEmpty { spec.dnsServers = real }
        }

        let addrs = (tun["address"] as? [String]) ?? []
        for addr in addrs {
            let parts = addr.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { continue }
            let ip = String(parts[0])
            if ip.contains(":") {
                spec.ipv6Address = ip
                spec.ipv6Prefix = prefix
                spec.ipv6 = addr
            } else if spec.ipv4 == "172.19.0.1/30" {   // 只取第一个 IPv4
                spec.ipv4 = addr
                spec.ipv4Address = ip
                spec.ipv4Mask = Self.maskString(prefix: prefix)
            }
        }
        return spec
    }

    private static func maskString(prefix: Int) -> String {
        guard prefix > 0, prefix <= 32 else { return "0.0.0.0" }
        var mask: UInt32 = prefix == 32 ? 0xFFFF_FFFF : (~UInt32(0) << (32 - UInt32(prefix)))
        var octets: [String] = []
        for _ in 0..<4 {
            octets.append(String(mask >> 24))
            mask = (mask << 8) & 0xFFFF_FFFF
        }
        return octets.joined(separator: ".")
    }

    /// 打印 fd 的 socket 类型（SOCK_DGRAM / SOCK_STREAM / 非 socket）。
    ///
    /// 为什么要打：gVisor 的 fdbased 端点要求 fd 是**数据报**语义（一个 recvmsg
    /// 一个包）。真机排查「内核起来了但流量不通」时，这条信息能立刻排除
    /// 「fd 类型不对」这一类原因。
    private static func socketTypeDescription(_ fd: Int32) -> String {
        guard fd >= 0 else { return "fd<0" }
        var type: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let rc = getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len)
        guard rc == 0 else { return "非 socket（getsockopt errno=\(errno)）" }
        switch type {
        case SOCK_DGRAM: return "SOCK_DGRAM"
        case SOCK_STREAM: return "SOCK_STREAM"
        case SOCK_RAW: return "SOCK_RAW"
        default: return "type=\(type)"
        }
    }

    // MARK: - 内核

    private func startEngine(home: String, json: String, fd: Int32, apiPort: Int) throws {
        #if canImport(Libbox)
        let engine = MBoxLibboxEngine()
        engine.setTunnelFd(fd)
        // openTun 那一刻再试一次真实 utun fd：拿到就用它、并停掉用户态桥
        // （两个 reader 同时读 packetFlow 会互相抢包）。
        engine.setFdResolver { [weak self] in self?.resolveRealTunnelFdNow() ?? -1 }
        engine.setPhysicalInterface(boundInterface)
        self.engine = engine
        self.tunnelFd = fd
        TunnelDiag.log("调用 libbox 启动内核（内核版本 \(MBoxLibboxEngine.version())）…")
        let began = Date()
        do {
            try engine.start(home: home, configContent: json, apiPort: apiPort)
        } catch {
            let cost = Int(Date().timeIntervalSince(began) * 1000)
            TunnelDiag.log("✗ libbox 启动失败（\(cost)ms）: \(error.localizedDescription)")
            throw tunnelError("内核启动失败：\(error.localizedDescription)")
        }
        let cost = Int(Date().timeIntervalSince(began) * 1000)
        TunnelDiag.log("✓ libbox 启动成功（\(cost)ms）")
        #else
        TunnelDiag.log("✗ 此构建未链接 Libbox.xcframework")
        throw tunnelError("此构建未包含内核（Libbox.xcframework 缺失）")
        #endif
    }

    private struct FdHit {
        let fd: Int32
        let source: String
    }

    /// `packetFlow` 上可能挂着底层 socket fd 的 keyPath（按历史/版本从常用到冷门）
    private static let flowFdPaths = [
        "socket.fileDescriptor",
        "socket.fd",
        "socket._fileDescriptor",
        "socket.fileDescriptor.fileDescriptor",
        "_socket.fileDescriptor",
        "_socket.fd",
        "socket.socket.fileDescriptor",
        "tunnelFlow.socket.fileDescriptor",
        "socket.fileDescriptor.fileDescriptor.fileDescriptor",
    ]

    /// 少数版本把 fd 挂在 provider 自己身上
    private static let providerFdPaths = [
        "tunnelFileDescriptor",
        "_tunnelFileDescriptor",
        "socket.fileDescriptor",
        "packetFlow.socket.fileDescriptor",
    ]

    /// 取隧道 fd：**轮询 + 多路径 + 运行时兜底 + 失败时打印真实结构**。
    ///
    /// 为什么不能像旧版那样「取一次、三条 KVC、失败就报错」：
    /// 真机日志（TrollStore / iOS，v2.2.10）显示
    ///     [320ms] setTunnelNetworkSettings 成功
    ///     [321ms] socket.fileDescriptor / socket.fd / socket.fileDescriptor.fileDescriptor 全 nil
    ///     [322ms] ✗ 内核启动失败: 无法获取隧道 fd
    /// 三条路径都返回 nil 而**没有抛 NSUnknownKeyException**，说明 `_socket` 这个
    /// ivar 是存在的、只是**值为 nil** —— `NEPacketTunnelFlow` 内部那个 socket 由
    /// 系统在隧道真正 up 之后才**懒创建**，而我们比它早了 1ms 去取。
    ///
    /// 现在：轮询重试（默认 6s）→ 仍取不到就 kick 一次 `readPackets`（**文档 API**，
    /// 会迫使内部 socket 建立）→ 再取不到就把 packetFlow / provider 的**真实 ivar
    /// 结构**写进诊断轨迹，下一版可按图索骥，而不是继续猜。
    ///
    /// 注：取 fd 本身用私有 KVC，因此仅适用于侧载（TrollStore / 自签），不上 App Store。
    /// 取得给内核用的 fd：**先试直连，再退回用户态桥**。
    ///
    /// - 直连：老 iOS / 某些机型上 `packetFlow` 会暴露 utun fd（省掉一次拷贝）；
    /// - 桥：iOS 16.4+ 的 `NEVirtualInterface` 后端不再暴露 fd（本机实测），
    ///   用 socketpair 自己搬运数据包。
    private func acquireKernelFd() throws -> (fd: Int32, bridge: PacketBridge?) {
        // 直连只做一次短探测（0.5s）：真机实测 iOS 16.6.1 上 `_socket` 恒为 nil，
        // 等久了只是白拖慢连接；但其它 iOS 版本上它可能一次就成（省掉一次用户态拷贝）
        if let fd = try? tunnelFileDescriptor(timeout: 0.5) {
            return (fd, nil)
        }
        TunnelDiag.log("直连 fd 不可得 → 改用 socketpair 用户态桥（只用文档 API）")
        guard let bridge = PacketBridge(flow: packetFlow) else {
            throw tunnelError("无法建立隧道 fd，且用户态桥创建失败")
        }
        bridge.start()
        return (bridge.kernelFd, bridge)
    }

    private func tunnelFileDescriptor(timeout: TimeInterval = 6) throws -> Int32 {
        let started = Date()
        var attempt = 0
        var kicked = false
        while Date().timeIntervalSince(started) < timeout {
            attempt += 1
            if let hit = probeTunnelFd() {
                TunnelDiag.log("取得隧道 fd=\(hit.fd)（来源=\(hit.source)，第 \(attempt) 次尝试，"
                    + "耗时 \(Int(Date().timeIntervalSince(started) * 1000))ms）")
                return hit.fd
            }
            if !kicked && attempt >= 3 {
                kicked = true
                TunnelDiag.log("fd 仍为空 → kick packetFlow.readPackets 强制建立内部 socket")
                kickPacketFlow()
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        dumpTunnelStructure()
        throw tunnelError("无法获取隧道 fd（已轮询 \(attempt) 次 / \(Int(timeout))s；"
            + "packetFlow 与 provider 的真实结构已写入诊断轨迹）")
    }

    /// 单次探测：先试已知 keyPath，再用 Objective-C runtime 兜底找 fd 形状的 ivar
    private func probeTunnelFd() -> FdHit? {
        for p in Self.flowFdPaths {
            if let fd = Self.intValue(of: packetFlow, keyPath: p), fd > 2 {
                return FdHit(fd: fd, source: "packetFlow.\(p)")
            }
        }
        for p in Self.providerFdPaths {
            if let fd = Self.intValue(of: self, keyPath: p), fd > 2 {
                return FdHit(fd: fd, source: "provider.\(p)")
            }
        }
        if let fd = Self.runtimeFindFd(in: packetFlow, depth: 0) {
            return FdHit(fd: fd, source: "runtime(packetFlow)")
        }
        if let fd = Self.runtimeFindFd(in: self, depth: 0) {
            return FdHit(fd: fd, source: "runtime(provider)")
        }
        return nil
    }

    /// 用**文档 API** `readPackets` 踢一脚：内部 socket 只有在第一次读包时才会
    /// 真正建立（这就是我们 1ms 取不到 fd 的原因）。
    /// 代价：这一下可能吃掉极少量「刚进隧道」的包（TCP 会重传、DNS 会重试），
    /// 属于一次性代价，且只在轮询 3 次仍失败时才做。
    private func kickPacketFlow() {
        packetFlow.readPackets { _, _ in
            TunnelDiag.log("kick 完成（readPackets 返回，socket 应已建立）")
        }
    }

    // MARK: - 安全取属性（绝不因为 key 不存在而崩扩展）

    /// 该 ivar 是否适合走 KVC（对象 / 数字 / 布尔）。
    ///
    /// struct（类型编码 `{...}`）、数组 `[...]`、联合与位域 `(...)` 走 KVC 会抛
    /// `NSUnknownKeyException` —— Swift 捕获不到，会**直接把扩展干崩**。
    /// 结构 dump 会遍历所有 ivar，所以必须先按类型编码过滤。
    private static func isKvcSafeIvar(_ ivar: Ivar) -> Bool {
        guard let encPtr = ivar_getTypeEncoding(ivar),
              let first = String(cString: encPtr).first else { return false }
        return "@cislqCISLQfdB".contains(first)
    }

    /// 是否存在该 ivar（含沿父类链查找 `_name` / `name` 两种写法）
    private static func hasIvar(_ obj: AnyObject, _ name: String) -> Bool {
        var cls: AnyClass? = object_getClass(obj)
        while let c = cls {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(c, &count) {
                for i in 0..<Int(count) {
                    if let n = ivar_getName(ivars[i]), String(cString: n) == name {
                        free(ivars)
                        return true
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(c)
        }
        return false
    }

    /// 读一段属性路径：逐段检查「有 getter 或有同名 ivar」后再取值。
    /// `value(forKeyPath:)` 对完全不存在的 key 会抛 NSUnknownKeyException（Swift
    /// 捕获不到，直接把扩展干崩），所以这里必须自己逐段检查。
    private static func safeGet(_ obj: AnyObject, _ segment: String) -> Any? {
        if obj.responds(to: NSSelectorFromString(segment)) {
            return obj.value(forKey: segment)
        }
        let candidates = ["_\(segment)", segment]
        if candidates.contains(where: { hasIvar(obj, $0) }) {
            return obj.value(forKey: segment)
        }
        return nil
    }

    /// 取整型属性（支持 a.b.c 路径）
    private static func intValue(of obj: AnyObject, keyPath: String) -> Int32? {
        var current: AnyObject? = obj
        for seg in keyPath.split(separator: ".") {
            guard let cur = current else { return nil }
            guard let next = safeGet(cur, String(seg)) else { return nil }
            current = next as AnyObject
        }
        guard let v = current else { return nil }
        if let n = v as? NSNumber { return n.int32Value }
        if let i = v as? Int { return Int32(i) }
        if let i = v as? Int32 { return i }
        if let i = v as? Int64 { return Int32(i) }
        if let i = v as? UInt32 { return Int32(i) }
        return nil
    }

    /// runtime 兜底：递归找「名字像 fd、值也像 fd」的 ivar（跨 iOS 版本自适应）。
    /// 名字优先匹配 fd/fileDescriptor/socket，避免误取无关整型。
    private static func runtimeFindFd(in obj: AnyObject, depth: Int) -> Int32? {
        guard depth <= 3 else { return nil }
        var cls: AnyClass? = object_getClass(obj)
        var visited = 0
        while let c = cls, visited < 6 {
            visited += 1
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(c, &count) {
                for i in 0..<Int(count) {
                    guard let namePtr = ivar_getName(ivars[i]) else { continue }
                    let name = String(cString: namePtr)
                    let lower = name.lowercased()
                    let looksLikeFd = lower.contains("fd") || lower.contains("filedescriptor")
                        || lower.contains("socket") || lower.contains("tunnel")
                    guard looksLikeFd, isKvcSafeIvar(ivars[i]) else { continue }
                    if let v = safeGet(obj, name.hasPrefix("_") ? String(name.dropFirst()) : name) {
                        if let n = v as? NSNumber, n.int32Value > 2 { free(ivars); return n.int32Value }
                        if let n = v as? Int, n > 2 { free(ivars); return Int32(n) }
                        let child = v as AnyObject
                        if String(describing: type(of: child)).hasPrefix("NS") == false
                            || String(describing: type(of: child)).hasPrefix("NE") {
                            if let fd = runtimeFindFd(in: child, depth: depth + 1) {
                                free(ivars)
                                return fd
                            }
                        }
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(c)
        }
        return nil
    }

    /// 全部策略失败时，把真实结构写进诊断轨迹（下一版据此精确取 fd）
    private func dumpTunnelStructure() {
        TunnelDiag.log("—— packetFlow 结构（取不到 fd 时供定位）——")
        TunnelDiag.log(Self.describe(packetFlow, depth: 0))
        TunnelDiag.log("—— provider 结构 ——")
        TunnelDiag.log(Self.describe(self, depth: 0))
    }

    private static func describe(_ obj: AnyObject, depth: Int) -> String {
        guard depth <= 2 else { return "…" }
        let indent = String(repeating: "  ", count: depth)
        var lines = ["\(indent)\(type(of: obj)) {"]
        var cls: AnyClass? = object_getClass(obj)
        var visited = 0
        while let c = cls, visited < 4 {
            visited += 1
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(c, &count) {
                for i in 0..<Int(count) {
                    guard let namePtr = ivar_getName(ivars[i]) else { continue }
                    let name = String(cString: namePtr)
                    let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? "?"
                    let plain = name.hasPrefix("_") ? String(name.dropFirst()) : name
                    var valueDesc = "<非 KVC 类型，跳过取值>"
                    if isKvcSafeIvar(ivars[i]), let v = safeGet(obj, plain) {
                        valueDesc = "<取不到>"
                        if let n = v as? NSNumber {
                            valueDesc = "\(n)"
                        } else {
                            valueDesc = String(describing: v)
                            if valueDesc.count > 80 { valueDesc = String(valueDesc.prefix(80)) + "…" }
                            lines.append("\(indent)  \(name): \(type) = \(valueDesc)")
                            lines.append(describe(v as AnyObject, depth: depth + 1))
                            continue
                        }
                    } else if isKvcSafeIvar(ivars[i]) {
                        valueDesc = "<取不到>"
                    }
                    lines.append("\(indent)  \(name): \(type) = \(valueDesc)")
                }
                free(ivars)
            }
            cls = class_getSuperclass(c)
        }
        lines.append("\(indent)}")
        return lines.joined(separator: "\n")
    }

    /// 机型标识（诊断用：不同机型/系统版本的私有结构可能不同）
    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(v)))) }
        }
    }

    /// 排除本机/内网段，避免 TUN 接管本机与局域网流量
    private static var localExcludedRoutes: [NEIPv4Route] {
        [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
        ]
    }

    // MARK: - 目录与 geo

    /// 扩展可写工作目录（config.json 与 cache.db 落这里）
    private func ensureHomeDir() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("singbox", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
    }

    /// 把随扩展 bundle 分发的 geo 数据复制进工作目录（仅缺失时，幂等）。
    /// 内核配置里 geo-auto-update=false，必须本地就位，否则 GEOSITE/GEOIP
    /// 规则会让内核对 GitHub 发起下载（国内直连被墙 → 启动卡死）。
    /// 内核启动前把离线数据落到它自己的 homeDir（仅缺文件或大小变化时才复制）。
    ///
    /// cn.mrs 是 iOS 智能分流的**关键**：GEOSITE,cn 的 succinct 匹配器启动期要
    /// 申请约 74MB 堆（本机实测 HeapAlloc 峰值 74MB / RSS 167MB），而 iOS 网络扩展
    /// 的内存上限只有几十 MB —— 真机表现就是内核刚起 200ms 就被系统杀掉，且日志一
    /// 行都没有。.mrs 是 zstd+可直接查表的格式（实测规则数 111021、堆 +2MB），
    /// 用 RULE-SET,cn 替代 GEOSITE,cn 后启动从 146ms/167MB 降到 15ms/50MB。
    /// 把配置里的规则集路径改成**绝对路径**（指向扩展自己的工作目录），
    /// 并把内核日志落到 `home/kernel.log`。
    ///
    /// 为什么必须绝对化：App 生成 iOS 配置时传的是相对文件名（`geosite-cn.srs`），
    /// 而 sing-box 打开 rule-set 用的是**进程当前工作目录** —— NetworkExtension
    /// 进程的 CWD 一般是 `/`，不是我们的工作目录。结果内核启动直接 FATAL
    /// （`open geosite-cn.srs: no such file or directory`），真机表现就是
    /// 「隧道一起来内核立刻退出、App 只看到内核启动超时」。
    ///
    /// 缺失的规则集不是让整份配置崩掉，而是**连同引用它的规则一起摘掉**：
    /// 分流退化成全代理，但连接能起来（可用性优先）。
    private static func absolutizeRuleSetPaths(_ json: String, home: String) -> String {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              var route = root["route"] as? [String: Any] else {
            TunnelDiag.log("⚠ 配置解析失败，跳过规则集路径绝对化")
            return json
        }

        var droppedTags = Set<String>()
        if var sets = route["rule_set"] as? [[String: Any]] {
            for i in sets.indices {
                guard let tag = sets[i]["tag"] as? String,
                      var path = sets[i]["path"] as? String, !path.isEmpty else { continue }
                if !path.hasPrefix("/") {
                    path = (home as NSString).appendingPathComponent(path)
                }
                let exists = FileManager.default.fileExists(atPath: path)
                sets[i]["path"] = path
                if !exists {
                    droppedTags.insert(tag)
                    TunnelDiag.log("⚠ rule-set 不存在，摘掉: \(path)")
                } else {
                    TunnelDiag.log("rule-set 绝对路径: \(path)")
                }
            }
            if !droppedTags.isEmpty {
                sets.removeAll { droppedTags.contains(($0["tag"] as? String) ?? "") }
            }
            route["rule_set"] = sets
        }

        if !droppedTags.isEmpty, var rules = route["rules"] as? [[String: Any]] {
            let before = rules.count
            rules.removeAll { rule in
                guard let tags = rule["rule_set"] as? [String] else { return false }
                return tags.contains(where: droppedTags.contains)
            }
            route["rules"] = rules
            TunnelDiag.log("摘掉 \(before - rules.count) 条依赖缺失规则集的规则"
                + "（分流降级为全代理，但内核能起来）")
        }
        root["route"] = route

        // 内核自身的日志也落文件：libbox 的 CommandClient 日志通道在启动失败时
        // 往往还没建立，只有文件里能看到内核报的错。
        var logCfg = (root["log"] as? [String: Any]) ?? [:]
        logCfg["output"] = (home as NSString).appendingPathComponent("kernel.log")
        root["log"] = logCfg

        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8) else {
            TunnelDiag.log("⚠ 配置重新序列化失败，沿用原配置")
            return json
        }
        return text
    }

    private func seedGeoFiles(into home: String) {
        let fm = FileManager.default
        for name in ["geosite-cn.srs", "geoip-cn.srs"] {
            let dest = (home as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: dest),
               let attrs = try? fm.attributesOfItem(atPath: dest),
               let size = attrs[.size] as? Int, size > 0 {
                let srcSize = Bundle.main.path(forResource: name, ofType: nil)
                    .flatMap { (try? fm.attributesOfItem(atPath: $0))?[.size] as? Int }
                if srcSize == nil || srcSize == size {
                    TunnelDiag.log("rule-set \(name) 已在位（\(size)B）")
                    continue
                }
                TunnelDiag.log("rule-set \(name) 版本变化（\(size)B → \(srcSize!)B），覆盖")
            }
            guard let src = Bundle.main.path(forResource: name, ofType: nil) else {
                TunnelDiag.log("✗ rule-set 缺失于扩展 bundle: \(name)（智能分流将降级）")
                continue
            }
            try? fm.removeItem(atPath: dest)
            do {
                try fm.copyItem(atPath: src, toPath: dest)
                let size = ((try? fm.attributesOfItem(atPath: dest))?[.size] as? Int) ?? 0
                TunnelDiag.log("rule-set \(name) 已复制（\(size)B）")
            } catch {
                TunnelDiag.log("✗ rule-set 复制失败 \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 内核日志抽取

    /// 内核的日志缓冲在扩展进程内，App 读不到 → 由扩展抽到 App Group 共享
    /// 文件，App 侧「内核日志」页沿用 Android 的同一套读取逻辑。
    private func startLogPump() {
        stopLogPump()
        if TunnelDiag.appGroupPath == nil {
            TunnelDiag.log("App Group 不可用：内核日志只保留在内存轨迹里")
        }
        let timer = DispatchSource.makeTimerSource(queue: logQueue)
        // 500ms：内核启动期一旦被系统杀掉，抽得越勤，留下的内核日志越完整
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler {
            // sing-box 的日志由 MBoxLogClient（LibboxCommandClient）实时推给
            // TunnelDiag.appendKernel，这里不再轮询。
        }
        timer.resume()
        logPump = timer
    }

    private func stopLogPump() {
        logPump?.cancel()
        logPump = nil
    }

    // MARK: - 错误

    private func tunnelError(_ message: String) -> NSError {
        NSError(domain: "top.mbox.tunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
