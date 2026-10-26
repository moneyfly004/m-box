package top.moneyfly.app.vpn

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.UserManager
import android.util.Log
import org.json.JSONObject
import top.moneyfly.app.MainActivity
import top.moneyfly.app.R
import top.moneyfly.libbox.BridgeOptions
import top.moneyfly.libbox.BridgeSession
import top.moneyfly.libbox.CommandClient
import top.moneyfly.libbox.CommandClientHandler
import top.moneyfly.libbox.CommandClientOptions
import top.moneyfly.libbox.CommandServer
import top.moneyfly.libbox.CommandServerHandler
import top.moneyfly.libbox.ConnectionEvents
import top.moneyfly.libbox.ConnectionOwner
import top.moneyfly.libbox.InterfaceUpdateListener
import top.moneyfly.libbox.Libbox
import top.moneyfly.libbox.LocalDNSTransport
import top.moneyfly.libbox.LogEntry
import top.moneyfly.libbox.LogIterator
import top.moneyfly.libbox.NeighborUpdateListener
import top.moneyfly.libbox.NetworkInterface
import top.moneyfly.libbox.NetworkInterfaceIterator
import top.moneyfly.libbox.Notification as BoxNotification
import top.moneyfly.libbox.OutboundGroupItemIterator
import top.moneyfly.libbox.OutboundGroupIterator
import top.moneyfly.libbox.OverrideOptions
import top.moneyfly.libbox.PlatformInterface
import top.moneyfly.libbox.PlatformUser
import top.moneyfly.libbox.RoutePrefixIterator
import top.moneyfly.libbox.SetupOptions
import top.moneyfly.libbox.ShellSession
import top.moneyfly.libbox.StatusMessage
import top.moneyfly.libbox.StringIterator
import top.moneyfly.libbox.SystemProxyStatus
import top.moneyfly.libbox.TunOptions
import top.moneyfly.libbox.WIFIState
import java.io.File
import java.io.FileOutputStream
import java.util.ArrayDeque
import java.util.concurrent.Executors

/**
 * MoneyFly (m-box) 的 Android VPN 服务：VpnService + libbox（**sing-box**
 * v1.14 官方核心经 gomobile bind，Java 包名 top.moneyfly.libbox）。
 *
 * 架构（与 sing-box-for-android / SFA 一致）：
 *  - Flutter 侧生成 **sing-box JSON 配置**，经 MethodChannel → Intent 传给本服务；
 *  - 本服务实现 [PlatformInterface]：Go 侧要建 TUN / protect socket 时回调过来；
 *    TUN 的 fd 由 `VpnService.establish()` 产出，地址/路由/MTU/DNS 全部来自
 *    配置里的 `inbounds[type=tun]`（libbox 解析后通过 [TunOptions] 传下来）；
 *  - 同时实现 [CommandServerHandler]：Go 侧的服务启停 / 系统代理状态回传；
 *  - 控制面统一走内核自带 Clash API（127.0.0.1:9090），Flutter 侧用它做
 *    模式热切换（Rule/Global）、节点热切换、实时流量统计 —— 与桌面端同一套
 *    Dart 代码；
 *  - 内核日志：用 [CommandClient] 订阅 `CommandLog`，环形缓冲后由
 *    `fetchKernelLogs()` 增量取给「内核日志」页。
 */
@Suppress("UNUSED_PARAMETER")
class MoneyFlyVpnService : VpnService(), PlatformInterface, CommandServerHandler {

    companion object {
        private const val TAG = "MoneyFlyVpnService"

        const val ACTION_START = "top.moneyfly.vpn.START"
        const val ACTION_STOP = "top.moneyfly.vpn.STOP"
        const val EXTRA_CONFIG = "config_json"
        const val EXTRA_NEED_TUN = "need_tun"
        const val CHANNEL_ID = "moneyfly_vpn_channel"
        private const val NOTIFY_ID = 1001

        /** 失败分类常量（与 lib/core/proxy/native_start_failure.dart 对齐） */
        const val KIND_CROSS_USER = "cross_user"
        const val KIND_VPN_NOT_PREPARED = "vpn_not_prepared"
        const val KIND_APP_MISSING = "app_missing"

        @Volatile
        var isRunning: Boolean = false
            private set

        /** 最近一次内核启动失败的原因（Dart 侧超时后读取，用于精确定位） */
        @Volatile
        var lastStartError: String? = null
            private set

        /** 启动失败的**分类**（cross_user / vpn_not_prepared / app_missing / unknown） */
        @Volatile
        var lastStartErrorKind: String? = null
            private set

        /** 本次启动有降级时的说明（如按应用分流被系统拒绝后退化为全部走代理） */
        @Volatile
        var lastStartWarning: String? = null
            private set

        /** 内核日志环形缓冲（CommandClient 采集；最多 2000 行） */
        private val logBuffer = ArrayDeque<String>()
        private var logReadPos = 0
        private const val LOG_MAX = 2000

        private fun appendLog(line: String) {
            synchronized(logBuffer) {
                if (logBuffer.size >= LOG_MAX) {
                    logBuffer.removeFirst()
                    if (logReadPos > 0) logReadPos--
                }
                logBuffer.addLast(line)
            }
        }

        /** 内置内核版本（任何时候可读，用于设置页「内核管理」） */
        fun kernelVersion(): String =
            try {
                Libbox.version() ?: ""
            } catch (e: Exception) {
                Log.w(TAG, "kernelVersion: ${e.message}")
                ""
            }

        /** 自上次调用以来的内核日志增量（「内核日志」实时页轮询） */
        fun fetchKernelLogs(): String {
            return try {
                synchronized(logBuffer) {
                    if (logReadPos >= logBuffer.size) return ""
                    val sb = StringBuilder()
                    var i = 0
                    for (line in logBuffer) {
                        if (i >= logReadPos) sb.append(line).append('\n')
                        i++
                    }
                    logReadPos = logBuffer.size
                    sb.toString()
                }
            } catch (e: Exception) {
                Log.w(TAG, "fetchKernelLogs: ${e.message}")
                ""
            }
        }
    }

    private var commandServer: CommandServer? = null
    private var commandClient: CommandClient? = null
    private var tunPfd: ParcelFileDescriptor? = null

    /** 最近一次成功加载的 sing-box 配置（serviceReload 时重载用） */
    @Volatile
    private var currentConfig: String? = null

    /** 内核启动/停止串行化（Go 侧 CommandServer 的调用需避免并发） */
    private val coreExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val configJson = intent?.getStringExtra(EXTRA_CONFIG)
        when (intent?.action) {
            ACTION_STOP -> {
                coreExecutor.execute {
                    stopBox()
                    stopForegroundCompat()
                    stopSelf()
                }
                return START_NOT_STICKY
            }

            // 无配置的启动来源：BootReceiver（开机自启）/ 系统因 START_STICKY
            // 重启 service。此时没有内核配置，绝不能常驻空转 —— 否则出现
            // 「前台通知挂着但内核没跑」（幽灵连接）。
            ACTION_START -> {
                if (configJson.isNullOrEmpty()) {
                    startForeground(NOTIFY_ID, buildNotification())
                    coreExecutor.execute {
                        try {
                            Thread.sleep(1500)
                        } catch (_: InterruptedException) {
                        }
                        if (!isRunning) {
                            stopForegroundCompat()
                            stopSelf()
                        }
                    }
                    return START_NOT_STICKY
                }
            }
        }
        // START_STICKY 重启（intent == null）：无配置可恢复，直接结束
        if (intent == null) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFY_ID, buildNotification())
        if (configJson.isNullOrEmpty()) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        coreExecutor.execute {
            try {
                startBox(configJson)
            } catch (e: Exception) {
                Log.e(TAG, "startBox failed", e)
                isRunning = false
                stopForegroundCompat()
                stopSelf()
            }
        }
        return START_STICKY
    }

    @Synchronized
    private fun startBox(configJson: String) {
        // 新一轮启动：先清掉上一轮的失败/降级记录。Dart 侧会在就绪窗口内轮询
        // lastStartError 做「早失败」，残留的旧值会被误判成本次失败。
        lastStartError = null
        lastStartErrorKind = null
        lastStartWarning = null

        // 竞态处理：Dart 断开后立刻重连时旧内核可能还在停（CommandServer 非空）。
        // 语义：收到新的启动请求 → 先关旧内核再按新配置启动（重启）。
        if (commandServer != null) {
            Log.d(TAG, "收到新启动请求，先关闭旧内核再重启")
            runCatching { commandServer?.closeService() }
            runCatching { commandClient?.disconnect() }
            runCatching { commandServer?.close() }
            commandServer = null
            commandClient = null
            isRunning = false
        }

        try {
            val workDir = File(filesDir, "work").also { it.mkdirs() }
            // 离线分流规则集（.srs）从 APK assets 兜底复制：正常情况下 Dart 侧
            // 已落盘（幂等），这里只覆盖「Dart 未跑到」的异常路径。
            syncRuleAssets(workDir)

            // libbox 全局初始化（只做一次）
            val opts = SetupOptions().apply {
                basePath = filesDir.absolutePath
                workingPath = workDir.absolutePath
                tempPath = cacheDir.absolutePath
                fixAndroidStack = true
                // 日志环形缓冲：内核日志页靠它 + CommandClient 增量拉取
                logMaxLines = 2000L
            }
            Libbox.setup(opts)

            // 按应用分流：把 Flutter 侧设置翻译成 libbox 的 include/exclude 包名表
            val override = OverrideOptions()
            val (mode, apps) = readAccessSettings()
            val others = apps.filter { it != packageName }
            when (mode) {
                "selected" -> if (others.isNotEmpty()) {
                    override.includePackage = stringIteratorOf(others)
                }

                "denied" -> if (others.isNotEmpty()) {
                    override.excludePackage = stringIteratorOf(others)
                }
            }

            val server = CommandServer(this, this)
            server.start()
            commandServer = server
            startLogClient()

            // 阻塞直到配置解析完成/失败
            server.startOrReloadService(configJson, override)
            currentConfig = configJson
            isRunning = true
            appendLog("[app] sing-box 内核已启动（${Libbox.version()}）")
            Log.i(TAG, "sing-box started (version=${Libbox.version()})")
        } catch (e: Exception) {
            lastStartErrorKind = classifyStartFailure(e)
            lastStartError = buildStartErrorDetail(e, lastStartErrorKind ?: "unknown")
            Log.e(TAG, "startBox failed: $lastStartError")
            runCatching { commandClient?.disconnect() }
            commandServer = null
            commandClient = null
            isRunning = false
            throw e
        }
    }

    private fun stringIteratorOf(values: List<String>): StringIterator =
        object : StringIterator {
            private var i = 0
            override fun hasNext(): Boolean = i < values.size
            override fun next(): String = values[i++]
            override fun len(): Int = values.size
        }

    /** 订阅内核日志：CommandClient + CommandLog（SFA 同款做法） */
    private fun startLogClient() {
        try {
            val handler = object : CommandClientHandler {
                override fun clearLogs() {
                    synchronized(logBuffer) {
                        logBuffer.clear()
                        logReadPos = 0
                    }
                }

                override fun connected() {}

                override fun disconnected(message: String?) {
                    if (!message.isNullOrEmpty()) appendLog("[app] 日志通道断开: $message")
                }

                override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) {}

                override fun setDefaultLogLevel(level: Int) {}

                override fun updateClashMode(newMode: String?) {}

                override fun writeConnectionEvents(events: ConnectionEvents?) {}

                override fun writeGroups(groups: OutboundGroupIterator?) {}

                override fun writeLogs(iterator: LogIterator?) {
                    if (iterator == null) return
                    while (iterator.hasNext()) {
                        val entry: LogEntry = iterator.next() ?: continue
                        appendLog(entry.message.orEmpty())
                    }
                }

                override fun writeOutbounds(iterator: OutboundGroupItemIterator?) {}

                override fun writeStatus(status: StatusMessage?) {}
            }
            val options = CommandClientOptions().apply {
                statusInterval = 0L // 不做状态轮询：流量统计走 Clash API
                addCommand(Libbox.CommandLog)
            }
            val client = CommandClient(handler, options)
            client.connect()
            commandClient = client
        } catch (e: Exception) {
            // 日志通道失败不影响内核运行：日志页会显示为空
            Log.w(TAG, "startLogClient failed: ${e.message}")
        }
    }

    /** 失败分类：与 Dart 侧 native_start_failure.dart 的常量一一对应。 */
    private fun classifyStartFailure(e: Throwable): String {
        val m = (e.message ?: "").lowercase()
        return when {
            m.contains("interact_across_users") -> KIND_CROSS_USER
            m.contains("missing vpn permission") ||
                m.contains("not prepared or is revoked") -> KIND_VPN_NOT_PREPARED

            m.contains("namenotfound") -> KIND_APP_MISSING
            else -> "unknown"
        }
    }

    /** 失败详情：原文 + 跨用户拦截时的设备环境信息 */
    private fun buildStartErrorDetail(e: Throwable, kind: String): String {
        val base = e.message ?: e.javaClass.simpleName
        if (kind != KIND_CROSS_USER) return base
        return "$base | uid=${Process.myUid()} profiles=${profileCount()}"
    }

    /** 当前用户的 profile 数量（>1 说明有工作资料/分身空间）。读取失败返回 -1。 */
    private fun profileCount(): Int = try {
        getSystemService(UserManager::class.java)?.userProfiles?.size ?: 1
    } catch (_: Exception) {
        -1
    }

    @Synchronized
    private fun stopBox() {
        isRunning = false
        currentConfig = null
        runCatching { commandServer?.closeService() }
        runCatching { commandClient?.disconnect() }
        runCatching { commandServer?.close() }
        commandClient = null
        commandServer = null
        // 内核已关闭其持有的 TUN fd；这里只关我们自己的 PFD 副本
        runCatching { tunPfd?.close() }
        tunPfd = null
    }

    // ================= PlatformInterface =================

    override fun autoDetectInterfaceControl(fd: Int) {
        try {
            protect(fd)
        } catch (e: Exception) {
            Log.e(TAG, "protect failed", e)
        }
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun useProcFS(): Boolean = false

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun usePlatformBridge(): Boolean = false

    override fun usePlatformShell(): Boolean = false

    /**
     * 建立 TUN：地址/路由/MTU/DNS 全部来自配置里 tun inbound（libbox 解析后
     * 通过 [TunOptions] 传下来）。
     *
     * 无论哪种分流模式，**本应用自身必须排除** —— 进程内内核（gomobile 库、
     * 同 uid）拨号到代理服务器的流量若被自己的 TUN 再抓回来，会形成自代理
     * 死循环（表现：连上了但零流量）。
     */
    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")
        var firstError: Exception? = null
        try {
            val pfd = buildTunBuilder(options, withAccessControl = true).establish()
            if (pfd != null) {
                tunPfd = pfd
                return pfd.fd
            }
            firstError = IllegalStateException(
                "android: the application is not prepared or is revoked"
            )
        } catch (e: Exception) {
            firstError = e
            Log.w(TAG, "establish with per-app access control failed: ${e.message}")
        }
        // 降级重试：放弃按应用分流，仅保留「排除自身」的自环保护
        try {
            val pfd = buildTunBuilder(options, withAccessControl = false).establish()
                ?: throw IllegalStateException(
                    "android: the application is not prepared or is revoked"
                )
            lastStartWarning =
                "per-app access control rejected by system, degraded to disallow-self-only " +
                    "(first error: ${firstError?.message})"
            Log.w(TAG, "TUN established WITHOUT per-app access control (degraded)")
            tunPfd = pfd
            return pfd.fd
        } catch (e: Exception) {
            Log.w(TAG, "TUN establish fallback also failed: ${e.message}")
            // 两次都失败：上抛**首次**原因（它才是真因）
            throw (firstError ?: e)
        }
    }

    @SuppressLint("MissingPermission")
    private fun buildTunBuilder(options: TunOptions, withAccessControl: Boolean): Builder {
        val builder = Builder()
            .setSession("MoneyFly")
            .setConfigureIntent(
                PendingIntent.getActivity(
                    this, 0, Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .setMtu(options.mtu)

        forEachPrefix(options.inet4Address) { address, prefix ->
            builder.addAddress(address, prefix)
        }
        forEachPrefix(options.inet6Address) { address, prefix ->
            builder.addAddress(address, prefix)
        }

        if (options.autoRoute) {
            forEachPrefix(options.inet4RouteAddress) { address, prefix ->
                builder.addRoute(address, prefix)
            }
            forEachPrefix(options.inet6RouteAddress) { address, prefix ->
                builder.addRoute(address, prefix)
            }
        } else {
            // Flutter 端配置 tun.auto_route=false（路由交回平台侧）：全量路由
            builder.addRoute("0.0.0.0", 0)
            // IPv6 全量路由：避免 v4 全接管而 v6 走系统直连造成的地址族泄漏
            builder.addRoute("::", 0)
        }

        runCatching {
            val dns = options.dnsServerAddress
            if (dns != null) {
                while (dns.hasNext()) {
                    builder.addDnsServer(dns.next())
                }
            }
        }.onFailure { Log.d(TAG, "dns server iterate: ${it.message}") }

        if (withAccessControl) {
            applyAccessControl(builder)
        } else {
            builder.addDisallowedApplication(packageName)
        }
        return builder
    }

    /**
     * 写入按应用分流设置。**逐项容错**：单个应用不存在/被系统拒绝时只跳过该项
     * 并计数，不再「一个失败就整份列表作废且静默」。
     *
     * 两类情况必须中断本次尝试（交给 openTun 降级重试）：
     *   1) 排除自身失败 → 自代理死循环风险；
     *   2) selected 模式下一个应用都没加进去 → 隧道形同虚设。
     */
    private fun applyAccessControl(builder: Builder) {
        val (mode, apps) = readAccessSettings()
        val others = apps.filter { it != packageName }
        when (mode) {
            "selected" -> {
                var ok = 0
                for (p in others) {
                    try {
                        builder.addAllowedApplication(p)
                        ok++
                    } catch (e: Exception) {
                        Log.w(TAG, "addAllowedApplication($p) skipped: ${e.message}")
                    }
                }
                if (ok == 0) {
                    throw IllegalStateException(
                        "android: none of the selected apps could be added to the tunnel " +
                            "(requested=${others.size})"
                    )
                }
                if (ok < others.size) {
                    Log.w(TAG, "access control partial: $ok/${others.size} selected apps applied")
                }
            }

            "denied" -> {
                for (p in others) {
                    try {
                        builder.addDisallowedApplication(p)
                    } catch (e: Exception) {
                        Log.w(TAG, "addDisallowedApplication($p) skipped: ${e.message}")
                    }
                }
                builder.addDisallowedApplication(packageName)
            }

            else -> builder.addDisallowedApplication(packageName)
        }
    }

    private inline fun forEachPrefix(iter: RoutePrefixIterator?, block: (String, Int) -> Unit) {
        if (iter == null) return
        while (iter.hasNext()) {
            val prefix = iter.next() ?: continue
            block(prefix.address(), prefix.prefix())
        }
    }

    override fun clearDNSCache() {}

    override fun readWIFIState(): WIFIState? = null

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun getInterfaces(): NetworkInterfaceIterator = EmptyNetworkInterfaceIterator()

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {}

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {}

    override fun startNeighborMonitor(listener: NeighborUpdateListener) {}

    override fun closeNeighborMonitor(listener: NeighborUpdateListener) {}

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner = error("android: findConnectionOwner not supported")

    override fun sendNotification(notification: BoxNotification) {}

    override fun cancelNotification(identifier: String, typeID: Int) {}

    override fun checkPlatformShell() {}

    override fun openShellSession(
        user: PlatformUser?,
        command: String?,
        environ: StringIterator?,
        term: String?,
        rows: Int,
        columns: Int,
    ): ShellSession? = null

    override fun createBridge(options: BridgeOptions): BridgeSession =
        error("android: bridge not supported")

    override fun lookupUser(username: String): PlatformUser =
        error("android: lookupUser not supported")

    override fun lookupSFTPServer(): String = error("android: sftp not supported")

    override fun readSystemSSHHostKey(): String = error("android: ssh host key not supported")

    override fun tailscaleHostname(): String = error("android: tailscale not supported")

    override fun registerMyInterface(name: String) {}

    // ================= CommandServerHandler =================

    override fun serviceReload() {
        val config = currentConfig ?: return
        coreExecutor.execute {
            try {
                commandServer?.startOrReloadService(config, OverrideOptions())
                appendLog("[app] 配置已热重载")
            } catch (e: Exception) {
                Log.e(TAG, "serviceReload failed", e)
                appendLog("[app] 配置热重载失败: ${e.message}")
            }
        }
    }

    override fun serviceStop() {
        coreExecutor.execute { stopBox() }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus =
        SystemProxyStatus().also {
            it.available = false
            it.enabled = false
        }

    override fun setSystemProxyEnabled(isEnabled: Boolean) {}

    override fun writeDebugMessage(message: String) {
        if (message.isNotEmpty()) appendLog("[app] $message")
        Log.d(TAG, message)
    }

    override fun connectSSHAgent(): Int = 0

    override fun triggerNativeCrash() {}

    // ================= 设置读取 / 资源 =================

    /** 从 Flutter 设置读取访问控制（SharedPreferences 的 moneyfly_settings_v1 JSON） */
    private fun readAccessSettings(): Pair<String, List<String>> {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val raw = prefs.getString("flutter.moneyfly_settings_v1", null)
            if (raw == null) return "all" to emptyList()
            val json = JSONObject(raw)
            val mode = json.optString("accessControlMode", "all")
            val arr = json.optJSONArray("accessControlApps")
            val apps = mutableListOf<String>()
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    arr.optString(i).takeIf { it.isNotBlank() }?.let { apps.add(it) }
                }
            }
            mode to apps
        } catch (_: Exception) {
            "all" to emptyList()
        }
    }

    /** 从 Flutter assets 复制分流规则集（APK 内 flutter_assets/assets/rules 下的 .srs） */
    private fun syncRuleAssets(dir: File) {
        for (name in listOf("geosite-cn.srs", "geoip-cn.srs")) {
            val target = File(dir, name)
            if (target.exists() && target.length() > 0) continue
            try {
                assets.open("flutter_assets/assets/rules/$name").use { input ->
                    FileOutputStream(target).use { output -> input.copyTo(output) }
                }
                Log.d(TAG, "rule-set synced: $name -> ${target.absolutePath}")
            } catch (e: Exception) {
                // 缺规则集内核仍能启动（Dart 侧会降级为全代理），仅告警
                Log.w(TAG, "rule-set $name 复制失败（智能分流会降级）: ${e.message}")
            }
        }
    }

    // ================= 前台通知 =================

    private fun buildNotification(): Notification {
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("MoneyFly")
            .setContentText("代理运行中")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID, "VPN", NotificationManager.IMPORTANCE_LOW
            )
            channel.setShowBadge(false)
            nm.createNotificationChannel(channel)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        coreExecutor.execute { stopBox() }
        coreExecutor.shutdown()
    }
}

private class EmptyNetworkInterfaceIterator : NetworkInterfaceIterator {
    override fun hasNext(): Boolean = false
    override fun next(): NetworkInterface = error("empty")
}
