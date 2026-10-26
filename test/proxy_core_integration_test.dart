@Tags(['e2e'])
library;

// 集成测试：真实启动 sing-box 内核，验证「点连接就能用」的核心链路。
//
// 运行条件（任一生效即可）：
//   1) 环境变量 MBOX_SINGBOX 指向 sing-box 可执行文件
//   2) 仓库自带开发内核 .core_dl/sing-box-<ver>-<os>-<arch>/sing-box（tool/fetch_singbox.sh 落地）
//   3) 仓库 build/sing-box/sing-box，或 PATH 里有 sing-box
// 不满足条件时自动跳过（CI 上桌面端不装内核二进制，避免误报失败）。
//
// 注意：本测试用 tunMode='off' 且关闭系统代理管理（manageSystemProxy=false），
// 不会改动系统代理/虚拟网卡。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/singbox_config.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';
import 'package:mbox/core/services/local_paths.dart';

/// 定位本地 sing-box 内核（MBOX_SINGBOX / 仓库自带 .core_dl /
/// build/sing-box / PATH）。
String? _findBinary() {
  final injected = Platform.environment['MBOX_SINGBOX'];
  if (injected != null &&
      injected.isNotEmpty &&
      File(injected).existsSync()) {
    return injected;
  }
  final exe = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  final candidates = <String>[];
  for (final dir in [
    '${Directory.current.path}/.core_dl',
    '${Directory.current.path}/sing-box-bin',
    '${Directory.current.path}/build/sing-box',
  ]) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    candidates.add('$dir/$exe');
    for (final sub in d.listSync().whereType<Directory>()) {
      candidates.add('${sub.path}/$exe');
    }
  }
  candidates.sort((a, b) {
    final am = a.contains(Platform.operatingSystem) ? 0 : 1;
    final bm = b.contains(Platform.operatingSystem) ? 0 : 1;
    return am != bm ? am - bm : a.compareTo(b);
  });
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  try {
    final r = Process.runSync('which', [exe],
        environment: {'PATH': Platform.environment['PATH'] ?? ''});
    final out = '${r.stdout}'.trim();
    if (r.exitCode == 0 && out.isNotEmpty && File(out).existsSync()) return out;
  } catch (_) {}
  return null;
}

final binary = _findBinary();

/// 把内核挂到 [ProxyCoreCli.resolveKernelBinary] 会去找的位置。
///
/// 该函数按「测试注入 → supportDir/kernel/sing-box（桌面端内置内核文件名）→
/// 可执行文件同目录」查找；flutter test 里没有 path_provider 平台实现，
/// 所以用 [LocalPaths.debugSupportDir]（官方测试注入点）把 support 目录指向
/// 临时目录，再在 `<support>/kernel/sing-box` 放内核（符号链接，失败则复制）。
void _installKernel(String bin) {
  final support = Directory.systemTemp.createTempSync('mf_kernel_');
  Directory('${support.path}/kernel').createSync(recursive: true);
  final target =
      '${support.path}/kernel/${Platform.isWindows ? 'sing-box.exe' : 'sing-box'}';
  try {
    Link(target).createSync(bin);
  } catch (_) {
    // Windows 无开发者模式建不了符号链接 → 退回复制
    File(bin).copySync(target);
  }
  LocalPaths.debugSupportDir = () async => support;
}

/// 串行化「独占内核工作目录 + 固定端口」的端到端用例。
///
/// `flutter test` 默认按文件并发跑，而内核工作目录是进程内静态的
/// `${tmp}/mbox_core`（[ProxyCoreCli.workDir]）——两个 e2e 文件同时起内核
/// 会互相覆盖 config.json、抢 2080/9090（dart_test.yaml 要求 e2e 串行，
/// 但验收命令不带 --concurrency=1）。用跨进程文件锁把「起内核 → 停内核」
/// 这一段串起来，谁先拿到锁谁先跑完整轮。
Future<T> _withKernelLock<T>(Future<T> Function() body) async {
  final raf = await File('${Directory.systemTemp.path}/mbox_core.e2e.lock')
      .open(mode: FileMode.write);
  try {
    await raf.lock(FileLock.blockingExclusive);
    return await body();
  } finally {
    try {
      await raf.unlock();
    } catch (_) {}
    await raf.close();
  }
}

ProxyNode _fakeNode() => ProxyNode(
      tag: '测试节点',
      type: 'vless',
      server: '127.0.0.1',
      port: 9, // 假地址：内核可启动，outbound 无需真实连通
      uuid: '00000000-0000-0000-0000-000000000000',
      countryCode: 'HK',
      raw: const {},
    );

/// 仓库内置的离线规则集目录（geosite-cn.srs / geoip-cn.srs）
String get _ruleSetDir => '${Directory.current.path}/assets/rules';

/// 配置生成用例的入参（不启动内核，端口用默认值，断言「产物长什么样」）
Map<String, dynamic> _buildConfig({
  bool smartMode = true,
  bool bypassLan = true,
  String? ruleSetDir,
  String tunMode = 'off',
}) =>
    SingBoxConfigBuilder.build(
      nodes: [_fakeNode()],
      selectedTag: '测试节点',
      smartMode: smartMode,
      tunMode: tunMode,
      bypassLan: bypassLan,
      ruleSetDir: ruleSetDir,
    );

/// 端到端用例的入参：端口避开默认 2080/9090，避免撞本机正在跑的 App 实例
Map<String, dynamic> _safeConfig() {
  // 测试期间 app 不管理系统代理，避免改动真实系统代理
  ProxyCoreCli.manageSystemProxy = false;
  return SingBoxConfigBuilder.build(
    nodes: [_fakeNode()],
    selectedTag: '测试节点',
    smartMode: true,
    tunMode: 'off', // 集成测试不创建虚拟网卡（需 root）
    localPort: 21880,
    clashApiPort: 29809,
    ruleSetDir: _ruleSetDir,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认用 mock HttpClient 拦截一切 HTTP（返回 400）；
  // 本集成测试需要真实访问内核 Clash API，复位为系统实现
  HttpOverrides.global = null;

  final skip = binary == null
      ? '未找到 sing-box 内核（tool/fetch_singbox.sh 获取后本地验证）'
      : null;

  test('配置生成：sing-box JSON 基础结构（入站 / Clash API / 规则集 / 选择器）',
      skip: skip, () {
    final cfg = _buildConfig(ruleSetDir: _ruleSetDir);

    // 入站：本机 mixed（HTTP+SOCKS 同端口，系统代理指向它）；tunMode=off 无 TUN
    final inbounds = (cfg['inbounds'] as List).cast<Map<String, dynamic>>();
    final mixed = inbounds.firstWhere((i) => i['type'] == 'mixed');
    expect(mixed['tag'], 'mixed-in');
    expect(mixed['listen'], '127.0.0.1');
    expect(mixed['listen_port'], 2080, reason: 'system proxy 指向的本地端口');
    expect(inbounds.any((i) => i['type'] == 'tun'), isFalse);

    // Clash API：切模式（Rule/Global）、切节点、流量统计都走它
    final clashApi = (cfg['experimental'] as Map)['clash_api'] as Map;
    expect(clashApi['external_controller'], '127.0.0.1:9090');
    expect(clashApi['default_mode'], 'Rule', reason: '智能模式');
    expect('${clashApi['secret']}'.isNotEmpty, isTrue);
    expect(clashApi['secret'], cfg['_clashApiSecret']);
    // 缓存不落盘（移动端容器空间有限）
    expect((cfg['experimental'] as Map)['cache_file'], {'enabled': false});

    // 智能分流：离线 .srs 规则集（替代旧内核的 GEOSITE/GEOIP 字段）
    final route = cfg['route'] as Map;
    final ruleSets = (route['rule_set'] as List).cast<Map>();
    expect(ruleSets.map((r) => r['tag']), containsAll(['geosite-cn', 'geoip-cn']));
    expect(ruleSets.every((r) => r['format'] == 'binary'), isTrue);
    expect(ruleSets.every((r) => '${r['path']}'.endsWith('.srs')), isTrue);
    final rules = (route['rules'] as List).cast<Map>();
    bool hasRuleSet(String tag) =>
        rules.any((r) => (r['rule_set'] as List?)?.contains(tag) ?? false);
    expect(hasRuleSet('geosite-cn'), isTrue);
    expect(hasRuleSet('geoip-cn'), isTrue);
    // 国内分流是「直连」，兜底是 select（代理）
    for (final tag in ['geosite-cn', 'geoip-cn']) {
      final r = rules.firstWhere((r) => (r['rule_set'] as List?)?.contains(tag) ?? false);
      expect(r['outbound'], 'direct');
      expect(r['clash_mode'], 'Rule');
    }
    expect(route['final'], 'select', reason: '未命中的流量走代理');
    expect(route['default_domain_resolver'], {'server': 'dns-main'});

    // 出站：selector 默认选中节点排首位（重启后线路不丢）
    final outbounds = (cfg['outbounds'] as List).cast<Map>();
    final select = outbounds.firstWhere((o) => o['type'] == 'selector');
    expect(select['tag'], 'select');
    expect(select['default'], '测试节点');
    expect(select['outbounds'], ['测试节点', 'direct']);
    expect(outbounds.any((o) => o['tag'] == 'direct' && o['type'] == 'direct'), isTrue);
    expect(outbounds.any((o) => o['tag'] == 'block' && o['type'] == 'block'), isTrue);

    // 元数据：ProxyCore 读取后剥离，不写进配置文件
    expect(cfg['_localPort'], 2080);
    expect(cfg['_clashApiPort'], 9090);
    expect(cfg['_tunMode'], 'off');
  });

  test('配置生成：tunMode off → 无 tun 入站；bypassLan false → 内网段不放行',
      skip: skip, () {
    final cfgOff = _buildConfig();
    final inbounds = (cfgOff['inbounds'] as List).cast<Map>();
    expect(inbounds.any((i) => i['type'] == 'tun'), isFalse);

    List<Map> ipRules(Map<String, dynamic> cfg) =>
        ((cfg['route'] as Map)['rules'] as List)
            .cast<Map>()
            .where((r) => r['ip_cidr'] is List)
            .toList();

    // 默认（bypassLan=true）：回环 + 三个内网段都直连
    final lanCidrs = ipRules(_buildConfig()).expand((r) => (r['ip_cidr'] as List)).toSet();
    expect(lanCidrs, contains('127.0.0.0/8'));
    expect(lanCidrs, contains('10.0.0.0/8'));
    expect(lanCidrs, contains('172.16.0.0/12'));
    expect(lanCidrs, contains('192.168.0.0/16'));

    // bypassLan=false：只放行回环，内网段不再直连
    final rules = ipRules(_buildConfig(bypassLan: false));
    expect(rules, isNotEmpty);
    final cidrs = rules.expand((r) => (r['ip_cidr'] as List)).toSet();
    expect(cidrs, contains('127.0.0.0/8'), reason: '回环始终放行');
    expect(cidrs.contains('192.168.0.0/16'), isFalse, reason: '内网不放行');
    expect(cidrs.contains('10.0.0.0/8'), isFalse);
    expect(cidrs.contains('172.16.0.0/12'), isFalse);
    // 直连规则仍然只指向 direct
    expect(rules.every((r) => r['outbound'] == 'direct'), isTrue);
  });

  // 真实内核端到端：一个用例内跑两轮内核启停，Windows runner 上还叠加
  // killStaleKernels 的 PowerShell 进程枚举 + Defender 扫描新 exe，默认 30s
  // 超时会偶发被挤爆（环境性 flaky，非逻辑回归）。给足 2 分钟余量。
  test('端到端：启动内核 → Clash API 就绪 → 切模式 → 流量统计 → 停止',
      skip: skip, timeout: const Timeout(Duration(minutes: 2)), () async {
    _installKernel(binary!);
    ProxyCoreCli.manageSystemProxy = false;
    await _withKernelLock(() async {
      final core = ProxyCoreCli();
      expect(core.isRunning, isFalse);

      try {
        // 启动
        await core.start(_safeConfig());
        expect(core.isRunning, isTrue);

        // sing-box 只读 -c 指定的 JSON：配置文件与离线规则集必须已落盘
        // （工作目录 = ProxyCoreCli.workDir，内核 -D 也指向它）
        final workDir = Directory(ProxyCoreCli.workDir);
        final configFile = File('${workDir.path}/config.json');
        expect(configFile.existsSync(), isTrue,
            reason: 'sing-box 必须用 -c 显式指定配置，不能依赖默认文件名');
        final written = jsonDecode(configFile.readAsStringSync()) as Map;
        expect(written.containsKey('inbounds'), isTrue);
        expect(written['route'], isA<Map>());
        // 元数据键不得写进配置文件（否则内核解析即失败）
        expect(written.keys.any((k) => '$k'.startsWith('_')), isFalse);
        // 规则集引用了 .srs → 文件必须在位，否则内核启动直接 FATAL
        expect(File('${workDir.path}/geosite-cn.srs').existsSync(), isTrue);
        expect(File('${workDir.path}/geoip-cn.srs').existsSync(), isTrue);

        // 热切模式（Clash API PATCH /configs）——global ↔ rule 不应抛错
        await core.switchMode(false);
        await core.switchMode(true);

        // 流量统计回调（1s 流式推送；假节点无实际流量时 tick 可能为 0，
        // 仅验证回调注册不抛、不挂起——CI runner 无出站流量属正常）
        core.onTraffic = (up, down) {};
        await Future.delayed(const Duration(milliseconds: 2600));

        // 异常退出回调（主动停止不应触发）
        var unexpected = 0;
        core.onUnexpectedExit = () => unexpected++;

        // 停止：进程干净退出
        await core.stop();
        await Future.delayed(const Duration(milliseconds: 600));
        expect(core.isRunning, isFalse);
        expect(unexpected, 0, reason: '主动断开不应视为异常退出');

        // 二次启动（幂等性：停止后可再次连接）
        await core.start(_safeConfig());
        expect(core.isRunning, isTrue);
        await core.stop();
      } finally {
        // 断言失败时确保内核停止，避免残留进程占用端口污染其他测试
        if (core.isRunning) {
          await core.stop();
        }
      }
    });
  });

  test('配置序列化：JSON 可解析、端口正确、元数据不外泄', skip: skip, () {
    final encoded = SingBoxConfigBuilder.encode(
        _buildConfig(ruleSetDir: _ruleSetDir));
    final decoded = jsonDecode(encoded) as Map;
    final inbounds = (decoded['inbounds'] as List).cast<Map>();
    expect(inbounds.firstWhere((i) => i['type'] == 'mixed')['listen_port'], 2080);
    expect((decoded['experimental'] as Map)['clash_api']['default_mode'], 'Rule');
    // 元数据不得写入配置文件
    expect(decoded.containsKey('_localPort'), isFalse);
    expect(decoded.containsKey('_tunMode'), isFalse);
    expect(decoded.containsKey('_clashApiPort'), isFalse);
    expect(decoded.containsKey('_clashApiSecret'), isFalse);
    expect(decoded.keys.any((k) => '$k'.startsWith('_')), isFalse);
    // 产物是带缩进的 JSON（写盘后人类可读、可 diff）
    expect(encoded.contains('\n'), isTrue);
    expect(encoded.split('\n').any((l) => l.startsWith('  "log":')), isTrue,
        reason: '2 空格缩进（JsonEncoder.withIndent(\'  \')）');
  });
}
