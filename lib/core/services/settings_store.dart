import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/serial_executor.dart';
import 'speed_test_mode.dart';

/// 设置持久化（shared_preferences，JSON 序列化）。
///
/// 写路径收敛到本类：所有「读-改-写」必须走 [update]，落盘经全局串行队列，
/// 杜绝多写者并发 load→save 交错导致丢字段/旧快照覆盖（曾出现:设置页整份
/// 旧快照回写把其它模块刚写入的 lastSelectedTag 覆盖掉）。
/// 读 [load] 直读(带默认值合并)；直接 [save] 也入队保证落盘顺序。
class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();
  static const _p = 'moneyfly_settings_v1';

  /// 默认测速探测地址：**必须 HTTPS**。
  static const defaultTestUrl = 'https://www.gstatic.com/generate_204';

  /// 遗留默认测速地址（2.1.x 用的是 http 版）。它是「整份设置持久化」的字段，
  /// 老用户升级后会一直沿用存下来的 http，所以必须显式迁移：
  /// - 明文 HTTP 会被运营商/代理提供商劫持；
  /// - 内核测速对同一地址连发两次请求，明文下极易被判定失败，日志满屏
  ///   `failed to get the second response from http://...`（内核自己都会警告
  ///   「建议改用 HTTPS」），并让在线节点被误判成掉线。
  static const legacyHttpTestUrl = 'http://www.gstatic.com/generate_204';

  /// 全局串行写队列：save/update 依次执行，避免并发交错
  static SerialExecutor _writeQueue = SerialExecutor();

  /// 测试用：丢弃写队列状态。
  ///
  /// 为什么需要：写队列是**进程级单例**，任务只在 `_tail` 上串行链式执行。
  /// widget 测试跑在各自的假异步 zone 里，某个用例结束（zone 被拆掉）时若队列里
  /// 还有一个没跑完的任务，`_tail` 就成了永远不会完成的 future —— 之后所有
  /// `save/update` 都会静默排在它后面、永远不执行。表现是「单个用例跑过、整个
  /// 文件一起跑就失败」（值没落盘）。测试在 setUp 里调用本方法即可隔离。
  @visibleForTesting
  static void resetForTest() {
    _writeQueue = SerialExecutor();
  }

  Map<String, dynamic> _defaults() => {
        // #10：启动自动连接 / 断线自动重连 默认关闭（手动点击连接）
        'autoConnect': false,
        'autoTest': true,
        'autoReconnect': false,
        'reconnectTimes': 3,
        'testIntervalMin': 30,
        'dns': '223.5.5.5',
        // 主 DNS 列表(多源,提升解析成功率);fake-ip 过滤追加域名
        'dnsNameservers': <String>['223.5.5.5', '119.29.29.29'],
        'fakeIpFilterExtra': <String>[],
        'defaultMode': 'smart', // smart / global
        // 本机代理监听端口（mixed 入站 + 系统代理指向的端口），默认 2080
        'localPort': 2080,
        // Clash API 管理端口（切节点/测速/流量统计），默认 9090
        'clashApiPort': 9090,
        // 测速探测地址（内核 delay 测试；网络环境特殊时可改）
        'testUrl': defaultTestUrl,
        // 测速方式：tcp=仅 TCP 端口连通（**默认**）/ kernel=内核测速(真连接)。
        // **老用户本地设置里没有这个 key** —— load() 会把 _defaults() 合并进
        // 读到的快照，缺 key 时自然取到这里的 'tcp'；即使有人手改坏了值，
        // parseSpeedTestMode 也会回落到默认（TCP 测速），绝不因缺 key 异常。
        // 显式选了内核测速的用户不受影响：'kernel' 被显式识别，不会被回落吃掉。
        'speedTestMode': speedTestModeKey(defaultSpeedTestMode),
        // 桌面端默认「仅系统代理」（TUN 需 root，默认开会导致连接失败）；
        // Android/iOS 默认「TUN + 系统代理双通道」（VpnService 授权后 TUN 接管）
        'tunMode': (Platform.isAndroid || Platform.isIOS) ? 'auto' : 'off',
        // TUN 用户态栈（Android 机型兼容性切换：gvisor 兼容性最好 / mixed 更快）
        'tunStack': 'gvisor',
        // 内核日志级别（debug/info/warning/error；连接启动与实时页热更共用）
        'kernelLogLevel': 'warning',
        // DNS 解析模式：auto / fake-ip / redir-host
        'dnsMode': 'auto',
        // hysteria/hysteria2/tuic 放宽证书校验（默认开：这些协议普遍用伪装
        // SNI + 不匹配证书，校验开着必然连不上；实测 17/17 失败 vs 16/17 成功）
        'udpSkipCertVerify': true,
        // 按 App 分流/排除（Android）：all / selected / denied + 包名列表
        'accessControlMode': 'all',
        'accessControlApps': <String>[],
        // 用户自定义「直连名单」（域名后缀列表，命中直接不走代理）
        'bypassDomains': <String>[],
        // 用户追加的「必须走代理」域名（内置默认名单见 mihomo_config）
        'forceProxyDomains': <String>[],
        'bypassLan': true,
        // 外观模式：light / warm / gray / darkgray / darkblue / black
        'appearance': 'light',
        // 订阅自定义 User-Agent（空 = 用默认 MoneyFly/<版本>）
        'subscribeUserAgent': '',
        'language': 'zh',
        'notify': true,
        'crashReport': false,
        'analytics': false,
        'launchAtStartup': false,
        // 桌面端关闭窗口行为：ask 每次询问 / hide 最小化到托盘 / quit 退出
        'closeAction': 'ask',
        // 用户最后手动选择的节点 tag（跨重启恢复固定线路用）
        'lastSelectedTag': '',
        // 内核变体偏好:compatible / standard(桌面 amd64)
        'kernelVariant': 'compatible',
        // 检测到新版本时后台预下载安装包（下载+校验，用户点「立即更新」无需等待）
        'autoDownloadUpdatePkg': true,
        // 用户点过「稍后」的版本号：同一版本不再重复弹更新提示
        'dismissedUpdateVersion': '',
      };

  Future<Map<String, dynamic>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_p);
    if (raw == null) return _defaults();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return _migrateLegacyTestUrl(_migrateLegacyDns(
            {..._defaults(), ...Map<String, dynamic>.from(decoded)}));
      }
    } catch (_) {}
    return _defaults();
  }

  /// 兼容遗留的明文测速地址（见 [legacyHttpTestUrl]）。
  /// 只在「值恰好等于旧默认值」时迁移 —— 用户自己填的任意地址（含自建 http
  /// 探测端点）一律不动，避免把有意的配置悄悄改掉。
  static Map<String, dynamic> _migrateLegacyTestUrl(Map<String, dynamic> s) {
    final u = s['testUrl']?.toString().trim() ?? '';
    if (u == legacyHttpTestUrl) {
      s['testUrl'] = defaultTestUrl;
    }
    return s;
  }

  /// 兼容遗留单值键 `dns`：多 DNS 列表功能上线后，`dns` 只在
  /// `dnsNameservers` 为空时才生效，而默认值恒为非空列表 → 老用户自定义过的
  /// `dns`（如 1.1.1.1）会被静默压掉、设置页也不展示。
  /// 读取时做一次等价映射：列表仍等于默认值时，用 `dns` 替换首项。
  static Map<String, dynamic> _migrateLegacyDns(Map<String, dynamic> s) {
    const defaultDns = '223.5.5.5';
    const defaultList = ['223.5.5.5', '119.29.29.29'];
    final dns = (s['dns']?.toString() ?? '').trim();
    if (dns.isEmpty || dns == defaultDns) return s;
    final list = (s['dnsNameservers'] as List?)
        ?.map((e) => e.toString())
        .toList(growable: false);
    if (list == null || list.length != defaultList.length) return s;
    for (var i = 0; i < list.length; i++) {
      if (list[i] != defaultList[i]) return s; // 用户已自行改过列表 → 不干预
    }
    s['dnsNameservers'] = <String>[dns, ...defaultList.skip(1)];
    return s;
  }

  /// 直接整体保存(整份快照,一般仅「恢复默认」用)；入队保证落盘顺序
  Future<void> save(Map<String, dynamic> settings) {
    return _enqueue(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_p, jsonEncode(settings));
    });
  }

  /// 原子「读-改-写」：所有写方都应走这里(在最新值上改一个/几个键再保存)，
  /// 与其它写方串行,杜绝旧快照覆盖/丢字段
  Future<void> update(void Function(Map<String, dynamic> current) mutate) {
    return _enqueue(() async {
      final s = await load();
      mutate(s);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_p, jsonEncode(s));
    });
  }

  /// 清空用户设置回默认（保留 defaults 语义）
  Future<void> reset() => update((s) => s.clear());

  static Future<void> _enqueue(Future<void> Function() job) => _writeQueue.run(job);
}
