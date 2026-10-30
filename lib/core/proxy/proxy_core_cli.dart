import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'proxy_core.dart';
import 'geo_assets.dart';
import 'kernel_delay_api.dart';
import 'port_guard.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';
import '../platform/mac_tun_helper.dart';
import 'tun_failure.dart';
import '../../l10n/app_strings.dart';
import '../services/app_log.dart';
import '../services/kernel_log.dart';
import '../services/local_paths.dart';

/// sing-box CLI 子进程 + 本地 Clash API（macOS / Windows / Linux）
///
/// 连接 = 写 config.json → 启动 `sing-box run -c config.json -D <workDir>`
/// → 轮询 Clash API 就绪；
/// 切模式/切节点走 Clash API 热更新，不重启内核不断网；
/// 流量统计 1s 拉一次 /traffic（仅连接时，断开即停）。
///
/// 内核二进制位置（CI 打包进安装包；本地开发用 tool/fetch_singbox.sh 获取）：
///   macOS    `App.app/Contents/MacOS/sing-box`
///   Windows  `exe 同目录/sing-box.exe`
///   可用环境变量 MBOX_SINGBOX 覆盖（开发调试用）。
class ProxyCoreCli extends ProxyCore {

  /// 是否由 app 管理系统代理（连接时设置、断开时恢复）。
  /// 集成测试置 false，避免改动真实系统代理。
  static bool manageSystemProxy = true;

  /// 内核工作目录（config.json + 离线规则集 .srs 落盘处；
  /// sing-box 以 -D 指定工作目录，配置里用绝对路径引用规则集）
  static final String workDir = '${Directory.systemTemp.path}/mbox_core';
  static const _readyTimeout = Duration(seconds: 10);

  /// 内核日志实时流（广播）：_onLog 收到的每行都推送，
  /// 「内核日志」实时页订阅展示
  static final StreamController<String> kernelLogStream =
      StreamController<String>.broadcast();

  /// 最近内核日志快照（实时页初始历史用，环形保留末尾 ~200 行）
  static List<String> logTailSnapshot() =>
      List.unmodifiable(_lastCoreLogs);

  /// 当前智能(Rule)/全局(Global)状态。sing-box 的模式热切换走
  /// PATCH /configs，节点热切换固定打 select 选择器（两种模式共用），
  /// 这里保留状态仅用于启动日志输出。
  bool _smartMode = true;

  final Dio _api = Dio(BaseOptions(
    baseUrl: 'http://127.0.0.1:9090',
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
  ));

  Process? _proc;

  /// 启动流程进行中标志。`start()` 从第一行到 `Process.start` 之间有 5 个 await，
  /// 期间 `_proc` 仍是 null —— 只检查 `_proc` 会让并发 `start()` 双双通过守卫
  /// （双开内核 → `_proc` 被覆盖 → 失去跟踪的那个成为清不掉的孤儿）。
  bool _starting = false;
  bool _intentionalStop = false;

  /// 本次内核是否通过 `sudo -n` 以 root 启动（macOS TUN 专用，见 MacTunHelper）
  bool _launchedViaSudo = false;

  /// 内核工作目录（sudo 启动时用于兜底 pkill）
  String? _kernelDir;

  /// 本次启动是否已经就「TUN 起不来」报过一次日志（避免就绪轮询里刷屏）
  bool _tunFailureLogged = false;

  /// 内核日志里第一条「真致命」TUN 行 + 紧随其后的上下文（供分类）
  final List<String> _tunFatalContext = [];

  /// 出现过「像 TUN 出错」但无法确认的行（见 looksLikeTunTrouble）
  bool _tunSuspectSeen = false;
  String? _lastError;
  String? _configPath;

  /// 本机 mixed 入站端口（设置页可改；随配置传入，默认 2080）。
  /// 系统代理的 apply/保活/探测全部指向该端口。
  int _localPort = SystemProxyManager.defaultPort;

  /// Clash API 管理端口（设置页可改；随配置传入，默认 9090）
  int _clashApiPort = 9090;

  /// 系统代理保活定时器：连接期间周期检查，被系统/外部关掉就重新开启。
  /// 目标：只要内核在跑，系统代理就保持指向本地端口，直到断开/退出。
  /// 20s 一次：探测是子进程(reg query / networksetup)，过密会累积进程创建
  /// 开销(macOS 每轮服务数×3 并行)；20s 内恢复被外部关闭的代理已足够快。
  Timer? _proxyKeepAlive;
  static const _proxyKeepAliveInterval = Duration(seconds: 20);

  /// 进程异常退出（非主动断开）→ 控制器触发自动重连
  VoidCallback? _onUnexpectedExit;

  /// 实时速率回调（MB/s），1s 一次，仅连接期间
  void Function(double upMbps, double downMbps)? _onTraffic;

  @override
  VoidCallback? get onUnexpectedExit => _onUnexpectedExit;

  @override
  set onUnexpectedExit(VoidCallback? cb) => _onUnexpectedExit = cb;

  @override
  void Function(double upMbps, double downMbps)? get onTraffic => _onTraffic;

  @override
  set onTraffic(void Function(double upMbps, double downMbps)? cb) =>
      _onTraffic = cb;

  CancelToken? _trafficCancel;
  final List<int> _trafficBuf = [];

  /// 最近内核日志（错误排查用，环形保留末尾 ~40 行）
  final List<String> _logTail = [];
  static const _logKeep = 40;
  /// 进程级内核日志环形缓冲（日志实时页跨实例读取；上限 200 行）
  static final List<String> _lastCoreLogs = [];
  static const _coreLogKeep = 200;

  @override
  bool get isRunning => _proc != null;

  @override
  String? get lastError => _lastError;

  /// 定位 sing-box 可执行文件（优先级：测试注入 → 用户切换/更新的副本
  /// [KernelManager.userActivePath] → 安装内置）。
  /// 用户副本放在应用支持目录，任意安装目录(含只读的 Program Files)都可用。
  Future<String> resolveBinary() => resolveKernelBinary();

  /// [resolveBinary] 的静态形式：测速专用内核（[SpeedProbeKernel]）也要用同一份
  /// 定位逻辑，否则会出现「连接能找到内核、测速找不到」这种只在部分安装方式下
  /// 复现的诡异故障（Program Files 只读、用户内核副本、测试注入三处任一不同）。
  static Future<String> resolveKernelBinary() async {
    // 环境变量注入（测试/开发）：MBOX_SINGBOX 指向内核可执行文件
    final injected = Platform.environment['MBOX_SINGBOX'];
    if (injected != null &&
        injected.isNotEmpty &&
        File(injected).existsSync()) {
      return injected;
    }
    // 用户内核副本优先（内核管理页切换/更新写入的位置，与 KernelManager 同名）
    try {
      final support = await LocalPaths.supportDir();
      if (support != null) {
        final userBin =
            '${support.path}/kernel/sing-box${Platform.isWindows ? '.exe' : ''}';
        if (File(userBin).existsSync()) return userBin;
      }
    } catch (_) {}
    final exe = Platform.resolvedExecutable;
    final name = 'sing-box${Platform.isWindows ? '.exe' : ''}';
    final candidates = <String>[
      if (Platform.isMacOS) '${Directory(exe).parent.path}/$name',
      '${Directory(exe).parent.path}/$name',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    throw FileSystemException(
      '未找到 sing-box 内核二进制。\n'
      '开发环境请运行: bash tool/fetch_singbox.sh\n'
      '发布包由 CI 自动内置内核，无需额外操作。',
    );
  }

  bool _tunForceMode = false;

  /// 清理指向本项目工作目录的「僵尸 sing-box 进程」。
  ///
  /// 场景：App 被强杀/崩溃/异常退出时，内核子进程(sing-box run -c workDir/config.json)可能
  /// 残留，继续占用 9090/2080 与 cache.db 锁 —— 再次启动时新内核
  /// bind 失败("address already in use")+ "[CacheFile] can't open cache
  /// file: timeout"，表现为「退出后重开连不上」。
  /// 只匹配命令行含本项目工作目录标记的内核，不会误杀其它代理软件。
  ///
  /// **只收真孤儿**（[isStaleKernelCandidate]）：父进程还活着的内核一律不动。
  /// 旧实现无条件 kill 所有匹配进程，多开/双实例时会把**另一个实例正在用的活内核**
  /// 杀掉（2026-09-14 日志里的 `KERNEL process exited unexpectedly, code=-1`：
  /// PowerShell 的 `Stop-Process -Force` 终止码正是 -1），随后因为
  /// autoReconnect 默认关闭而不再恢复，用户看到的是「好好的突然断线」。
  /// [livePid] 额外豁免本实例当前跟踪的内核 pid。
  ///
  /// [tag] 是命令行里用于识别「本 App 的内核」的工作目录片段：连接内核用
  /// [_workDirTag]，测速专用内核用 [SpeedProbeKernel.workDirTag]。两者分开收，
  /// 因为 App 启动时只应清理连接内核（探测内核由它自己按空闲超时退出）。
  static Future<void> killStaleKernels({int? livePid, String? tag}) async {
    final t = tag ?? _workDirTag;
    try {
      if (Platform.isWindows) {
        await _reapStaleKernelsWindows(livePid, t);
        return;
      }
      await _reapStaleKernelsPosix(livePid, t);
    } catch (_) {}
  }

  /// 残留内核判定（纯函数，便于单测）。
  ///
  /// 判据是**父进程是否还是本 App**：
  /// - 父进程已消失 → 真孤儿（上次 App 被强杀留下的），可收；
  /// - 父进程是活着的 MBox → 那是**别的实例正在使用的内核**，绝不能杀；
  /// - 父进程活着但不是 MBox（PID 被复用的极端情况）→ 按残留处理，
  ///   否则端口/cache 锁永远解不开，连接一直 bind 失败。
  @visibleForTesting
  static bool isStaleKernelCandidate({
    required int pid,
    required int? parentPid,
    required bool parentAlive,
    required bool parentIsApp,
    int? livePid,
  }) {
    if (pid <= 1) return false; // 0/1 是内核线程与 init，绝不碰
    if (livePid != null && pid == livePid) return false; // 本实例在跟踪的内核
    if (parentPid == null) return true; // 拿不到 ppid → 视为孤儿
    if (!parentAlive) return true; // 父进程没了
    return !parentIsApp; // 父进程活着：是 App → 别动，不是 App → PID 复用
  }

  /// 进程命令行里出现这个片段即认定为「本 App 的内核」（workDir 名）。
  static const _workDirTag = 'mbox_core';

  /// Windows：用一次 PowerShell 列出候选内核及其父进程信息，再由 Dart 决策，
  /// 只对判定为孤儿的 pid 逐个 `Stop-Process -Force`。
  ///
  /// 决策放在 Dart（而非整段写在 PowerShell 里）是为了可单测，也避免
  /// 「一个 Where-Object 写错就把活内核全杀了」这类无法回归的脚本 bug。
  static Future<void> _reapStaleKernelsWindows(int? livePid, String tag) async {
    // 原始字符串 + 运行期替换 tag：`$($_.ParentProcessId)`、`$p`、`$_` 必须原样
    // 交给 PowerShell，绝不能被 Dart 插值（`$p` 会被当成 Dart 变量直接编译报错）。
    final script = r'''Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'sing-box' -and $_.CommandLine -match '__MF_TAG__' } | ForEach-Object { $p = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.ParentProcessId)" -ErrorAction SilentlyContinue; "$($_.ProcessId)|$($_.ParentProcessId)|$($p.Name)" }'''
        .replaceAll('__MF_TAG__', tag);
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      script,
    ]);
    if (r.exitCode != 0) return;
    for (final line in (r.stdout as String).split('\n')) {
      final parts = line.trim().split('|');
      if (parts.length < 3) continue;
      final pid = int.tryParse(parts[0].trim());
      if (pid == null) continue;
      final ppid = int.tryParse(parts[1].trim());
      final parentName = parts[2].trim();
      final parentAlive = parentName.isNotEmpty;
      if (!isStaleKernelCandidate(
        pid: pid,
        parentPid: ppid,
        parentAlive: parentAlive,
        parentIsApp: parentName.toLowerCase().contains('mbox'),
        livePid: livePid,
      )) {
        if (parentAlive) {
          AppLog.kernel(
              'keep running kernel pid=$pid (parent $ppid $parentName alive)');
        }
        continue;
      }
      AppLog.kernel('kill stale sing-box pid=$pid (parent ${ppid ?? '?'} gone)');
      // `$pid` 由 Dart 插值成真实 pid（PowerShell 侧不再有变量）；沿用
      // Stop-Process -Force（其终止码为 -1，与日志里「被自己人收掉」的现场
      // 特征一致，便于事后区分外部强杀）
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue',
      ]);
    }
  }

  /// macOS / Linux：同一份 `ps` 快照里既有候选内核，也有它们父进程的命令行 ——
  /// 父进程是否存活、是否是本 App 都从这一份快照读，不再额外探测（少两次 fork）。
  static Future<void> _reapStaleKernelsPosix(int? livePid, String tag) async {
    final r = await Process.run('ps', ['-axo', 'pid,ppid,command'],
        environment: {'PATH': Platform.environment['PATH'] ?? ''});
    if (r.exitCode != 0) return;
    // pid → 命令行（用于判断父进程是否存活/是否本 App）
    final cmdByPid = <int, String>{};
    final candidates = <({int pid, int ppid})>[];
    for (final line in (r.stdout as String).split('\n')) {
      final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$').firstMatch(line);
      if (m == null) continue;
      final pid = int.tryParse(m.group(1)!);
      final ppid = int.tryParse(m.group(2)!);
      if (pid == null || ppid == null) continue;
      final cmd = m.group(3) ?? '';
      cmdByPid[pid] = cmd;
      if (cmd.contains('sing-box') && cmd.contains(tag)) {
        candidates.add((pid: pid, ppid: ppid));
      }
    }
    for (final c in candidates) {
      final parentCmd = cmdByPid[c.ppid];
      if (!isStaleKernelCandidate(
        pid: c.pid,
        parentPid: c.ppid,
        parentAlive: parentCmd != null,
        parentIsApp: (parentCmd ?? '').toLowerCase().contains('mbox'),
        livePid: livePid,
      )) {
        if (parentCmd != null) {
          AppLog.kernel(
              'keep running kernel pid=${c.pid} (parent ${c.ppid} alive)');
        }
        continue;
      }
      AppLog.kernel(
          'kill stale sing-box pid=${c.pid}: ${cmdByPid[c.pid]?.trim()}');
      await Process.run('kill', ['-9', '${c.pid}']);
    }
  }

  @override
  Future<void> start(Map<String, dynamic> config) async {
    // 守卫覆盖**整个**启动过程（见 _starting 说明），否则并发启动会双开内核
    if (_proc != null || _starting) throw StateError('内核已在运行');
    _starting = true;
    try {
      await _startKernel(config);
    } finally {
      _starting = false;
    }
  }

  /// 实际启动流程（由 [start] 在 `_starting` 互斥保护下调用）
  Future<void> _startKernel(Map<String, dynamic> config) async {
    _intentionalStop = false;
    _lastError = null;
    _logTail.clear();
    _tunFailureLogged = false;
    _tunFatalContext.clear();
    _tunSuspectSeen = false;
    // 桌面端兜底：清理上次异常退出残留的僵尸内核（避免端口/cache 锁冲突）。
    // 只收真孤儿 —— 父进程还活着的内核属于别的实例，杀了就是「好好的突然断线」。
    await killStaleKernels(livePid: _proc?.pid);
    // 把内核日志落盘路径写进 app_log：用户导出 app_log 时能顺着找到完整内核输出
    KernelLog.announcePaths();

    // 从配置同步当前模式（Rule=智能 / Global=全局）。sing-box 没有顶层 mode
    // 字段，模式在 experimental.clash_api.default_mode 里。
    final exp = config['experimental'];
    final apiCfg = exp is Map ? exp['clash_api'] : null;
    final startMode = apiCfg is Map ? apiCfg['default_mode']?.toString() : null;
    _smartMode = startMode != 'Global';
    // tunMode='force' 时无 mixed 端口，不管理系统代理
    _tunForceMode = config.remove('_tunMode') == 'force';
    // 本机监听端口（设置页自定义，默认 2080）
    _localPort =
        (config.remove('_localPort') as num?)?.toInt() ?? SystemProxyManager.defaultPort;
    // Clash API 管理端口（设置页自定义，默认 9090）
    _clashApiPort = (config.remove('_clashApiPort') as num?)?.toInt() ?? 9090;
    final clashSecret = config.remove('_clashApiSecret')?.toString() ?? '';
    _api.options.baseUrl = 'http://127.0.0.1:$_clashApiPort';
    if (clashSecret.isNotEmpty) {
      _api.options.headers['Authorization'] = 'Bearer $clashSecret';
    }

    final binary = await resolveBinary();
    final dir = Directory(workDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _configPath = '${dir.path}/config.json';

    // 确保离线 geo 数据就位（connect 路径会提前落盘；集成测试/外部直接调
    // start 时自保。幂等：文件已存在且非空则跳过）。
    // 失败时移除配置里的 rule_set 声明与引用它的规则：sing-box 一旦引用
    // 本地规则集而文件缺失，**启动直接失败**（parse rule-set: open ...），
    // 内置 assets 理应就位，缺失属异常 → 宁可降级全代理也要让内核起来。
    final geoOk = await GeoAssets.materialize(preferDir: workDir);
    if (!geoOk) {
      final route = config['route'];
      if (route is Map) {
        final sets = route['rule_set'];
        final tags = <String>{};
        if (sets is List) {
          for (final rs in sets) {
            if (rs is Map && rs['tag'] != null) tags.add(rs['tag'].toString());
          }
        }
        route.remove('rule_set');
        final rules = route['rules'];
        if (rules is List) {
          route['rules'] = rules.where((r) {
            if (r is! Map) return true;
            final ref = r['rule_set'];
            if (ref is List) {
              return !ref.any((t) => tags.contains(t.toString()));
            }
            return true;
          }).toList();
        }
      }
    }

    // sing-box 读 JSON：SingBoxConfigBuilder.encode 会剥离 `_` 前缀元数据键
    await File(_configPath!).writeAsString(SingBoxConfigBuilder.encode(config), flush: true);

    // 端口预检（`bind: address already in use` 的根治点）。
    //
    // 为什么必须在起进程**之前**做：[killStaleKernels] 只收「父进程已消失」的真
    // 孤儿；而占着端口的两类进程它按设计不会动 —— 上一版/另一实例残留的内核
    // （父进程还活着）、桌面端的测速探测内核。这些不处理，内核必然 bind 失败，
    // 而失败信息只有内核那句 FATAL，用户完全无从下手（线上日志里连续 7 次
    // `listen tcp 127.0.0.1:2080: bind: address already in use` 就是这么来的）。
    //
    // 处理口径：我方残留 → 杀掉并等端口真正释放（用户无感自愈）；
    // 别人的程序 → 抛类型化错误（带进程名/PID），UI 给「换端口并重连」。
    // TUN force 模式下没有 mixed 入站，本地端口不参与监听，跳过即可。
    if (!_tunForceMode) {
      await PortGuard.ensureFree(_localPort, what: AppStrings.t('port_what_local'));
    }
    await PortGuard.ensureFree(_clashApiPort, what: AppStrings.t('port_what_api'));

    // macOS 的 TUN 必须 root：仅当「强制 TUN」且用户已一次性授权时走 sudo -n
    // （普通系统代理模式仍以当前用户运行内核，完全不需要提权）。
    var useSudo = false;
    if (Platform.isMacOS && _tunForceMode) {
      useSudo = await MacTunHelper.isGranted(binary);
      if (!useSudo) {
        AppLog.kernel('macOS TUN：尚未授权（sudo -n 不可用），内核将以当前用户启动');
      }
    }
    _launchedViaSudo = useSudo;
    _kernelDir = dir.path;
    final kernelArgs = ['run', '-c', _configPath!, '-D', dir.path];
    _proc = useSudo
        ? await Process.start(
            'sudo',
            ['-n', binary, ...kernelArgs],
            environment: {'PATH': Platform.environment['PATH'] ?? ''},
          )
        : await Process.start(
            binary,
            kernelArgs,
            environment: {'PATH': Platform.environment['PATH'] ?? ''},
          );

    _proc!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLog);
    _proc!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLog);
    unawaited(_watchProcess());
    // sing-box 在 warn 级别下启动**不输出任何日志**（旧内核有 banner），
    // 内核日志页会一片空白 → 补一条 app 侧启动记录（内核路径/端口/模式/规则集）
    _onLog('[app] sing-box 已启动：$binary');
    _onLog('[app] 配置 $_configPath｜本地端口 $_localPort｜API 端口 $_clashApiPort'
        '｜模式 ${_smartMode ? "智能(Rule)" : "全局(Global)"}');

    // 等内核就绪（Clash API 可访问 + 本地 mixed 端口真的在监听）
    final sw = Stopwatch()..start();
    var apiReadyButPortDead = false;
    while (sw.elapsed < _readyTimeout) {
      if (_proc == null) {
        // 内核因 TUN 起不来而立即退出（macOS 未授权时 sing-box 打
        // `start tun: operation not permitted` 就退出）必须按 TUN 分类上报，
        // 否则用户只看到「内核进程启动后立即退出」，不知道该提权。
        final tunFailure = detectTunStartFailure(_tunFatalContext);
        if (tunFailure != TunStartFailure.none) {
          throw TunStartException(tunFailure, _tunFatalContext.join(' | '));
        }
        // 进程启动后立即退出（_watchProcess 已记录退出码与尾部日志）：
        // 给出可诊断信息，而不是含糊的「（无输出）」
        final why = (_lastError?.isNotEmpty ?? false)
            ? _lastError!
            : '内核进程启动后立即退出';
        // 端口被占用：翻译成**类型化 + 短文案**。内核那句 FATAL 又长又是英文
        // （还夹着多行上下文），塞进首页错误区用户根本读不懂 —— 而它其实只说明
        // 一件事：端口被占了，要么关掉占用者，要么换端口。完整日志仍在
        // kernel_log.txt（错误提示里已给出路径）。
        if (PortGuard.looksLikePortInUse(why)) {
          await stop();
          throw await _portInUseError(why);
        }
        throw UnsupportedError('内核启动失败：$why$_winKernelHint');
      }
      try {
        final r = await _api.get('/version', options: Options(validateStatus: (s) => true));
        if (r.statusCode == 200) {
          // API 200 **不代表内核在干活**：mixed-port 非法（越界）或被占用时，
          // 内核只打 error 日志却继续运行、Clash API 照样返回 200。若不复查
          // 本地监听端口，App 会把系统代理指向死端口 → 整机断网且零提示。
          // （TUN force 模式没有 mixed 入站，跳过探活。）
          if (!_tunForceMode && !await _portListening(_localPort)) {
            apiReadyButPortDead = true;
            await Future.delayed(const Duration(milliseconds: 200));
            continue;
          }
          // TUN 判定：只认「真的没起来」的致命串（见 tun_failure.dart），
          // 且用边收边判的 [_tunFatalContext]（不受 40 行缓冲与 debug 级别影响）。
          final tunFailure = detectTunStartFailure(_tunFatalContext);
          if (tunFailure != TunStartFailure.none) {
            if (_tunForceMode) {
              // force 模式只有 TUN 一条路 → 必须中断，否则是假连接
              await stop();
              throw TunStartException(tunFailure, _tunFatalContext.join(' | '));
            }
            // 自动模式（TUN + 系统代理）：TUN 挂了系统代理仍可用，不该中断连接；
            // 但绝不能静默 —— 用户以为游戏/UDP 走了代理，实际是直连。
            if (!_tunFailureLogged) {
              _tunFailureLogged = true;
              AppLog.error('[TUN] 启动失败（${tunFailure.name}），'
                  '本次连接仅系统代理生效（UDP/游戏等不走代理）：'
                  '${_tunFatalContext.join(' | ')}');
            }
          } else if (_tunSuspectSeen && !_tunFailureLogged) {
            // 弱判据：有「像 TUN 出错」的行但无法确认致命。不中断连接（不重演
            // 「正常连接被判死」），但留痕 —— 万一内核换了失败文案，至少日志里
            // 能查到线索，而不是静默假连接。
            _tunFailureLogged = true;
            AppLog.error('[TUN] 检测到 TUN 相关错误但无法确认是否致命'
                '（force 模式请确认是否有流量）：${_tail()}');
          }
          // 内核就绪后管理系统代理（仅有 mixed 端口时，TUN force 模式不需要）
          if (manageSystemProxy && !_tunForceMode) {
            await SystemProxyManager.apply(port: _localPort);
            _startProxyKeepAlive();
          }
          _startStatsTimer();
          return;
        }
      } catch (_) {
        // 未就绪，继续等
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await stop();
    if (apiReadyButPortDead) {
      // 内核跑着但 mixed 端口没监听：最常见就是端口被别人抢先占了（sing-box
      // 只打 error 日志、Clash API 照样 200）。类型化后 UI 才能给出
      // 「换端口并重连」这个真正能解决的动作。
      throw await _portInUseError(_tail());
    }
    throw UnsupportedError(
        '内核启动超时（${_readyTimeout.inSeconds}s）。日志：${_tail()}$_winKernelHint');
  }

  /// 把内核的 bind 失败翻译成**可执行**的类型化错误。
  ///
  /// 端口号优先从内核日志里抠（`listen tcp 127.0.0.1:2080: bind: ...` 里那个
  /// 才是真正失败的端口），抠不到才退回本地代理端口；占用者再从系统里查，
  /// 于是提示能精确到「sing-box（PID 80160）」这种程度。
  Future<TypedConnError> _portInUseError(String log) async {
    final port = PortGuard.portFromLog(log) ?? _localPort;
    final what = port == _clashApiPort
        ? AppStrings.t('port_what_api')
        : AppStrings.t('port_what_local');
    final msg = await PortGuard.portInUseMessage(port, what: what);
    AppLog.error('[PORT] 内核启动失败（端口占用）：$msg');
    return TypedConnError(ConnErrorKind.portInUse, msg);
  }

  /// 本地端口探活：内核是否真的在 [port] 上监听。
  /// 比 Clash API 的 200 更接近「系统代理指向它能上网」这一实际语义。
  static Future<bool> _portListening(int port) async {
    if (port < 1 || port > 65535) return false;
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 800));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Windows 附加引导：内核进程启动即退出时给出排障方向。
  /// - 退出码 0xC0000005(访问违例)/0xC000001D(非法指令)：通常是 CPU 过老
  ///   跑不了新版内核(官方 amd64 按新指令集编译) —— 已默认改用官方
  ///   compatible 版,仍出现可到「设置 → 内核管理」手动更新为兼容内核;
  /// - 无任何日志输出且反复被终止：多为杀毒软件/Windows 安全中心拦截
  ///   sing-box.exe，请把 MBox 安装目录加入白名单
  String get _winKernelHint => Platform.isWindows
      ? '。提示：若退出码为 0xC0000005/0xC000001D 多为 CPU 过老与新版内核不兼容'
          '(可到设置→内核管理更新兼容内核)；若反复「无日志即退出」多为杀毒软件/'
          'Windows 安全中心拦截 sing-box.exe，请将 MBox 安装目录加入白名单'
      : '';

  @override
  Future<void> stop() async {
    _intentionalStop = true;
    _stopProxyKeepAlive();
    _trafficCancel?.cancel();
    final p = _proc;
    _proc = null;

    final killFut = () async {
      if (p == null) return;
      // 优先通过 Clash API 请求内核优雅退出（清理 TUN/虚拟网卡），
      // SIGTERM 在 Windows 上无效，直接 kill 会残留虚拟网卡。
      try {
        await _api.request('/shutdown',
            options: Options(method: 'POST', validateStatus: (_) => true,
                receiveTimeout: const Duration(milliseconds: 800)));
        await p.exitCode.timeout(const Duration(milliseconds: 1500));
        return;
      } catch (_) {}
      // API 退出失败：回退信号/强杀
      try {
        p.kill(ProcessSignal.sigterm);
        await p.exitCode.timeout(const Duration(milliseconds: 1500));
      } catch (_) {
        p.kill(ProcessSignal.sigkill);
      }
    }();
    final restoreFut =
        manageSystemProxy ? SystemProxyManager.restore() : Future.value();

    await Future.wait([killFut, restoreFut]);
    // sudo 启动时，杀掉 sudo 父进程不一定带走 root 内核：按工作目录兜底一次
    if (_launchedViaSudo && _kernelDir != null) {
      try {
        await Process.run('sudo', ['-n', 'pkill', '-f', _kernelDir!],
            stdoutEncoding: utf8, stderrEncoding: utf8);
      } catch (_) {}
      _launchedViaSudo = false;
    }
  }

  /// 启动系统代理保活：每 20s 检查一次，被关/被改走则立即重新指向本地端口
  bool _keepAliveInFlight = false;

  void _startProxyKeepAlive() {
    _stopProxyKeepAlive();
    _keepAliveInFlight = false;
    _proxyKeepAlive = Timer.periodic(_proxyKeepAliveInterval, (_) async {
      if (_keepAliveInFlight) return;
      if (_proc == null || _tunForceMode || !manageSystemProxy) return;
      _keepAliveInFlight = true;
      try {
        await SystemProxyManager.ensureApplied(port: _localPort);
      } catch (_) {
      } finally {
        _keepAliveInFlight = false;
      }
    });
  }

  void _stopProxyKeepAlive() {
    _proxyKeepAlive?.cancel();
    _proxyKeepAlive = null;
  }

  @override
  Future<void> switchMode(bool smart) async {
    _smartMode = smart;
    // sing-box: Rule=智能(规则分流) / Global=全局。
    // 配置里两套规则都用 clash_mode 前缀区分，PATCH /configs 热切换即可，
    // 内核不重启、不断网（实测 204）。
    await _clash('PATCH', '/configs', {'mode': smart ? 'Rule' : 'Global'});
  }

  @override
  Future<void> switchNode(String tag) async {
    // sing-box 没有内置 GLOBAL 组：两种模式的路由终点都是 select 选择器
    // （Global 模式由 `clash_mode: Global` 规则把流量指到 select）
    await _clash('PUT', '/proxies/select', {'name': tag});
  }

  @override
  Future<void> setKernelLogLevel(String level) async {
    // sing-box 的 Clash API 不支持热改日志级别（实测 PATCH /configs
    // {"log-level":...} 返回 204 但内核不生效），级别只能由启动配置决定。
    // 这里不去假装成功，而是往内核日志流里写一条明确提示，让用户知道
    // 「改了、但要重连才生效」。
    _onLog('[app] 日志级别已切换为 $level（sing-box 不支持热更，重新连接后生效）');
  }

  @override
  Future<int> testNodeDelay(String tag,
      {Duration timeout = const Duration(seconds: 5), String? url}) async {
    if (_proc == null) return -1;
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
      // 只有 200 + {'delay': <num>} 才算成功；超时/不可达 → -1（绝不给假数字）
      return parseKernelDelayResponse(r.statusCode, r.data);
    } catch (_) {
      return -1;
    }
  }

  Future<void> _clash(String method, String path, Object body) async {
    if (_proc == null) throw StateError('内核未运行');
    await _api.request(path,
        data: body,
        options: Options(
            method: method, validateStatus: (s) => s != null && s >= 200 && s < 300));
  }

  /// sing-box 的日志带 ANSI 颜色码（`\x1b[36mINFO\x1b[0m`），
  /// 直接展示/落盘会一堆转义字符，TUN 关键字匹配也会被切断。
  static final _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

  void _onLog(String rawLine) {
    final line = rawLine.replaceAll(_ansi, '');
    _logTail.add(line);
    if (_logTail.length > _logKeep) _logTail.removeAt(0);
    _lastCoreLogs.add(line);
    if (_lastCoreLogs.length > _coreLogKeep) _lastCoreLogs.removeAt(0);
    // 落盘：内存里的尾部会随进程/App 退出消失，而「内核为什么死」只能靠它查
    KernelLog.append(line);
    _trackTunLog(line);
    if (!kernelLogStream.isClosed) {
      kernelLogStream.add(line);
    }
  }

  /// TUN 失败**边收边判**：就绪时再回头扫 `_logTail` 会漏 —— 缓冲区只有 40 行
  /// 且日志级别可调成 debug，启动瞬间几十行 debug 足以把致命行挤出去（一旦漏判，
  /// force 模式就是「显示已连接、零流量、零报错」）。收到即判定，与缓冲区无关。
  void _trackTunLog(String line) {
    if (_tunFatalContext.isNotEmpty) {
      // 已在收集致命行之后的上下文（OS 错误常另起一行），最多留 8 行
      if (_tunFatalContext.length < 8) _tunFatalContext.add(line);
      return;
    }
    if (isFatalTunLine(line)) {
      _tunFatalContext.add(line);
    } else if (looksLikeTunTrouble([line])) {
      _tunSuspectSeen = true;
    }
  }

  String _tail() => _logTail.isEmpty ? '（无输出）' : _logTail.join(' | ');

  /// 进程退出监视：主动 stop 之外的退出 → 先留现场（崩溃快照），再通知控制器自愈
  Future<void> _watchProcess() async {
    final p = _proc;
    if (p == null) return;
    final code = await p.exitCode;
    if (_proc == p && !_intentionalStop) {
      _proc = null;
      _trafficCancel?.cancel();
      _lastError = '内核进程退出（code $code）：${_tail()}';
      AppLog.kernel('process exited unexpectedly, code=$code, log=${_tail()}');
      // 崩溃现场独立成文件：app_log 里那行会被 120 字截断 + 512KB 旋转滚掉，
      // 想定因（被安全软件杀 / OOM / 端口与锁冲突 / CPU 指令集不兼容）必须
      // 有完整尾部 + 退出码，且要活过 App 重启。
      unawaited(KernelLog.recordCrash(
        code: code,
        tail: List<String>.of(_lastCoreLogs),
        note: 'unexpected exit',
      ).then((path) {
        if (path != null) AppLog.kernel('crash dump saved: $path');
      }));
      _onUnexpectedExit?.call();
    }
  }

  /// 流量统计：Clash API 的 /traffic 是持续流（每秒推送一行
  /// {"up":Δ,"down":Δ}，单位字节/秒），流式解析直接换算 MB/s 回调。
  /// 断开/出错后重连流，直到内核停止。
  void _startStatsTimer() {
    _trafficCancel?.cancel();
    _trafficCancel = CancelToken();
    _trafficBuf.clear();
    // 流任务自管理生命周期（内核停止/取消令牌时退出），无需持有引用
    unawaited(_streamTraffic(_trafficCancel!));
  }

  Future<void> _streamTraffic(CancelToken cancel) async {
    while (_proc != null && !cancel.isCancelled) {
      try {
        final resp = await _api.get(
          '/traffic',
          cancelToken: cancel,
          options: Options(responseType: ResponseType.stream),
        );
        final stream = resp.data.stream as Stream<List<int>>;
        await for (final chunk in stream) {
          if (cancel.isCancelled || _proc == null) break;
          _trafficBuf.addAll(chunk);
          if (_trafficBuf.length > 64 * 1024) _trafficBuf.removeRange(0, _trafficBuf.length - 4096);
          // 按行解析 JSON（流式，跨 chunk 的行由缓冲区拼接）
          while (true) {
            final nl = _trafficBuf.indexOf(0x0A); // '\n'
            if (nl < 0) break;
            final line = utf8.decode(_trafficBuf.sublist(0, nl)).trim();
            _trafficBuf.removeRange(0, nl + 1);
            if (line.isEmpty) continue;
            try {
              final obj = jsonDecode(line);
              if (obj is Map && obj['up'] is num && obj['down'] is num) {
                // 值即每秒增量字节 → 直接换算 MB/s
                _onTraffic?.call(
                  (obj['up'] as num) / 1024 / 1024,
                  (obj['down'] as num) / 1024 / 1024,
                );
              }
            } catch (_) {
              // 忽略无法解析的行
            }
          }
        }
      } catch (_) {
        // 流中断：稍后重连（内核仍在运行则继续尝试）
      }
      if (_proc == null || cancel.isCancelled) break;
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  @override
  void dispose() {
    _trafficCancel?.cancel();
    _api.close(force: true);
    unawaited(stop());
  }
}
