import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import '../models/models.dart';
import '../services/app_log.dart';
import 'kernel_delay_api.dart';
import 'singbox_config.dart';
import 'proxy_core_cli.dart';

/// 内核测速的启动/探测失败（带可展示原因，**绝不静默回落 TCP**）。
///
/// 为什么要有类型化错误：旧实现「未连接就退回纯 TCP」是**静默**的 ——
/// 用户以为看到的是内核实测延迟，其实是端口握手，于是「有延迟但连不上」。
/// 内核测速失败时必须让调用方拿到原因，由 UI 明确告知用户。
class KernelProbeException implements Exception {
  KernelProbeException(this.message, {this.detail});
  final String message;
  final String? detail;
  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

/// 测速专用内核（临时 sing-box 实例，仅用于 `/proxies/{name}/delay` 真连接测速）。
///
/// ## 为什么需要它
/// 「内核测速」= 让内核真的通过节点发一次请求。它要求有一个**运行中**的内核。
/// 而用户点测速时通常**还没连接**（正在挑节点）—— 这时没有内核可用。
/// 桌面端（macOS/Windows/Linux）内核本来就是 App 拉起的子进程，因此这里再拉起
/// 一个**只做延迟探测**的临时实例：测完按空闲超时自动退出。
///
/// ## 与真实连接实例的隔离（每一条都对应一种真实故障）
/// - **独立工作目录** `${tmp}/mbox_probe`：config.json / cache.db 不与
///   连接内核（`mbox_core`）争锁。共用目录会出现 `[CacheFile] can't open
///   cache file: timeout` 与「配置文件被另一个实例覆盖」。
/// - **动态空闲端口**（`bind(0)` 取一个当前空闲的端口）：不碰用户设置的
///   `clashApiPort`(9090) / `localPort`(2080)，因此**连接与测速可同时存在**，
///   也不会把正在用的 9090 顶掉。
/// - **无入站监听、无 TUN、无系统代理**：见 [SingBoxConfigBuilder.buildProbe]。
///   不会修改系统代理、不需要管理员权限、不会建虚拟网卡。
/// - **不进入 App 的「已连接」状态**：探测内核与连接状态机完全无关，
///   UI 上不会出现「假装连上了」。
///
/// ## 平台限制（诚实的边界）
/// Android / iOS 的内核跑在系统隧道进程内（VpnService / NetworkExtension），
/// App **无法**自己再起一个实例 → [isSupported] 为 false，调用方应提示用户
/// 「先连接再用内核测速」。这是平台限制，不是可以绕过的实现细节。
class SpeedProbeKernel {
  SpeedProbeKernel._();
  static final SpeedProbeKernel instance = SpeedProbeKernel._();

  /// 工作目录名（同时是命令行里用于识别/回收的片段）。
  static const workDirTag = 'mbox_probe';

  /// 启动后无请求的空闲存活时间：之后自动退出，绝不留常驻进程。
  static const idleTimeout = Duration(seconds: 90);

  /// 内核就绪等待上限。
  static const readyTimeout = Duration(seconds: 12);

  /// 当前平台能否单独拉起探测内核。
  static bool get isSupported =>
      !Platform.isAndroid && !Platform.isIOS;

  /// 测试注入：非空时 [ensureStarted] 直接以该原因失败（生产恒为 null）。
  @visibleForTesting
  static String? debugStartFailure;

  /// 测试注入：非空时 [testDelay] 直接用该函数的结果（生产恒为 null）。
  @visibleForTesting
  static Future<int> Function(String tag)? debugDelayOverride;

  static String get workDir =>
      '${Directory.systemTemp.path}/$workDirTag';

  Process? _proc;
  int _port = 0;
  String _secret = '';
  bool _starting = false;
  bool _stopping = false;
  String? _lastError;
  Timer? _idle;
  final List<String> _logTail = [];
  static const _logKeep = 40;

  /// 最近一次失败原因（UI 展示 / 日志排查用）
  String? get lastError => _lastError;

  bool get isRunning => _proc != null;

  /// 当前探测内核的 Clash API 端口（0 = 未起）。
  /// 公开只读：验收工具（tool/kernel_speed_test_lab.dart）要按真实端口做
  /// 「编码 vs 未编码」的原始 HTTP 对照，日志里也要能看出探测内核用的是哪个端口。
  int get controllerPort => _port;

  Dio get _api => Dio(BaseOptions(
        baseUrl: 'http://127.0.0.1:$_port',
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 10),
        headers: _secret.isEmpty ? null : {'Authorization': 'Bearer $_secret'},
      ));

  /// 确保探测内核已启动（已启动则只续期空闲计时器）。
  ///
  /// [nodes] 只在**首次启动**时用于生成配置：探测内核启动后不再重启
  /// （节点列表变了也不重启，避免每次测速都等内核冷启动；缺的节点会按
  /// 「失败」如实展示 —— 调用方测的永远是当前列表里的 tag）。
  ///
  /// 抛出 [KernelProbeException] 表示无法启动；调用方**必须**把原因告诉用户，
  /// 不得静默改用 TCP 测速。
  /// [logLevel] 固定用 warning：探测内核只跑延迟测试，debug 级会刷出大量
  /// 「connected to ...」噪声，反而把真正有用的失败原因挤出日志尾部
  /// （[_tail] 只保留末尾几行，正是给失败诊断用的）。
  Future<void> ensureStarted(
    List<ProxyNode> nodes, {
    Set<String>? onlyTags,
    String logLevel = 'warning',
  }) async {
    _touchIdle();
    if (debugStartFailure != null) {
      _lastError = debugStartFailure;
      throw KernelProbeException('测速内核不可用', detail: debugStartFailure);
    }
    // 测试注入：延迟结果已被替换 → 不需要真内核（否则单测要依赖内核二进制）。
    if (debugDelayOverride != null) return;
    if (_proc != null) return;
    if (!isSupported) {
      _lastError = 'platform-unsupported';
      // 移动端（Android/iOS）：内核跑在系统隧道进程里，App 起不了第二个实例，
      // 未连接时**无法**做内核测速。而「内核测速」正是默认测速方式（见
      // SpeedTestMode），所以这条失败路径必须给用户**可执行的自救说明**
      // （先连接 / 或临时改成 TCP 测速），而不是一句技术性的「不支持」。
      // 不带 detail：UI 拿到 message 就足够，detail 会让提示变成
      // 「…启动内核失败：<技术细节>」反而更难懂。
      AppLog.log('PROBE', '未连接且平台不支持探测内核（$Platform.operatingSystem）');
      throw KernelProbeException(AppStrings.t('speed_mode_kernel_needs_connect'));
    }
    if (_starting) {
      // 并发调用（用户连点 / 多页面同时测速）：等第一轮启动结束
      final sw = Stopwatch()..start();
      while (_starting && sw.elapsed < readyTimeout) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (_proc != null) return;
      throw KernelProbeException('测速内核启动失败',
          detail: _lastError ?? '启动超时');
    }
    _starting = true;
    try {
      await _start(nodes, onlyTags: onlyTags, logLevel: logLevel);
    } on KernelProbeException {
      rethrow;
    } catch (e) {
      _lastError = '$e';
      throw KernelProbeException('测速内核启动失败', detail: '$e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _start(List<ProxyNode> nodes,
      {Set<String>? onlyTags, required String logLevel}) async {
    _lastError = null;
    _logTail.clear();
    // 先收掉上次异常退出残留的探测内核（只收真孤儿，见 killStaleKernels）
    await ProxyCoreCli.killStaleKernels(tag: workDirTag);

    final binary = await ProxyCoreCli.resolveKernelBinary();
    final dir = Directory(workDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 端口：bind(0) 让系统给一个当前空闲端口，再立刻释放交给内核。
    // 比"猜 9091"可靠：不会踩用户改过的 clashApiPort，也不会踩别的软件占用的端口。
    final port = await _pickFreePort();
    _port = port;
    final cfg = SingBoxConfigBuilder.buildProbe(
      nodes: nodes,
      controllerPort: port,
      onlyTags: onlyTags,
      logLevel: logLevel,
    );
    _secret = cfg['_clashApiSecret']?.toString() ?? '';
    cfg.remove('_clashApiPort');
    cfg.remove('_clashApiSecret');

    // 显式 `-c <config.json>` 传配置：sing-box 不会「静默用默认配置」，
    // 缺配置会直接报错退出，所以文件名不受限制（这里固定 config.json）。
    final configPath = '${dir.path}/config.json';
    await File(configPath)
        .writeAsString(SingBoxConfigBuilder.encode(cfg), flush: true);

    final proc = await Process.start(
      binary,
      ['run', '-c', configPath, '-D', dir.path],
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
    ).catchError((Object e) {
      throw KernelProbeException('无法启动测速内核', detail: '$e');
    });
    _proc = proc;
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLog);
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLog);
    unawaited(proc.exitCode.then((code) {
      if (identical(_proc, proc)) {
        _proc = null;
        if (!_stopping) {
          _lastError = '测速内核意外退出（code=$code）';
          AppLog.error('[probe] 测速内核意外退出 code=$code: ${_tail()}');
        }
      }
    }));

    // 就绪等待：/version 200 才算可用（内核加载 800+ 节点需要一点时间）
    final sw = Stopwatch()..start();
    while (sw.elapsed < readyTimeout) {
      if (_proc == null) {
        throw KernelProbeException('测速内核启动失败',
            detail: _lastError ?? _tail());
      }
      try {
        final r = await _api.get('/version',
            options: Options(validateStatus: (s) => true));
        if (r.statusCode == 200) {
          AppLog.kernel('[probe] 测速内核就绪 port=$_port pid=${proc.pid}');
          _touchIdle();
          return;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 250));
    }
    await stop();
    throw KernelProbeException('测速内核启动超时', detail: _tail());
  }

  /// 让内核走完整代理链路测一个节点的延迟（ms）。失败/超时返回 -1。
  ///
  /// 探测地址默认 [defaultKernelDelayUrl]；[url] 由调用方按设置传入。
  Future<int> testDelay(String tag,
      {Duration timeout = const Duration(seconds: 5), String? url}) async {
    final override = debugDelayOverride;
    if (override != null) return override(tag);
    if (_proc == null) return -1;
    _touchIdle();
    try {
      final r = await _api.get(
        kernelDelayPath(tag),
        queryParameters: {
          'timeout': timeout.inMilliseconds,
          'url': url == null || url.trim().isEmpty
              ? defaultKernelDelayUrl
              : url.trim(),
        },
        options: Options(
            validateStatus: (s) => true,
            receiveTimeout: timeout + const Duration(seconds: 2)),
      );
      final ms = parseKernelDelayResponse(r.statusCode, r.data);
      if (ms < 0) {
        final why = kernelDelayErrorMessage(r.statusCode, r.data);
        if (why != null) {
          AppLog.log('PROBE', 'delay 失败 $tag → $why');
        }
      }
      return ms;
    } catch (e) {
      // 探测内核在测速途中死掉：如实返回失败（不给假数字）
      AppLog.log('PROBE', 'delay 异常 $tag → $e');
      return -1;
    } finally {
      _touchIdle();
    }
  }

  /// 按**原样路径**请求探测内核，返回 HTTP 状态码（-1 = 请求异常）。
  ///
  /// 存在的唯一目的：给验收实验提供「未编码 vs 编码」的原始对照 ——
  /// 直接拿 [kernelDelayPath] 之外的裸路径打内核，会被 URI 解析截断成
  /// `/proxies/名字的前半段/delay`，内核返回 400（proxy not found）。
  /// 这条对照就是「节点名必须 URL 编码」的现场证据，因此把 secret 封装在内部，
  /// 不对外暴露密钥本身。
  Future<int> rawGetStatus(String path) async {
    if (_proc == null) return -1;
    try {
      final r = await _api.get(path,
          options: Options(validateStatus: (s) => true));
      return r.statusCode ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// 关闭探测内核（断开连接、App 退出、空闲超时都会调用；幂等）。
  Future<void> stop() async {
    _idle?.cancel();
    _idle = null;
    final proc = _proc;
    _proc = null;
    if (proc == null) return;
    _stopping = true;
    try {
      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    } catch (_) {
    } finally {
      _stopping = false;
      AppLog.kernel('[probe] 测速内核已退出 pid=${proc.pid}');
    }
  }

  /// 空闲计时：每完成一次交互就重置；超时后自动 stop，绝不留常驻探测内核。
  void _touchIdle() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () {
      if (_proc != null) {
        AppLog.kernel('[probe] 空闲 ${idleTimeout.inSeconds}s，回收测速内核');
      }
      unawaited(stop());
    });
  }

  static Future<int> _pickFreePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  void _onLog(String line) {
    _logTail.add(line);
    if (_logTail.length > _logKeep) _logTail.removeAt(0);
  }

  /// 内核日志尾部（启动失败时把真正的 error 行带进异常详情）。
  String _tail() {
    if (_logTail.isEmpty) return '（无输出）';
    final start = _logTail.length > 6 ? _logTail.length - 6 : 0;
    return _logTail.sublist(start).join(' | ');
  }

  @visibleForTesting
  void resetForTest() {
    _idle?.cancel();
    _idle = null;
    _proc = null;
    _port = 0;
    _secret = '';
    _lastError = null;
    _logTail.clear();
    _starting = false;
    _stopping = false;
  }
}
