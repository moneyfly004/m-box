import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../services/app_log.dart';
import '../services/permission_service.dart';
import 'singbox_config.dart';
import 'kernel_delay_api.dart';
import 'native_start_failure.dart';
import 'proxy_core.dart';

/// 看门狗单次巡检后的决策（纯逻辑，便于单元测试）
enum WatchdogAction {
  /// 隧道正常，继续
  healthy,
  /// 本次失败但未达阈值 / 原生确认存活 → 保持连接，绝不断连
  keepAlive,
  /// 连续失败达阈值且原生确认已停 → 判定内核死亡
  declareDead,
}

/// 看门狗判死纯函数（无副作用，可单测）：
/// - 本次巡检 OK → healthy
/// - 失败但连续次数未达阈值 → keepAlive（等下次）
/// - 达阈值但原生 VpnService 仍在跑 → keepAlive（App 后台/限流导致的假失败）
/// - 达阈值且原生已停 → declareDead
///
/// [consecutiveFailures] 含本次在内的连续失败次数（本次失败时由调用方 +1 后传入）。
WatchdogAction decideWatchdog({
  required bool pollOk,
  required int consecutiveFailures,
  required int deadThreshold,
  required bool nativeAlive,
}) {
  if (pollOk) return WatchdogAction.healthy;
  if (consecutiveFailures < deadThreshold) return WatchdogAction.keepAlive;
  if (nativeAlive) return WatchdogAction.keepAlive;
  return WatchdogAction.declareDead;
}

/// 嵌入式内核（Android + iOS 共用）：内核以 gomobile 静态库跑在「系统提供的
/// 隧道」里，由原生侧拿到 tun fd 后调 libbox 启动内核（配置为 sing-box JSON）。
///
/// - Android：VpnService（原生 Kotlin）建立 TUN，内核在 **App 进程内**；
/// - iOS：NetworkExtension PacketTunnel 扩展建立 TUN，内核在 **扩展进程内**
///   （iOS 沙箱不允许 App 自建 utun，必须由扩展持有 packet-tunnel-provider
///   entitlement）。App 与扩展的通信走 App Group 共享配置 + 系统 VPN 管理器。
///
/// 两端原生侧的 MethodChannel 契约**同名同参**
/// （startVpn / stopVpn / isVpnRunning / kernelVersion / fetchKernelLogs /
/// lastStartError），因此 Dart 侧可以共用本实现；
/// 切模式/切节点/测速/流量统计统一走内核的 Clash API(127.0.0.1:9090)，
/// 与桌面端完全一致。
class ProxyCoreEmbedded extends ProxyCore {
  static const _channel = MethodChannel('top.moneyfly/vpn_core');

  final Dio _api = Dio(BaseOptions(
    baseUrl: 'http://127.0.0.1:9090',
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
  ));

  /// 当前智能(rule)/全局(global)状态 —— 决定热切节点时打 select 组还是 GLOBAL 组
  // ignore: unused_field
  bool _smartMode = true;

  /// 最近一次切换的节点 tag（切全局模式时把 GLOBAL 组指过来）
  // ignore: unused_field
  String? _lastNodeTag;

  bool _running = false;
  String? _lastError;
  VoidCallback? _onUnexpectedExit;
  void Function(double upMbps, double downMbps)? _onTraffic;
  Timer? _watchdog;
  CancelToken? _trafficCancel;
  final List<int> _trafficBuf = [];

  /// 看门狗连续失败计数。单次 /version 失败不判定内核死亡 —— App 切后台、
  /// 弹系统框、Doze 限流都可能让某一次轮询瞬时失败，但隧道其实还活着。
  /// 连续多次失败、且原生 VpnService 也确认已停，才判定真死亡。
  int _watchdogFailures = 0;
  static const _watchdogDeadThreshold = 3; // 连续 3 次(约15s)才判死

  @override
  bool get isRunning => _running;
  @override
  String? get lastError => _lastError;
  @override
  VoidCallback? get onUnexpectedExit => _onUnexpectedExit;
  @override
  set onUnexpectedExit(VoidCallback? cb) => _onUnexpectedExit = cb;
  @override
  void Function(double upMbps, double downMbps)? get onTraffic => _onTraffic;
  @override
  set onTraffic(void Function(double upMbps, double downMbps)? cb) => _onTraffic = cb;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    if (_running) throw StateError('already running');
    _lastError = null;
    // 从配置同步模式（Rule=智能 / Global=全局）：sing-box 的模式在
    // experimental.clash_api.default_mode 里
    final exp = config['experimental'];
    final apiCfg = exp is Map ? exp['clash_api'] : null;
    final startMode = apiCfg is Map ? apiCfg['default_mode']?.toString() : null;
    _smartMode = startMode != 'Global';
    // 剥离 app 侧元数据（系统代理端口/模式/TUN 开关），不写入配置文件
    final tunMode = config.remove('_tunMode')?.toString() ?? 'auto';
    final clashPort =
        (config.remove('_clashApiPort') as num?)?.toInt() ?? 9090;
    final localPort = (config.remove('_localPort') as num?)?.toInt() ?? 2080;
    final clashSecret = config.remove('_clashApiSecret')?.toString() ?? '';
    _api.options.baseUrl = 'http://127.0.0.1:$clashPort';
    if (clashSecret.isNotEmpty) {
      _api.options.headers['Authorization'] = 'Bearer $clashSecret';
    }
    // 序列化为 sing-box JSON（原生 libbox 只吃 JSON 配置）
    final configJson = SingBoxConfigBuilder.encode(config);
    final needTun = tunMode != 'off';
    // 前置检查：VPN 授权缺失/被撤销（重装、清数据、系统里关闭授权）时，
    // 直接在 Dart 侧给出类型化失败，避免走 15s 轮询超时才知道失败
    if (!await PermissionService.instance.isVpnPrepared()) {
      throw TypedConnError(
          ConnErrorKind.noVpnPermission, AppStrings.t('vpn_permission_needed'));
    }
    try {
      await _channel.invokeMethod('startVpn', {
        'configJson': configJson,
        'needTun': needTun,
        // ⚠️ iOS 侧（VpnCorePlugin/PacketTunnelProvider）必须拿到这三项：
        //   · clashSecret：扩展在**网络切换**时要 PATCH /configs 把新接口绑上去，
        //     没有正确的 secret 会被内核回 401 → 切换后流量全断（客户实测
        //     「热切换失败 / 经常自动断开」，扩展日志里那行
        //     `API 自检(扩展内) HTTP 401` 就是它）；
        //   · apiPort / localPort：端口被用户改过时，扩展要跟 App 用同一套端口。
        // 旧实现只传了配置/needTun → 扩展拿到空 secret → 401 循环。
        'apiPort': clashPort,
        'localPort': localPort,
        'clashSecret': clashSecret,
      });
    } on PlatformException catch (e) {
      // start_failed（原生侧返回，如 Android 12+ 后台启动前台服务受限）：
      // 类型化后交给首页分场景引导（保持前台重试等）
      final msg = e.message?.toString() ?? '$e';
      if (e.code == 'start_failed') {
        throw TypedConnError(ConnErrorKind.backgroundStartBlocked, msg);
      }
      throw TypedConnError(ConnErrorKind.unknown,
          AppStrings.t('vpn_start_fail', {'err': msg}));
    } catch (e) {
      throw TypedConnError(
          ConnErrorKind.unknown, AppStrings.t('vpn_start_fail', {'err': '$e'}));
    }
    final sw = Stopwatch()..start();
    // 原生侧「上一轮」的失败记录：本轮就绪窗口内只认**新增/变化**的失败，
    // 否则会把上一次连接的残留错误当成这次失败（原生侧也会在新一轮 startBox
    // 入口清空，这里是双保险 —— startVpn 是 startService，返回时可能尚未开始）。
    final staleError = await _safeChannelString('lastStartError');
    // 就绪窗口 20s：Clash API 监听在内核完全起来后才可用，Doze/后台限流/
    // 低端机慢启动都可能让首个 /version 迟到。窗口略放宽 + 超时后问原生
    // 存活（见下），双保险避免误杀正在正常转发的活内核。
    //
    // 原生侧**已明确记录启动失败**时不再干等满 20s（早失败）：安卓上
    // `VpnService.Builder.establish()` 被系统拒绝（如多用户/分身空间的
    // INTERACT_ACROSS_USERS）是确定性的，等满窗口只是让用户白等 20 秒，
    // 还会被自动重连重复三遍（线上日志实测）。
    //
    // iOS 额外做「早失败」探测：扩展启动失败时系统会很快把连接置为
    // disconnected/invalid，这时没必要干等满 20s —— 提前失败并带上扩展轨迹，
    // 否则用户只会看到一个没有原因的「内核启动超时」。
    var downStreak = 0;
    var nativeFailDetail = '';
    var ticks = 0;
    while (sw.elapsed < const Duration(seconds: 20)) {
      try {
        final r = await _api.get('/version', options: Options(validateStatus: (s) => true));
        if (r.statusCode == 200) {
          _running = true;
          _startWatchdog();
          _startTrafficStream();
          await _logStartWarning();
          return;
        }
      } catch (_) {}
      // 每 ~600ms 问一次原生侧是否已记录启动失败
      if (++ticks % 2 == 0) {
        final err = await _safeChannelString('lastStartError');
        if (err != null && err.isNotEmpty && err != staleError) {
          nativeFailDetail = err;
          break; // 早失败：原生侧已经知道原因，别让用户干等
        }
      }
      if (Platform.isIOS && sw.elapsed > const Duration(seconds: 5)) {
        final st = await _iosVpnStatus();
        if (st != null &&
            (st.startsWith('no-manager') ||
                st.startsWith('invalid') ||
                st.startsWith('disconnected'))) {
          downStreak++;
          if (downStreak >= 5) break; // 隧道明确没起来 → 走失败分支（含诊断）
        } else {
          downStreak = 0;
        }
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // 就绪窗口内 Clash API /version 未返回 200 —— 但这**不等于**内核启动失败。
    // 实测常见误报：内核已解析完配置、listener 在跑、隧道已在转发流量，只是
    // App 侧因 Doze/后台限流没能在 20s 内拿到 /version 的 200（日志尾部往往
    // 已是正常的分流/转发记录）。此时若直接 stopVpn，就把一个活内核误杀了，
    // 表现为「刚连上就自己断了」。
    //
    // 因此先向原生确认内核/VpnService 是否存活：
    //  - 存活 → 判定连接成立（视为已连接），启动看门狗接管后续健康探测。
    //    看门狗有「连续 3 次失败且原生确认已停才判死」的健壮逻辑，API 通道
    //    稍后恢复即自愈；真僵死也会被看门狗兜底判死并触发重连，不会卡死。
    //  - 已停 → 才是真失败，收集真实原因并清理残留。
    var nativeAlive = false;
    try {
      nativeAlive = await _channel.invokeMethod<bool>('isVpnRunning') ?? false;
    } catch (_) {}
    if (nativeAlive) {
      AppLog.kernel(
          'ready poll timed out (20s) but native kernel alive → treat as connected, watchdog takes over');
      _running = true;
      _startWatchdog();
      _startTrafficStream();
      // API 通道稍慢时先补测一次真实出口/流量由上层触发；这里直接判成功返回。
      return;
    }
    // 原生也确认内核未运行：这才是真正的启动失败。主动清理原生侧
    // （VpnService/内核可能启动失败留下残留），避免「UI 报失败但 VPN 通知/
    // 隧道残留」的幽灵连接。顺带拉取内核日志尾部，把真实原因带给用户。
    var detail = nativeFailDetail;
    // 1) 原生侧记录的真实启动错误（最直接、最精确）
    try {
      final err = await _channel.invokeMethod<String>('lastStartError');
      if (err != null && err.isNotEmpty) detail = err;
    } catch (_) {}
    // 2) 补充内核日志尾部
    try {
      final logs =
          await _channel.invokeMethod<String>('fetchKernelLogs') ?? '';
      if (logs.isNotEmpty) {
        final lines = logs.split('\n').where((l) => l.trim().isNotEmpty).toList();
        // 优先取「错误/启动阶段」行（bind/listen/error/config/panic），
        // 避免被启动后的流量日志刷掉真因；没有错误行才取末尾几行
        final errLines = lines
            .where((l) =>
                l.contains('level=error') ||
                l.contains('bind') ||
                l.contains('listen') ||
                l.contains('panic') ||
                l.contains('config') ||
                l.contains('Shutting'))
            .toList();
        final picked = errLines.isNotEmpty
            ? errLines.take(4).join(' | ')
            : (lines.length > 4
                ? lines.sublist(lines.length - 4).join(' | ')
                : lines.join(' | '));
        detail = detail.isEmpty ? picked : '$detail | $picked';
      }
    } catch (_) {}
    // 3) iOS：把扩展侧诊断接进来（这是「内核启动超时」唯一的定位线索）
    if (Platform.isIOS) {
      final diag = await _iosTunnelDiagnostics();
      if (diag.isNotEmpty) {
        AppLog.kernel('iOS 隧道诊断:\n$diag');
        final brief = _lastLines(diag, 6);
        detail = detail.isEmpty ? brief : '$detail | $brief';
      }
      // 4) iOS：内核（Go）的 stdout/stderr —— 崩溃转储 / fatal error / panic
      // 全在这里。扩展被系统静默杀掉时，这是唯一能带回现场的通道。
      try {
        final stderr =
            await _channel.invokeMethod<String>('fetchKernelStderr') ?? '';
        if (stderr.trim().isNotEmpty) {
          AppLog.kernel('内核 stderr（含崩溃转储）:\n${_lastLines(stderr, 60)}');
          final brief = _lastLines(stderr, 8);
          detail = detail.isEmpty ? brief : '$detail | $brief';
        }
      } catch (_) {}
    }
    _lastError = AppStrings.t('kernel_timeout');
    try {
      await _channel.invokeMethod('stopVpn');
    } catch (_) {}
    // 原生侧的分类（cross_user / vpn_not_prepared / app_missing / unknown）：
    // 决定给用户什么文案、以及上层该不该自动重连（跨用户拦截是确定性的，
    // 重试只会让用户多等 3 轮 —— 见 native_start_failure.dart）。
    final kindStr = await _safeChannelString('lastStartErrorKind');
    final failure = classifyNativeStartFailure(kind: kindStr, detail: detail);
    if (failure == NativeStartFailure.crossUserBlocked) {
      AppLog.error('[VPN] Android 多用户/分身空间拦截建立隧道：$detail');
    } else if (failure != NativeStartFailure.none) {
      AppLog.error('[VPN] 启动失败（${failure.name}）：$detail');
    }
    throw TypedConnError(
      connErrorKindForNativeStartFailure(failure) ?? ConnErrorKind.kernelTimeout,
      nativeStartFailureMessage(failure, detail),
    );
  }

  /// 读原生侧字符串通道（通道缺失/平台不支持时返回 null，不抛）。
  Future<String?> _safeChannelString(String method) async {
    try {
      final v = await _channel.invokeMethod<String>(method);
      return v;
    } catch (_) {
      return null;
    }
  }

  /// 启动成功但原生侧记录了降级（如按应用分流被系统拒绝）→ 落日志中心。
  /// 不静默：用户开了「仅这些应用走代理」却发现其他应用也在走代理时，
  /// 至少日志里能查到原因（UI 提示见 vpn_access_control_degraded）。
  Future<void> _logStartWarning() async {
    final w = await _safeChannelString('lastStartWarning');
    if (w == null || w.trim().isEmpty) return;
    AppLog.kernel('[VPN] 启动降级（${AppStrings.t('vpn_access_control_degraded')}）：$w');
  }

  /// iOS：向原生查询隧道状态（Android 无此通道方法 → 返回 null）。
  /// 形如 `connected/enabled=true`、`disconnected/enabled=true`、`no-manager`。
  Future<String?> _iosVpnStatus() async {
    try {
      return await _channel.invokeMethod<String>('vpnStatus');
    } catch (_) {
      return null;
    }
  }

  /// iOS：收集扩展侧诊断（内存轨迹优先，回退落盘轨迹）。
  /// 「内核启动超时」本身没有任何定位价值，真正的信息都在扩展进程里：
  /// 扩展有没有被系统拉起、配置有没有拿到、fd 取没取到、内核 Start 返回什么。
  Future<String> _iosTunnelDiagnostics() async {
    final parts = <String>[];
    final st = await _iosVpnStatus();
    if (st != null) parts.add('隧道状态: $st');
    // App 侧轨迹（含 NE 会话状态变化）—— 扩展没起来时这是唯一线索
    try {
      final appSide = await _channel.invokeMethod<String>('fetchVpnDiag');
      if (appSide != null && appSide.trim().isNotEmpty) {
        parts.add('[App 侧轨迹]\n$appSide');
      }
    } catch (_) {}
    try {
      final live = await _channel.invokeMethod<String>('fetchTunnelDiag');
      if (live != null && live.trim().isNotEmpty) {
        parts.add('[扩展内存轨迹]\n$live');
      }
    } catch (_) {}
    try {
      final persisted = await _channel.invokeMethod<String>('fetchTunnelLog');
      // 注意：即使是「暂无 tunnel.log」也要带上 —— 这条本身就是关键结论
      // （扩展从未被系统拉起 / App Group 失效），原先被过滤掉反而丢线索
      if (persisted != null && persisted.trim().isNotEmpty) {
        parts.add('[扩展落盘轨迹]\n$persisted');
      }
    } catch (_) {}
    return parts.join('\n');
  }

  /// 取文本末尾 [n] 行（诊断块很长，错误文案里只放最有价值的尾部）
  static String _lastLines(String text, int n) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.length <= n) return lines.join(' / ');
    return lines.sublist(lines.length - n).join(' / ');
  }

  @override
  Future<void> stop() async {
    _running = false;
    _watchdog?.cancel();
    _watchdog = null;
    _trafficCancel?.cancel();
    _trafficCancel = null;
    try {
      await _channel.invokeMethod('stopVpn');
      // 等待原生真正停完（VpnService 销毁 + 内核 stop 是异步的）。
      // 若不等待就立刻重连，旧内核还在停止中，新 start 会被
      // 「内核已在运行」忽略，随后旧内核停掉 → 新连接 15s 轮询超时。
      for (var i = 0; i < 40; i++) {
        final alive = await _channel.invokeMethod<bool>('isVpnRunning') ?? false;
        if (!alive) break;
        await Future.delayed(const Duration(milliseconds: 150));
      }
    } catch (_) {}
  }

  @override
  Future<void> switchMode(bool smart) async {
    _smartMode = smart;
    // sing-box: Rule=智能 / Global=全局，两套规则用 clash_mode 前缀区分，
    // PATCH /configs 热切换即可，不断网
    await _clash('PATCH', '/configs', {'mode': smart ? 'Rule' : 'Global'});
  }

  @override
  Future<void> switchNode(String tag) async {
    _lastNodeTag = tag;
    // sing-box 没有内置 GLOBAL 组：两种模式的路由终点都是 select 选择器
    await _clash('PUT', '/proxies/select', {'name': tag});
  }

  @override
  Future<void> setKernelLogLevel(String level) async {
    // sing-box 的 clash API 不支持热改日志级别（由启动配置决定）→ no-op
  }

  @override
  Future<int> testNodeDelay(String tag,
      {Duration timeout = const Duration(seconds: 5), String? url}) async {
    if (!_running) return -1;
    try {
      final r = await _api.get(
        // 节点名必须 URL 编码（emoji/空格/斜杠/中文），见 kernelDelayPath
        kernelDelayPath(tag),
        queryParameters: {
          'timeout': timeout.inMilliseconds,
          'url': url ?? defaultKernelDelayUrl,
        },
        options: Options(
            validateStatus: (s) => true,
            receiveTimeout: timeout + const Duration(seconds: 2)),
      );
      // 只有 200 + {'delay': <num>} 才算成功；407/408/超时 → -1（绝不给假数字）
      return parseKernelDelayResponse(r.statusCode, r.data);
    } catch (_) {
      return -1;
    }
  }

  Future<void> _clash(String method, String path, Object body) async {
    if (!_running) throw StateError('not running');
    try {
      await _api.request(path,
          data: body,
          options: Options(
              method: method,
              validateStatus: (s) => s != null && s >= 200 && s < 300));
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        _apiAuthFailed = true;
        AppLog.error('内核 API 鉴权失败（$method $path → HTTP $code）：'
            'secret 与内核配置不一致，热切换必然失败');
      }
      rethrow;
    }
  }

  bool _watchdogInFlight = false;

  /// 最近一次 API 调用是否因鉴权失败（供 UI/日志诊断：热切换失败的真实原因）
  bool _apiAuthFailed = false;
  bool get apiAuthFailed => _apiAuthFailed;

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdogFailures = 0;
    _watchdogInFlight = false;
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_running || _watchdogInFlight) return;
      _watchdogInFlight = true;
      try {
        bool ok;
        try {
          final r = await _api.get('/version',
              options: Options(validateStatus: (s) => true));
          final code = r.statusCode ?? 0;
          // ⚠️ 只要内核**回了 HTTP** 就说明它活着：401/403 是鉴权问题
          // （secret 与配置不一致，热切换会失败，但不代表内核死了）。
          // 旧实现要求严格 200 → iOS 扩展侧 secret 为空时每 15s 判死一次，
          // 触发 connect→死→recover 无限循环（客户实测「经常自动断开」）。
          ok = code > 0 && code < 500;
          if (!ok) {
            AppLog.kernel('watchdog: /version 返回 $code');
          } else if (code == 401 || code == 403) {
            _apiAuthFailed = true;
            AppLog.error('内核 API 鉴权失败（HTTP $code）：热切换/测速会失败，'
                '请检查 secret 是否与配置一致');
          } else {
            _apiAuthFailed = false;
          }
        } catch (_) {
          ok = false;
        }
        if (ok) {
          _watchdogFailures = 0;
          return;
        }
        _watchdogFailures++;
        var nativeAlive = _watchdogFailures >= _watchdogDeadThreshold
            ? await _nativeVpnAlive()
            : true;
        // 判死前**二次确认**：iOS 的 NEVPNStatus 在系统调整隧道（reasserting/
        // 网络切换）瞬间可能返回 false，一次采样不可信。再查一次仍为 false 才认。
        if (!nativeAlive) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
          final again = await _nativeVpnAlive();
          if (again) {
            AppLog.kernel('watchdog: 原生状态抖动（false→true），保持连接');
            nativeAlive = true;
          }
        }
        final action = decideWatchdog(
          pollOk: false,
          consecutiveFailures: _watchdogFailures,
          deadThreshold: _watchdogDeadThreshold,
          nativeAlive: nativeAlive,
        );
        switch (action) {
          case WatchdogAction.healthy:
          case WatchdogAction.keepAlive:
            if (nativeAlive && _watchdogFailures >= _watchdogDeadThreshold) {
              _watchdogFailures = 0;
            }
            return;
          case WatchdogAction.declareDead:
            _onKernelDead();
        }
      } finally {
        _watchdogInFlight = false;
      }
    });
  }

  /// 向原生查询 VpnService.isRunning（内核真死亡时才为 false）。
  /// 查询本身异常时保守返回 true（宁可不断连，也不误杀存活隧道）。
  Future<bool> _nativeVpnAlive() async {
    try {
      return await _channel.invokeMethod<bool>('isVpnRunning') ?? true;
    } catch (_) {
      return true;
    }
  }

  void _onKernelDead() {
    _running = false;
    _watchdogFailures = 0;
    _lastError = AppStrings.t('kernel_exit');
    _trafficCancel?.cancel();
    AppLog.kernel('watchdog declared dead, failures=$_watchdogDeadThreshold');
    _onUnexpectedExit?.call();
  }

  void _startTrafficStream() {
    _trafficCancel?.cancel();
    _trafficCancel = CancelToken();
    _trafficBuf.clear();
    unawaited(_streamTraffic(_trafficCancel!));
  }

  Future<void> _streamTraffic(CancelToken cancel) async {
    while (_running && !cancel.isCancelled) {
      try {
        final resp = await _api.get('/traffic',
            cancelToken: cancel,
            options: Options(responseType: ResponseType.stream));
        final stream = resp.data.stream as Stream<List<int>>;
        await for (final chunk in stream) {
          if (cancel.isCancelled || !_running) break;
          _trafficBuf.addAll(chunk);
          if (_trafficBuf.length > 64 * 1024) _trafficBuf.removeRange(0, _trafficBuf.length - 4096);
          while (true) {
            final nl = _trafficBuf.indexOf(0x0A);
            if (nl < 0) break;
            final line = utf8.decode(_trafficBuf.sublist(0, nl)).trim();
            _trafficBuf.removeRange(0, nl + 1);
            if (line.isEmpty) continue;
            try {
              final obj = jsonDecode(line);
              if (obj is Map && obj['up'] is num && obj['down'] is num) {
                _onTraffic?.call(
                  (obj['up'] as num) / 1024 / 1024,
                  (obj['down'] as num) / 1024 / 1024,
                );
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
      if (!_running || cancel.isCancelled) break;
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _trafficCancel?.cancel();
    _api.close(force: true);
    unawaited(stop());
  }
}
