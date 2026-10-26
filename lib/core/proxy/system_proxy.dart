import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/app_log.dart';
import '../services/settings_store.dart';

/// 系统代理管理器（macOS / Windows / Android）
///
/// 职责：连接 VPN 时把系统代理指向本地 sing-box mixed 端口，
/// 断开/退出时恢复原代理配置。参考 Hiddify：app 自己管理系统代理，
/// 不依赖内核自带的 set_system_proxy（实测内核进程被终止后
/// 不会恢复系统代理，导致残留）。
///
/// - macOS：`networksetup` 设置所有网络服务的 web/secure/socks 代理
/// - Windows：注册表 `HKCU\...\Internet Settings` 的 ProxyEnable/ProxyServer
/// - Android：不需要 —— VpnService + TUN 已接管全部流量（无系统代理概念）
///
/// 并发安全：apply / restore / ensureApplied 全部经过同一把互斥锁串行执行，
/// 避免「重连失败时的延迟 restore 与重连成功后的 apply 交错，
/// 导致内核已连接但系统代理被误关」的竞态（Windows 实测偶发）。
class SystemProxyManager {
  SystemProxyManager._();

  static const int defaultPort = 2080;

  // ---- 状态 ----
  static bool _applied = false;
  static int _port = defaultPort;

  /// 原始代理配置是否已捕获。仅在「本次连接的第一次 apply」时捕获一次；
  /// 之后的保活 reassert 不再覆盖 —— 否则会把我们自己写入（或被系统关到一半）
  /// 的状态误存为「原始值」，restore 时就还原不回用户真正的原始配置。
  static bool _captured = false;

  /// 原始代理配置（用于恢复）。macOS：service 名 → 原状态；Windows：原 Enable/Server
  static final Map<String, dynamic> _original = {};

  /// 互斥锁：所有系统代理写操作串行执行（消除 apply/restore 竞态）
  static Future<void> _mutex = Future.value();

  static bool get isApplied => _applied;

  static bool get _isMacOS =>
      !kIsWeb && (Platform.isMacOS);
  static bool get _isWindows =>
      !kIsWeb && (Platform.isWindows);

  static Future<void> _withLock(Future<void> Function() action) async {
    final prev = _mutex;
    final done = Completer<void>();
    _mutex = done.future;
    await prev;
    try {
      await action();
    } finally {
      done.complete();
    }
  }

  /// 设置系统代理指向本地端口（幂等；与 restore/ensureApplied 互斥串行）
  static Future<void> apply({int port = defaultPort}) async {
    await _withLock(() => _applyNow(port));
  }

  /// 恢复系统代理到原始状态（仅断开/退出时调用；互斥串行）
  static Future<void> restore() async {
    await _withLock(_restoreNow);
  }

  /// 巡检保活：连接期间周期调用。若系统代理已被外部/系统关闭或改走，
  /// 立即重新指向本地端口 —— 保持「只要 VPN 连着，系统代理就一直开着」，
  /// 直到真正断开连接或退出软件。
  /// 系统代理当前是否指向本机 [port]（启动巡检用：上次异常退出/强杀可能
  /// 残留代理指向死端口 → 无内核时会导致断网）
  static Future<bool> pointsToLocal(int port) async {
    try {
      // macOS：**直接枚举系统当前状态**，不依赖进程内 _original。
      // 启动巡检在新进程里跑（_original / _applied 都是空的）：
      //   · 用依赖 _original 的探针 → 空集合被当成「正常」→ 真残留清不掉 → 整机断网；
      //   · 无条件返回 true → 又会误关「别的代理软件指向 127.0.0.1:2080」的活配置。
      // 只有看真实系统状态，两个错都不会犯。
      if (_isMacOS) return await _macSystemProxyPointsTo(port);
      return await _osProxyPointsTo(port);
    } catch (_) {
      return false;
    }
  }

  /// macOS：枚举全部网络服务，看是否有任一服务的 web/secureweb/socks 代理
  /// 指向 `127.0.0.1:port`（我们的形状）。与进程内状态无关，供启动巡检使用。
  static Future<bool> _macSystemProxyPointsTo(int port) async {
    final services = await _macServices();
    var hit = false;
    await Future.wait([
      for (final svc in services)
        for (final kind in ['web', 'secureweb', 'socksfirewall'])
          Process.run('networksetup', ['-get${kind}proxy', svc]).then((r) {
            if (_isSelfResidual(r.stdout as String, port)) hit = true;
          }).catchError((_) {}),
    ]);
    return hit;
  }

  /// 启动巡检：清理「上次异常退出（强杀 / 注销 / 关机）残留」的系统代理。
  ///
  /// 与 [restore] 的本质区别：**不依赖进程内的 `_applied` / `_original`**。
  /// 新进程里两者恒为空，用它们做判断会导致「检测到残留却修不回来」——
  /// 旧实现就是如此：main.dart 先 pointsToLocal 再 restore()，而
  /// `_restoreNow` 首行 `if (!_applied) return;` 在新进程直接返回、什么都没做，
  /// 日志却打印「已恢复」。而残留的后果是整机断网（浏览器指向已死端口）。
  ///
  /// 这里改为**直接枚举系统当前状态**：凡指向本机残留端口的一律关掉。
  ///
  /// 「残留」的判据是**端口上还有没有进程在监听**（见 [shouldClearResidual]）：
  /// 旧实现只比对「系统代理是否指向本机端口」，于是在多开/双实例场景下会把
  /// **另一个实例正在使用的、活着的**系统代理当成残留清掉（2026-09-14
  /// `startup: cleared residual system proxy` 紧跟着内核被杀的那次故障），
  /// 用户表现为「显示已连接，但浏览器打不开网页」。
  /// 返回是否真的做了清理（供日志如实记录）。
  static Future<bool> clearResidual({required int port, bool force = false}) async {
    if (!_isMacOS && !_isWindows) return false;
    // 判据一：系统代理是否指向本机端口（不指向 → 与本次残留无关，直接返回）
    final pointsLocal = await pointsToLocal(port);
    // 判据二：该端口还有没有进程在监听（有 → 指向的是**活内核**，不是残留）
    final alive = await isLocalPortAlive(port);
    if (!shouldClearResidual(
        proxyPointsToLocal: pointsLocal, portAlive: alive, force: force)) {
      if (pointsLocal && alive) {
        AppLog.log('APP',
            'startup: system proxy points to a live port $port, keep it');
      }
      return false;
    }
    var fixed = false;
    try {
      fixed = _isWindows
          ? await _clearResidualWindows(port)
          : await _clearResidualMacOS(port);
    } catch (e) {
      AppLog.error('SystemProxyManager.clearResidual 失败: $e');
    }
    if (fixed) {
      // 残留已清 → 同步内存态，避免后续 keepalive 再把它拉起来
      _applied = false;
      _captured = false;
      _original.clear();
      AppLog.log('APP', 'startup: cleared residual system proxy (port $port)');
    }
    return fixed;
  }

  /// 残留清扫的决策（纯函数，便于单测）：只有「指向本机端口」**且**
  /// 「该端口已经没人监听」才算残留。[force] 跳过探活（调用方明确知道要清）。
  @visibleForTesting
  /// 保活是否需要重新 apply（纯函数，可单测）。
  ///
  /// macOS 的系统代理是**按网络服务**生效的，所以保活必须覆盖两件事：
  ///   · 还没捕获过任何服务 → 状态未知 → 需要 apply；
  ///   · 出现了未覆盖的**活跃**服务（换 Wi-Fi / 插网线 / 开热点 / 开热点共享）
  ///     → 需要 apply，否则新接口没有代理项。
  ///
  /// 旧实现两条都不查：`_original` 为空时探针直接返回 true（未知当正常），
  /// 新接入的服务也从不在 `_original` 里 → 探针恒说「正常」→ 客户看到
  /// 「首页已连接、速率为 0」，甚至以本机 IP 直连出网（以为走了代理）。
  static bool macProxyNeedsApply({
    required Set<String> captured,
    required List<String> activeServices,
  }) {
    if (captured.isEmpty) return true;
    for (final svc in activeServices) {
      if (!captured.contains(svc)) return true;
    }
    return false;
  }

  static bool shouldClearResidual({
    required bool proxyPointsToLocal,
    required bool portAlive,
    bool force = false,
  }) {
    if (!proxyPointsToLocal) return false;
    if (force) return true;
    return !portAlive;
  }

  /// 本机 [port] 是否有进程在监听（残留 vs 活内核的唯一判据）。
  /// 只做一次 TCP 连接尝试，超时 300ms —— 启动路径上不能拖慢启动，
  /// 而本机回环连接要么立刻成功要么立刻被拒。
  static Future<bool> isLocalPortAlive(int port,
      {Duration timeout = const Duration(milliseconds: 300)}) async {
    if (kIsWeb) return false;
    Socket? s;
    try {
      s = await Socket.connect('127.0.0.1', port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        s?.destroy();
      } catch (_) {}
    }
  }

  /// Windows 残留清扫：ProxyEnable=1 且 ProxyServer 指向本机端口 → 关掉并清值。
  ///
  /// 不尝试「还原用户原值」：原值存在已死亡的进程内存里，无法得知；
  /// 而把 ProxyEnable 置 0 + 删除我们写入的 ProxyServer/ProxyOverride
  /// 等于回到系统默认（不使用代理），是唯一可确定安全的修复。
  static Future<bool> _clearResidualWindows(int port) async {
    final enable = await Process.run(
        'reg', ['query', _winReg, '/v', 'ProxyEnable'], runInShell: true);
    if (enable.exitCode != 0 || !(enable.stdout as String).contains('0x1')) {
      return false;
    }
    final server = await Process.run(
        'reg', ['query', _winReg, '/v', 'ProxyServer'], runInShell: true);
    if (server.exitCode != 0) return false;
    final line = (server.stdout as String)
        .split('\n')
        .firstWhere((l) => l.contains('ProxyServer'), orElse: () => '');
    if (!line.contains('127.0.0.1:$port')) return false;
    await Future.wait([
      Process.run('reg',
          ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0',
              '/f'],
          runInShell: true),
      Process.run('reg', ['delete', _winReg, '/v', 'ProxyServer', '/f'],
          runInShell: true),
      Process.run('reg', ['delete', _winReg, '/v', 'ProxyOverride', '/f'],
          runInShell: true),
    ]);
    await _notifyWinInetChanged();
    return true;
  }

  /// macOS 残留清扫：枚举**全部**网络服务（不能只查 `_original.keys`——
  /// 新进程里它是空的），凡 web/secureweb/socks 里存在「Enabled 且指向
  /// 127.0.0.1:port」的就关掉。读操作并行、写操作串行（networksetup 写走
  /// 系统配置数据库全局锁，并发会丢写）。
  static Future<bool> _clearResidualMacOS(int port) async {
    final services = await _macServices();
    if (services.isEmpty) return false;
    const kinds = ['web', 'secureweb', 'socksfirewall'];
    final hits = <({String svc, String kind})>[];
    await Future.wait([
      for (final svc in services)
        for (final kind in kinds)
          Process.run('networksetup', ['-get${kind}proxy', svc]).then((r) {
            if (r.exitCode != 0) return;
            if (_isSelfResidual((r.stdout as String).trim(), port)) {
              hits.add((svc: svc, kind: kind));
            }
          }).catchError((_) {}),
    ]);
    if (hits.isEmpty) return false;
    for (final h in hits) {
      await Process.run(
          'networksetup', ['-set${h.kind}proxystate', h.svc, 'off']);
      AppLog.log('APP', 'clear residual: ${h.svc}/${h.kind} -> off');
    }
    return true;
  }

  static Future<void> ensureApplied({int port = defaultPort}) async {
    await _withLock(() async {
      if (!_applied || _port != port) {
        // 首次应用，或端口变了：按（新）端口应用
        await _applyNow(port);
        return;
      }
      final ok = await _osProxyPointsTo(port);
      if (!ok) {
        // 被系统/外部关掉或改走 → 强制重新打开（reassert）。
        // 注意必须 force：此时 _applied 仍为 true、端口未变，
        // 普通 _applyNow 的幂等判断会直接 return，导致「检测到掉了却修不回」。
        await _applyNow(port, reassert: true);
      }
    });
  }

  /// 实际执行「指向本地端口」（调用方需已持有互斥锁）。
  /// [reassert]=true 表示保活巡检发现代理被外部关掉后的强制重写，
  /// 跳过幂等判断、且不重新捕获原始配置。
  static Future<void> _applyNow(int port, {bool reassert = false}) async {
    if (!reassert && _applied && _port == port) return;
    _port = port;
    // 绕过列表随设置动态构造（回环 + 内网 + 用户直连名单），
    // 传入各平台的写入实现
    final bypass = await _bypassFromSettings();
    try {
      if (_isMacOS) {
        await _applyMacOS(port, bypass);
      } else if (_isWindows) {
        await _applyWindows(port, bypass);
        await _notifyWinInetChanged();
      }
      // Android：TUN 接管流量，无需系统代理
      _applied = true;
    } catch (e) {
      AppLog.error('SystemProxyManager.apply 失败: $e');
    }
  }

  /// 平台无关的「绕过列表」构造：本机回环 + （可选）内网段 + 用户直连名单。
  ///
  /// 旧实现 Windows 只写一个 `<local>`、macOS **完全不设** bypass domains，
  /// 于是 localhost / 局域网 / 本地控制端口都可能被塞进代理（内核没起来时
  /// 连本机服务都访问不了）。
  static List<String> _buildBypass(List<String> userDomains, bool bypassLan) {
    final out = <String>['127.0.0.1', 'localhost', '::1'];
    if (bypassLan) {
      out.addAll(const [
        '10.*', '172.16.*', '172.17.*', '172.18.*', '172.19.*', '172.20.*',
        '172.21.*', '172.22.*', '172.23.*', '172.24.*', '172.25.*', '172.26.*',
        '172.27.*', '172.28.*', '172.29.*', '172.30.*', '172.31.*',
        '192.168.*', '*.local',
      ]);
    }
    for (final raw in userDomains) {
      var v = raw.trim();
      if (v.isEmpty) continue;
      // bypassDomains 里带内核规则前缀，系统代理不认识，剥掉再用
      if (v.startsWith('IP-CIDR:')) {
        v = v.substring('IP-CIDR:'.length).trim();
      } else if (v.startsWith('DOMAIN:')) {
        v = v.substring('DOMAIN:'.length).trim();
      }
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }
    return out;
  }

  static Future<List<String>> _bypassFromSettings() async {
    try {
      final s = await SettingsStore.instance.load();
      return _buildBypass(
        (s['bypassDomains'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        s['bypassLan'] != false,
      );
    } catch (_) {
      return _buildBypass(const [], true);
    }
  }

  /// 实际执行「恢复原始状态」（调用方需已持有互斥锁）
  static Future<void> _restoreNow() async {
    if (!_applied) return;
    try {
      if (_isMacOS) {
        await _restoreMacOS();
      } else if (_isWindows) {
        await _restoreWindows();
        await _notifyWinInetChanged();
      }
      _applied = false;
      _captured = false; // 下次连接重新捕获原始配置
      _original.clear();
    } catch (e) {
      AppLog.error('SystemProxyManager.restore 失败: $e');
    }
  }

  /// 只读探测：当前系统代理是否仍指向本地端口（无副作用）
  static Future<bool> _osProxyPointsTo(int port) async {
    if (_isWindows) return _winProxyPointsTo(port);
    if (_isMacOS) return _macProxyPointsTo(port);
    return true; // Android 等无系统代理概念
  }

  // ---------------- 保活探测 ----------------

  /// Windows 残留检测：ProxyEnable=1 且 ProxyServer 指向我们自己的端口
  /// （上次未正常 restore 的残留）。用 reg query 的原始输出文本判断。
  static bool _winStateIsSelfResidual(
      String? enableOut, String? serverOut, int port) {
    if (enableOut == null || serverOut == null) return false;
    if (!enableOut.contains('0x1')) return false;
    final line = serverOut
        .split('\n')
        .firstWhere((l) => l.contains('ProxyServer'), orElse: () => '');
    return line.contains('127.0.0.1:$port');
  }

  static Future<bool> _winProxyPointsTo(int port) async {
    try {
      final enable = await Process.run(
          'reg', ['query', _winReg, '/v', 'ProxyEnable'], runInShell: true);
      if (enable.exitCode != 0 || !(enable.stdout as String).contains('0x1')) {
        return false;
      }
      final server = await Process.run(
          'reg', ['query', _winReg, '/v', 'ProxyServer'], runInShell: true);
      if (server.exitCode != 0) return false;
      final line = (server.stdout as String)
          .split('\n')
          .firstWhere((l) => l.contains('ProxyServer'), orElse: () => '');
      return line.contains('127.0.0.1:$port');
    } catch (_) {
      return false;
    }
  }

  /// 只读探测：apply 时设置过的活跃服务（_original.keys）三种代理是否都仍
  /// 指向本地端口。只查我们真正设过的少数服务，全并行（~0.1s）。
  static Future<bool> _macProxyPointsTo(int port) async {
    final services = _original.keys.toSet();
    // 「未知」不等于「正常」：还没捕获过任何服务时返回 false，
    // 让保活走 reassert 重新 apply（旧实现返回 true → 探针永远说正常 → 修不回来）。
    if (services.isEmpty) return false;
    // 出现未覆盖的**活跃**服务（换 Wi-Fi / 插网线 / 开热点）→ 同样视为「不 OK」，
    // 由保活补写代理（判据抽成纯函数，见 macProxyNeedsApply 的单测）。
    final active = await _macActiveServices();
    if (macProxyNeedsApply(captured: services, activeServices: active)) {
      return false;
    }
    try {
      final results = await Future.wait([
        for (final svc in services)
          for (final kind in ['web', 'secureweb', 'socksfirewall'])
            Process.run('networksetup', ['-get${kind}proxy', svc]).then(
                (r) => _macEntryEnabledToPort((r.stdout as String).trim(), port)),
      ]);
      return results.every((ok) => ok);
    } catch (_) {
      return false;
    }
  }

  /// macOS 单条代理状态：Enabled: Yes 且 127.0.0.1:port
  static bool _macEntryEnabledToPort(String state, int port) {
    if (!state.contains('Enabled: Yes')) return false;
    final server = _extractMacValue(state, 'Server:');
    final p = _extractMacValue(state, 'Port:');
    return server == '127.0.0.1' && p == '$port';
  }

  // ---------------- macOS ----------------
  static Future<List<String>> _macServices() async {
    final r = await Process.run('networksetup', ['-listallnetworkservices']);
    if (r.exitCode != 0) return const [];
    return (r.stdout as String)
        .split('\n')
        .map((s) => s.trim())
        .where((s) =>
            s.isNotEmpty &&
            !s.startsWith('*') && // 禁用服务
            !s.contains('denotes')) // 说明行
        .toList();
  }

  /// 仅返回「有 IP 地址的活跃网络服务」（通常 1~2 个）。
  /// 关键优化：用户机器常残留大量其他 VPN 的僵尸虚拟网卡（无流量），
  /// 而 macOS `networksetup -set` 走系统配置数据库全局写锁、并发无法真正并行 ——
  /// 对全部 20+ 服务串行 set 会让连接/断开卡 2~3s。只设活跃服务把 set 次数
  /// 从 60+ 降到 ~6，连接/断开各降到 <0.5s。getinfo 是只读、并行无锁竞争。
  static Future<List<String>> _macActiveServices() async {
    final all = await _macServices();
    final active = <String>[];
    await Future.wait([
      for (final svc in all)
        Process.run('networksetup', ['-getinfo', svc]).then((r) {
          final ip = _extractMacValue(r.stdout as String, 'IP address:');
          if (ip != null &&
              ip.isNotEmpty &&
              ip != 'none' &&
              !ip.startsWith('0.0.0.0')) {
            active.add(svc);
          }
        }).catchError((_) {}),
    ]);
    // 一个活跃服务都没找到（异常网络态）→ 回退全部，保证代理仍然生效
    return active.isEmpty ? all : active;
  }

  /// 判断某网络服务的代理是否指向「我们自己设置的端口」（残留检测）。
  /// 若残留（上次崩溃/强杀未恢复），记录原状态时视为「关闭」，
  /// restore 时恢复为关闭而非还原残留，避免代理永远清不掉。
  static bool _isSelfResidual(String state, int port) {
    final server = _extractMacValue(state, 'Server:');
    final p = _extractMacValue(state, 'Port:');
    return state.contains('Enabled: Yes') &&
        server == '127.0.0.1' &&
        p == '$port';
  }

  /// macOS apply：跨「网络服务 × 代理类型」全部并行执行。
  /// 用户机器上常有大量残留虚拟网卡（其他 VPN 软件遗留），串行 networksetup
  /// 会让连接卡 2~3s；并行后降到 ~0.3s。每个 networksetup 调用相互独立，
  /// 并行无副作用。
  /// 捕获若干 macOS 网络服务的「原始代理状态」（restore 时按此还原）。
  /// 已捕获过的服务不覆盖：保活 reassert 时不能把「我们自己写入的状态」当成原值。
  static Future<void> _captureMacOriginals(
      List<String> services, int port) async {
    await Future.wait([
      for (final svc in services)
        for (final kind in ['web', 'secureweb', 'socksfirewall'])
          Process.run('networksetup', ['-get${kind}proxy', svc]).then((r) {
            var state = (r.stdout as String).trim();
            // 上次强杀留下的「指向本机端口」的残留，记录为「关闭」，
            // restore 时恢复成关闭而不是把残留还原回来。
            if (_isSelfResidual(state, port)) state = 'Enabled: No';
            (_original[svc] ??= <String, String>{})[kind] = state;
          }).catchError((_) {}),
      // bypass domains 原值（restore 时还原）。旧实现从不设置该值、也没捕获 ——
      // 结果是 localhost / 内网 / 本地控制端口全被塞进代理，内核没起来时连本机
      // 服务都访问不了。
      for (final svc in services)
        Process.run('networksetup', ['-getproxybypassdomains', svc])
            .then((r) {
          (_original[svc] ??= <String, String>{})['bypass'] =
              (r.stdout as String).trim();
        }).catchError((_) {}),
    ]);
  }

  static Future<void> _applyMacOS(int port, List<String> bypass) async {
    // 1) **每次 apply 都重新枚举活跃服务**（不只首次）。
    //    换 Wi-Fi / 插网线 / 开热点后 macOS 会启用另一个网络服务，而系统代理是
    //    **按服务**生效的：旧实现只在首次捕获一次、之后永远只写 _original.keys，
    //    新服务拿不到代理 → 客户看到「首页显示已连接、速率为 0」，甚至以本机 IP
    //    直连出网（以为自己走了代理）。新出现的服务在这里补捕获原状态，
    //    restore 才能把它正确还原。
    final active = await _macActiveServices();
    final toCapture = _captured
        ? active.where((s) => !_original.containsKey(s)).toList()
        : active;
    if (toCapture.isNotEmpty) {
      await _captureMacOriginals(toCapture, port);
      _captured = true;
    }
    // 2) 设置代理 on + 127.0.0.1:port。
    //    注意：networksetup -set 走系统配置数据库全局写锁，并发 set 会互相
    //    竞争、偶发丢写，故写操作串行执行。因只对活跃服务（通常 1~2 个、
    //    共 3~6 次），串行也仅 ~0.4s，可靠优先。
    final services = _original.keys.toList();
    for (final svc in services) {
      for (final kind in ['web', 'secureweb', 'socksfirewall']) {
        await Process.run(
            'networksetup', ['-set${kind}proxy', svc, '127.0.0.1', '$port']);
      }
      if (bypass.isNotEmpty) {
        await Process.run(
            'networksetup', ['-setproxybypassdomains', svc, ...bypass]);
      }
    }
  }

  /// macOS restore：只恢复「apply 时真正设置过的活跃服务」（_original.keys）。
  /// 写操作串行（避免 networksetup 系统配置数据库写锁竞争丢写）；
  /// 因只涉及少数活跃服务，断开仍 <0.5s。
  static Future<void> _restoreMacOS() async {
    final services = _original.keys.toList();
    for (final svc in services) {
      for (final kind in ['web', 'secureweb', 'socksfirewall']) {
        await _restoreMacOneEntry(svc, kind);
      }
      await _restoreMacBypass(svc);
    }
    _original.clear();
  }

  /// 还原 bypass domains：原值为空（本来就没设）时用 `Empty` 清空
  static Future<void> _restoreMacBypass(String svc) async {
    final orig = _original[svc] as Map<String, String>?;
    final prev = (orig?['bypass'] ?? '').trim();
    final empty = prev.isEmpty || prev.contains("aren't any bypass domains");
    await Process.run('networksetup', [
      '-setproxybypassdomains',
      svc,
      if (empty)
        'Empty'
      else
        ...prev
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty),
    ]);
  }

  /// 恢复单条 macOS 代理（service × kind）到原始状态
  static Future<void> _restoreMacOneEntry(String svc, String kind) async {
    final orig = _original[svc] as Map<String, String>?;
    final prev = orig?[kind] ?? '';
    final enabled = prev.contains('Enabled: Yes');
    final host = _extractMacValue(prev, 'Server:');
    final port = _extractMacValue(prev, 'Port:');
    if (enabled && host != null && port != null) {
      await Process.run('networksetup', ['-set${kind}proxy', svc, host, port]);
    } else {
      await Process.run('networksetup', ['-set${kind}proxystate', svc, 'off']);
    }
  }

  static String? _extractMacValue(String text, String key) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.startsWith(key)) {
        return t.substring(key.length).trim();
      }
    }
    return null;
  }

  // ---------------- Windows ----------------
  static const _winReg =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static Future<void> _applyWindows(int port, List<String> bypass) async {
    // 保存原值（仅首次捕获；保活 reassert 时不再覆盖，避免把「我们自己写入的
    // 值」或「被系统关到一半的值」误存为原始配置）。两次 query 并行。
    if (!_captured) {
      final results = await Future.wait([
        Process.run('reg', ['query', _winReg, '/v', 'ProxyEnable'],
            runInShell: true),
        Process.run('reg', ['query', _winReg, '/v', 'ProxyServer'],
            runInShell: true),
        Process.run('reg', ['query', _winReg, '/v', 'ProxyOverride'],
            runInShell: true),
      ]);
      final enableOut =
          results[0].exitCode == 0 ? (results[0].stdout as String) : null;
      final serverOut =
          results[1].exitCode == 0 ? (results[1].stdout as String) : null;
      final overrideOut =
          results[2].exitCode == 0 ? (results[2].stdout as String) : null;
      // 残留检测：上次崩溃/被强杀，代理仍指向我们自己的端口 →
      // 视为「原本关闭」，restore 时关掉而非还原到死端口（否则系统流量永久中断）。
      if (_winStateIsSelfResidual(enableOut, serverOut, port)) {
        _original['ProxyEnable'] = null;
        _original['ProxyServer'] = null;
      } else {
        _original['ProxyEnable'] = enableOut;
        _original['ProxyServer'] = serverOut;
      }
      // ProxyOverride 也需记录：restore 时有原值则还原、无原值则删除我们写入的
      // <local>，否则会残留（真机验证发现：原本未设代理的机器断开后有残留）。
      _original['ProxyOverride'] = overrideOut;
      _captured = true;
    }

    // 写不同注册表值互不冲突，可并行（注册表有细粒度锁，无 macOS 那种全局写锁）
    // ProxyOverride 用 Windows 规定的 **分号** 分隔（不是逗号），并包含
    // <local>（无点号主机名）+ 回环 + 内网 + 用户直连名单。
    final override = ['<local>', ...bypass].join(';');
    await Future.wait([
      Process.run('reg',
          ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1',
              '/f'],
          runInShell: true),
      Process.run('reg',
          ['add', _winReg, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d',
              '127.0.0.1:$port', '/f'],
          runInShell: true),
      Process.run('reg',
          ['add', _winReg, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d',
              override, '/f'],
          runInShell: true),
    ]);
  }

  static Future<void> _restoreWindows() async {
    // ProxyEnable：总是有意义（0/1），还原原值或置 0
    final enable = _original['ProxyEnable'] as String?;
    if (enable != null && enable.contains('ProxyEnable')) {
      await Process.run('reg', ['add', _winReg, '/v', 'ProxyEnable', '/t',
          'REG_DWORD', '/d', enable.contains('0x1') ? '1' : '0', '/f'],
          runInShell: true);
    } else {
      await Process.run('reg',
          ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0',
              '/f'],
          runInShell: true);
    }
    // ProxyServer / ProxyOverride：原本有值则还原；原本不存在则删除我们写入的
    // 值（关键：否则原本未配代理的机器会残留 127.0.0.1:2080 / <local>）。
    await _restoreWinValueOrDelete('ProxyServer');
    await _restoreWinValueOrDelete('ProxyOverride');
  }

  /// 还原单个 Windows 注册表字符串值到原始状态：
  /// _original 里存有原 reg query 输出（含该值名）→ 解析末段还原；
  /// 否则（原本不存在）→ reg delete 清除我们写入的值，避免残留。
  static Future<void> _restoreWinValueOrDelete(String name) async {
    final raw = _original[name] as String?;
    if (raw != null && raw.contains(name)) {
      final value = _extractRegValue(raw, name);
      if (value != null) {
        await Process.run('reg', ['add', _winReg, '/v', name, '/t', 'REG_SZ',
            '/d', value, '/f'], runInShell: true);
        return;
      }
    }
    // 原本无此值 → 删除（忽略「值不存在」的报错）
    await Process.run('reg', ['delete', _winReg, '/v', name, '/f'],
        runInShell: true);
  }

  /// 从 `reg query` 输出里提取值文本。
  /// 注意不能按空白 split 取末段：ProxyOverride 的值本身可能含空格
  /// （用户手填过 `localhost; 127.0.0.1`），旧实现会把值截断成尾部一小截，
  /// 还原后用户的绕过列表就被破坏。
  static String? _extractRegValue(String raw, String name) {
    for (final line in raw.split('\n')) {
      final i = line.indexOf(name);
      if (i < 0) continue;
      final rest = line.substring(i + name.length);
      final m = RegExp(r'\s+REG_[A-Z_]+\s+(.*)$').firstMatch(rest);
      if (m != null) return m.group(1)!.trim();
    }
    return null;
  }

  /// 让浏览器/系统立即感知代理注册表变化（仅 Windows；reg.exe 写注册表
  /// 不会自动通知 WinINET）。
  ///
  /// 旧实现每次都启动 PowerShell（冷启动 0.5~1s），连接/断开各吃一次，是
  /// Windows 端「连接慢、断开慢」的主因之一。改为 dart:ffi 直接调 wininet
  /// 的 InternetSetOption（INTERNET_OPTION_SETTINGS_CHANGED + REFRESH）——
  /// 无进程启动，微秒级返回，且是 WinINET 官方刷新方式。
  static Future<void> _notifyWinInetChanged() async {
    if (!_isWindows) return;
    // 优先 FFI（快）；任何失败都回退到 PowerShell（慢但已验证可靠）。
    // 代理注册表值此时已写入，通知只是让浏览器「立即」感知，回退不影响正确性。
    if (_notifyWinInetViaFfi()) return;
    await _notifyWinInetViaPowerShell();
  }

  /// FFI 直调 wininet InternetSetOption。成功返回 true；抛异常或调用失败返回
  /// false（交由调用方回退）。
  static bool _notifyWinInetViaFfi() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final internetSetOption = wininet.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)>('InternetSetOptionW');
      const internetOptionSettingsChanged = 39;
      const internetOptionRefresh = 37;
      // hInternet=0（全局）、无缓冲区：通知「设置已变」+「立即刷新」。
      // 返回非 0 为成功；任一步失败即视为整体失败，回退 PowerShell。
      final r1 = internetSetOption(0, internetOptionSettingsChanged, nullptr, 0);
      final r2 = internetSetOption(0, internetOptionRefresh, nullptr, 0);
      return r1 != 0 && r2 != 0;
    } catch (e) {
      AppLog.error('SystemProxyManager FFI 通知失败，回退 PowerShell: $e');
      return false;
    }
  }

  /// 回退方案：PowerShell 广播 WM_SETTINGCHANGE（旧实现，慢但可靠）
  static Future<void> _notifyWinInetViaPowerShell() async {
    try {
      final script = r'''
Add-Type -MemberDefinition '[DllImport("user32.dll", SetLastError = true)] public static extern bool SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);' -Name P -Namespace W32
$r = [UIntPtr]::Zero
[void][W32.P]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, "InternetSettings", 2, 1000, [ref]$r)
''';
      final ps1 = File('${Directory.systemTemp.path}/mbox_proxy_notify.ps1');
      await ps1.writeAsString(script, flush: true);
      await Process.run('powershell', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ps1.path,
      ], runInShell: true);
    } catch (e) {
      AppLog.error('SystemProxyManager PowerShell 通知失败: $e');
    }
  }
}
