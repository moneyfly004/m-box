package top.moneyfly.app

import android.Manifest
import android.net.Uri
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import top.moneyfly.app.vpn.MoneyFlyVpnService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "top.moneyfly/vpn_permissions"
        private const val DEVICE_CHANNEL = "top.moneyfly/device_id"
        private const val CORE_CHANNEL = "top.moneyfly/vpn_core"
        private const val REQ_VPN = 1001
        private const val REQ_NOTIFY = 1002
        private const val REQ_BATTERY = 1003

        // 待回传的 MethodChannel.Result 放 companion（静态）而不是实例字段：
        // 系统 VPN 授权框 / 通知授权框会把 Activity 切到后台，部分 ROM（MIUI/
        // EMUI/ColorOS 等激进回收 + 开发者选项「不保留活动」）会在此期间销毁并
        // 重建 Activity —— 实例字段会随旧实例丢失，onActivityResult 拿到 null。
        // 静态字段保证同进程内新旧 Activity 实例交替时 Result 引用不丢。
        // 注意：默认 FlutterActivity 的引擎并未被 FlutterEngineCache 缓存，
        // Activity 销毁时引擎（连同 Dart isolate 里挂起的 await）一起销毁——
        // 那种场景下不存在「永久挂起」，回传到死引擎也只是无害空操作。
        // 真正的兜底是 Dart 侧超时 + isVpnPrepared 复查（permission_service.dart）。
        private var pendingVpnResult: MethodChannel.Result? = null
        private var pendingNotifyResult: MethodChannel.Result? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareVpn" -> prepareVpn(result)
                "isVpnPrepared" -> result.success(VpnService.prepare(this) == null)
                "isBatteryOptimizationIgnored" -> result.success(isBatteryOptimizationIgnored())
                "requestIgnoreBatteryOptimization" -> {
                    requestIgnoreBatteryOptimization()
                    result.success(true) // 必须回调，否则 Dart 侧 await 永久挂起、阻塞连接
                }
                "openBatterySettings" -> {
                    openBatterySettings()
                    result.success(true)
                }
                "openVpnSettings" -> {
                    openVpnSettings()
                    result.success(true)
                }
                "getVendor" -> result.success(Build.MANUFACTURER ?: "unknown")
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "hasNotificationPermission" -> result.success(hasNotificationPermission())
                "getVpnServiceStatus" -> result.success(getVpnServiceStatus())
                else -> result.notImplemented()
            }
        }

        // 设备标识通道：硬件指纹读取（跨重装不变，用于设备去重）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAndroidId" -> result.success(androidId())
                    else -> result.notImplemented()
                }
            }

        // 核心控制通道：启动/停止 VPN（sing-box 内核由 VpnService 托管）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CORE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        val configJson = call.argument<String>("configJson")
                        val needTun = call.argument<Boolean>("needTun") ?: true
                        if (configJson.isNullOrEmpty()) {
                            result.error("no_config", "缺少配置", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(this, MoneyFlyVpnService::class.java).apply {
                            action = MoneyFlyVpnService.ACTION_START
                            putExtra(MoneyFlyVpnService.EXTRA_CONFIG, configJson)
                            putExtra(MoneyFlyVpnService.EXTRA_NEED_TUN, needTun)
                        }
                        try {
                            // Android 12+ 后台启动前台服务受限：若连接瞬间 App 被系统页
                            // （如电池豁免框）挤到后台，这里会抛异常 —— 必须回传真实
                            // 原因，否则 Dart 侧只能等到 15s 轮询超时（表现为「连接不生效」）
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error(
                                "start_failed",
                                "无法启动 VPN 服务：${e.message ?: e.javaClass.simpleName}",
                                null,
                            )
                        }
                    }
                    "stopVpn" -> {
                        // 用 stopService 而非 startService(ACTION_STOP)：
                        // 断连可能发生在 App 后台（看门狗判死自动清理/重连失败），
                        // Android 8+ 后台 startService 会被系统禁止抛异常；
                        // stopService 停止「已在运行的服务」不受后台限制，
                        // 会触发 onDestroy → 内核停止 + TUN 释放。
                        try {
                            stopService(Intent(this, MoneyFlyVpnService::class.java))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error(
                                "stop_failed",
                                "无法停止 VPN 服务：${e.message ?: e.javaClass.simpleName}",
                                null,
                            )
                        }
                    }
                    "isVpnRunning" -> result.success(MoneyFlyVpnService.isRunning)
                    "kernelVersion" -> result.success(MoneyFlyVpnService.kernelVersion())
                    // 内核日志读取（见文件底部 KernelLogCursor）：
                    //  - 实时页带 incremental=true：走增量游标，返回 Map{log, hasMore}；
                    //  - 无参数调用（连接失败诊断等一次性拉全文）保持原 String 语义、不动游标。
                    "fetchKernelLogs" -> {
                        if (call.argument<Boolean>("incremental") == true) {
                            result.success(
                                KernelLogCursor.fetchDelta(call.argument<Boolean>("reset") == true)
                            )
                        } else {
                            result.success(MoneyFlyVpnService.fetchKernelLogs())
                        }
                    }
                    "lastStartError" -> result.success(MoneyFlyVpnService.lastStartError)
                    // 失败分类（cross_user / vpn_not_prepared / app_missing / unknown）：
                    // Dart 侧据此给可执行文案、并跳过确定性的自动重连
                    "lastStartErrorKind" -> result.success(MoneyFlyVpnService.lastStartErrorKind)
                    // 启动成功但有降级（如按应用分流被系统拒绝）时的说明
                    "lastStartWarning" -> result.success(MoneyFlyVpnService.lastStartWarning)
                    "getInstalledApps" -> {
                        // PackageManager 查询较重（数百次 IPC），放工作线程避免 UI 卡顿
                        Thread {
                            val list = getInstalledApps()
                            runOnUiThread { result.success(list) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------- VPN ----------
    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        pendingVpnResult = result
        try {
            startActivityForResult(intent, REQ_VPN)
        } catch (e: Exception) {
            // 极少数 ROM 缺系统 VPN 确认页（ActivityNotFound）/ 被设备策略拦截：
            // 立刻回传 false 让 Dart 走「授权失败」引导，而不是干等 45s 超时
            pendingVpnResult = null
            result.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_VPN -> {
                // 以 VpnService.prepare()==null 作为「已授权」的权威判定，而不是
                // 只看 resultCode==RESULT_OK：部分 ROM 即使拒绝也会回 OK、或弹框
                // 被系统吞掉时 resultCode 不可靠。prepare() 返回 null 才是真已授权。
                val granted = VpnService.prepare(this) == null
                pendingVpnResult?.success(granted)
                pendingVpnResult = null
            }
            REQ_BATTERY -> Unit
        }
    }

    // ---------- 电池优化豁免（省电 + 防杀后台） ----------
    private fun isBatteryOptimizationIgnored(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !isBatteryOptimizationIgnored()) {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = android.net.Uri.parse("package:$packageName")
            }
            startActivityForResult(intent, REQ_BATTERY)
        }
    }

    private fun openBatterySettings() {
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_SETTINGS))
        }
    }

    /** 打开系统 VPN 设置页：授权失败引导用 —— 排查其他 VPN 应用
     *  「始终开启的 VPN」占用导致系统授权框弹不出来的情况。 */
    private fun openVpnSettings() {
        try {
            startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_SETTINGS))
            } catch (_: Exception) {}
        }
    }

    // ---------- 通知权限（Android 13+） ----------
    private fun hasNotificationPermission(): Boolean {
        return Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (hasNotificationPermission()) {
            result.success(true)
            return
        }
        pendingNotifyResult = result
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFY) {
            pendingNotifyResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingNotifyResult = null
        }
    }

    /** 已安装应用列表（含桌面启动器的应用）：label + package，按 label 排序。
     *  供「按 App 分流/排除」设置页勾选。 */
    private fun getInstalledApps(): List<Map<String, String>> {
        return try {
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val resolved = packageManager.queryIntentActivities(intent, 0)
            val seen = LinkedHashMap<String, String>()
            val pm = packageManager
            for (ri in resolved) {
                val pkg = ri.activityInfo.packageName ?: continue
                if (seen.containsKey(pkg)) continue
                val label = try {
                    pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
                } catch (_: Exception) {
                    pkg
                }
                seen[pkg] = label
            }
            seen.entries
                .sortedBy { it.value.lowercase() }
                .map { mapOf("package" to it.key, "label" to it.value) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** ANDROID_ID：Android 8+ 按「应用签名 + 用户」作用域（旧版按设备+用户），
     *  **卸载重装不变化**，作为跨安装实例的硬件指纹。取不到时返回空串，
     *  Dart 侧会跳过 X-MF-Device-Fp 头（后端按原逻辑处理）。 */
    private fun androidId(): String {
        return try {
            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    private fun getVpnServiceStatus(): String {
        return if (VpnService.prepare(this) == null) "prepared" else "not_prepared"
    }

}

// ================= 内核日志增量读取（「内核日志」实时页） =================
//
// Mihomelib.logs()（经 MoneyFlyVpnService.fetchKernelLogs()）每次返回的是进程内
// 累积的「全量」快照字符串，且不支持按读取位置消费 —— 实时页若每次把全量回传 Dart
// 并逐行 setState，日志越长越卡。这里在 App 侧维护「上次交付终点」游标（单锁保护）：
//  - 快照为纯追加时，用游标处最后 64 字符做边界连续性校验，只把游标之后新增的
//    完整行交付给 Dart；每次最多交付 MAX_LINES_PER_FETCH 行，仍有剩余则
//    hasMore=true，Dart 立即续读直到追平 —— 不会一次拖回巨型字符串；
//  - 缓冲被清空/回绕（内核重启、stop/start 等）导致边界失配时，以最近
//    BASELINE_MAX_LINES 行为基线重建游标（页面进入也可主动 reset 重建基线）；
//  - 未写完的半行（末尾无 '\n'）暂不交付也不推进游标，等整行落盘后自然补上，
//    完整行不重不漏（仅在缓冲被头部截断的罕见回绕场景可能短暂重复末尾若干行）。
private object KernelLogCursor {

    /** 单次 fetch 最多交付的完整行数；超出部分留在游标后，hasMore=true 提示续读 */
    private const val MAX_LINES_PER_FETCH = 400

    /** 基线（页面进入/缓冲回绕）最多回放的最近行数：既有历史只取尾部，避免整页塞满 */
    private const val BASELINE_MAX_LINES = 200

    /** 连续性校验保留的边界字符数（只留这几十个字符，内存占用 O(1)） */
    private const val MARKER_LEN = 64

    private val lock = Any()

    /** 上次已交付内容在快照中的终点下标；consumedTail 为 null 表示尚无基线 */
    private var consumedEnd = 0

    /** 终点前最后 MARKER_LEN 个字符，用于下次校验快照仍是纯追加 */
    private var consumedTail: String? = null

    /**
     * 取增量日志。
     * @param reset true = 页面重新进入：丢弃旧游标，按最近 BASELINE_MAX_LINES 行重建基线
     * @return Map(log=增量文本, hasMore=本批是否截断、后面还有更多完整行)
     */
    fun fetchDelta(reset: Boolean): Map<String, Any> {
        val full = MoneyFlyVpnService.fetchKernelLogs()
        synchronized(lock) {
            if (reset) {
                consumedEnd = 0
                consumedTail = null
            }
            if (full.isEmpty()) {
                // 内核未启动/日志缓冲被清空：无可读内容，等下一次快照重建基线
                consumedEnd = 0
                consumedTail = null
                return mapOf("log" to "", "hasMore" to false)
            }
            val start = if (isContiguous(full)) consumedEnd else baselineStart(full)
            return deliver(full, start)
        }
    }

    /** 游标处边界与最新快照一致 ⇒ 仍是纯追加，可从 consumedEnd 继续增量读 */
    private fun isContiguous(full: String): Boolean {
        val tail = consumedTail ?: return false
        if (consumedEnd == 0 || consumedEnd > full.length) return false
        if (tail.length > consumedEnd) return false
        return full.regionMatches(consumedEnd - tail.length, tail, 0, tail.length)
    }

    /** 首次调用或缓冲回绕：返回「最近 BASELINE_MAX_LINES 个完整行」所在行首下标 */
    private fun baselineStart(full: String): Int {
        var newlines = 0
        var idx = 0
        while (true) {
            val nl = full.indexOf('\n', idx)
            if (nl < 0) break
            newlines++
            idx = nl + 1
        }
        if (newlines <= BASELINE_MAX_LINES) return 0
        var from = 0
        var toSkip = newlines - BASELINE_MAX_LINES
        while (toSkip > 0) {
            val nl = full.indexOf('\n', from)
            if (nl < 0) break
            from = nl + 1
            toSkip--
        }
        return from
    }

    /** 自 start 起交付至多 MAX_LINES_PER_FETCH 个完整行，并推进游标 */
    private fun deliver(full: String, start: Int): Map<String, Any> {
        var lineEnd = -1
        var searchFrom = start
        var delivered = 0
        while (delivered < MAX_LINES_PER_FETCH) {
            val nl = full.indexOf('\n', searchFrom)
            if (nl < 0) break
            lineEnd = nl
            searchFrom = nl + 1
            delivered++
        }
        if (delivered == 0) {
            // 自 start 起只有未写完的半行：本轮回调不交付也不推进，整行写完自然补上
            return mapOf("log" to "", "hasMore" to false)
        }
        val end = lineEnd + 1
        consumedEnd = end
        consumedTail = if (end <= MARKER_LEN) {
            full.substring(0, end)
        } else {
            full.substring(end - MARKER_LEN, end)
        }
        val hasMore = full.indexOf('\n', end) >= 0
        return mapOf("log" to full.substring(start, end), "hasMore" to hasMore)
    }

}
