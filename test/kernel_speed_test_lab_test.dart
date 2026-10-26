// ignore_for_file: avoid_print
//
// 内核测速 vs TCP 测速 **对照实验**（可复现、自包含，不依赖任何生产资源）。
//
// 运行:
//   MBOX_SINGBOX=$PWD/.core_dl/sing-box-1.14.4-darwin-arm64/sing-box \
//     flutter test test/kernel_speed_test_lab_test.dart --tags e2e --concurrency=1
//
// 为什么是 e2e 测试而不是 dart run 脚本：它要调用**生产代码**
// （SpeedTester / SpeedProbeKernel），而这些类依赖 Flutter（app_log 等），
// `dart run` 编译不过；放到 flutter test 里跑才能保证「验证的就是真代码」。
// 它同时会启动真实 sing-box 进程 + 占用本地端口，因此打 e2e 标签串行执行。
//
// ## 实验设计
// 起一个**本机真实代理服务**（sing-box 自己，mixed 入站 + 用户名口令），再起两种「端口开着
// 但代理链路不可用」的假服务（普通 HTTP 服务 / 只 accept 不响应的黑洞），
// 把它们当作 4 个节点，用**生产代码**跑两遍：
//
//   1) TCP 测速   → SpeedTester（即当前客户端在用的那条路径）
//   2) 内核测速   → SpeedProbeKernel（本次新增：/proxies/{name}/delay，真连接）
//
// 预期（就是本次要证明的东西）：
//   - 可用节点：两种方式都能得到合理延迟；
//   - 「端口开着但代理不可用」的三个节点：**TCP 给假阳性**（显示很小的延迟），
//     内核测速**如实失败**。
//
// 另外验证节点名 URL 编码：节点名里放 emoji / 空格 / 斜杠，并额外用**未编码**
// 的原始路径直接打内核 API 做对照（未编码 → 内核 400/404，编码 → 200）。
@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/kernel_delay_api.dart';
import 'package:mbox/core/proxy/speed_probe_kernel.dart';
import 'package:mbox/core/services/speed_tester.dart';

final singBoxBin = Platform.environment['MBOX_SINGBOX'] ??
    '.core_dl/sing-box-1.14.4-darwin-arm64/sing-box';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

const _tagGood = '✅ 可用节点 / lab-good';
const _tagBadAuth = '❌ 凭据错误 / lab-bad-auth';
const _tagBadHttp = '❌ 端口开着但不是代理 / lab-bad-http';
const _tagBlackhole = '❌ 端口开着但黑洞 / lab-blackhole';

String pad(Object? s, int n) {
  final t = '$s';
  // 中文/emoji 宽度按 2 算，让表格对齐（仅展示用）
  var w = 0;
  for (final r in t.runes) {
    w += r > 0x2000 ? 2 : 1;
  }
  return t + ' ' * (n - w > 0 ? n - w : 0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认用 mock HttpClient（一切请求返回 400）：本实验需要真实
  // 访问内核 Clash API 与外网探测地址，必须复位成系统实现。
  HttpOverrides.global = null;

  test('对照实验：TCP 测速给假阳性，内核测速如实失败', () async {
    await _runLab();
  }, timeout: const Timeout(Duration(minutes: 6)));
}

Future<void> _runLab() async {
  stdout.writeln('=== 内核测速 vs TCP 测速 对照实验 ===');
  stdout.writeln('sing-box: $singBoxBin');
  stdout.writeln('内核版本: ${await _kernelVersion()}\n');

  // ---------------------------------------------------------------- 实验环境
  // ① 真实代理服务：sing-box 自己的 mixed 入站（本机 127.0.0.1:<port>）
  final proxyPort = await freePort();
  final upstreamDir =
      Directory('${Directory.systemTemp.path}/mf_lab_upstream')..createSync(recursive: true);
  // sing-box 的 mixed 入站开启用户名口令：这样「凭据错误」才是一个真实存在的
  // 失败场景（不加认证时任意用户名/密码都会被接受，那个节点其实是可用的）
  final upstreamCfg = {
    'log': {'level': 'warning'},
    'inbounds': [
      {
        'type': 'mixed',
        'tag': 'lab-in',
        'listen': '127.0.0.1',
        'listen_port': proxyPort,
        'users': [
          {'username': 'labuser', 'password': 'labpass'},
        ],
      },
    ],
    'outbounds': [
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {'rules': <Object>[], 'final': 'direct'},
  };
  File('${upstreamDir.path}/config.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(upstreamCfg));
  final upstream = await Process.start(
    singBoxBin,
    ['run', '-c', '${upstreamDir.path}/config.json', '-D', upstreamDir.path],
    environment: {'PATH': Platform.environment['PATH'] ?? ''},
  );
  final upstreamLog = <String>[];
  upstream.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(upstreamLog.add);
  upstream.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(upstreamLog.add);

  // ② 「端口开着但不是代理服务」：一个普通 HTTP 服务
  final httpPort = await freePort();
  final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, httpPort);
  httpServer.listen((req) async {
    req.response.statusCode = 200;
    req.response.write('hello from a plain HTTP server, not a proxy');
    await req.response.close();
  });

  // ③ 「端口开着但永不响应」：accept 后什么都不回（黑洞）
  final blackholePort = await freePort();
  final blackhole = await ServerSocket.bind(InternetAddress.loopbackIPv4, blackholePort);
  final blackholeSockets = <Socket>[];
  blackhole.listen(blackholeSockets.add);

  // 等真实代理服务就绪
  var ready = false;
  for (var i = 0; i < 60 && !ready; i++) {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort,
          timeout: const Duration(milliseconds: 300));
      s.destroy();
      ready = true;
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
  stdout.writeln('实验环境就绪:');
  stdout.writeln('  · 真实 SOCKS5 代理       127.0.0.1:$proxyPort  (ready=$ready)');
  stdout.writeln('  · 普通 HTTP 服务(非代理)  127.0.0.1:$httpPort');
  stdout.writeln('  · 黑洞服务(accept 不响应) 127.0.0.1:$blackholePort');
  stdout.writeln('  · 探测地址               $defaultKernelDelayUrl\n');

  final nodes = <ProxyNode>[
    // 可用节点：真实 SOCKS5 代理 + 正确凭据
    ProxyNode(
      tag: _tagGood,
      type: 'socks5',
      server: '127.0.0.1',
      port: proxyPort,
      countryCode: 'HK',
      raw: const {'username': 'labuser', 'password': 'labpass'},
    ),
    // 凭据错误：TCP 握手一定成功（端口真的开着），但代理链路不可用
    ProxyNode(
      tag: _tagBadAuth,
      type: 'socks5',
      server: '127.0.0.1',
      port: proxyPort,
      countryCode: 'HK',
      // 凭据错误：上游要求 labuser/labpass，这里故意用错的
      raw: const {
        'username': 'labuser',
        'password': 'definitely-not-the-password',
      },
    ),
    // 端口后面跑的是普通 HTTP 服务，不是代理：TCP 必通，代理握手必失败
    ProxyNode(
      tag: _tagBadHttp,
      type: 'http',
      server: '127.0.0.1',
      port: httpPort,
      countryCode: 'HK',
      raw: const {},
    ),
    // 黑洞：TCP 连接会被 accept（握手成功），但永远没有响应
    ProxyNode(
      tag: _tagBlackhole,
      type: 'socks5',
      server: '127.0.0.1',
      port: blackholePort,
      countryCode: 'HK',
      raw: const {},
    ),
  ];

  try {
    // -------------------------------------------------------- ① TCP 测速
    stdout.writeln('──────────────────────────────────────────────────────────────');
    stdout.writeln('① TCP 测速（SpeedTester，超时 3s × 3 次取中位数）');
    final tcpSw = Stopwatch()..start();
    final tcpResult = await SpeedTester(connectTimeout: const Duration(seconds: 3))
        .testAll(nodes, onProgress: (d, t) => stdout.write('\r  进度 $d/$t'));
    stdout.writeln('\r  完成，耗时 ${tcpSw.elapsedMilliseconds}ms');
    for (final n in tcpResult) {
      stdout.writeln('  ${pad(n.tag, 34)} ${pad('${n.latencyMs} ms', 12)} '
          'online=${n.online}');
    }

    // -------------------------------------------------------- ② 内核测速
    stdout.writeln('\n──────────────────────────────────────────────────────────────');
    stdout.writeln('② 内核测速（SpeedProbeKernel → 内核 /proxies/{name}/delay，超时 5s）');
    final kernelSw = Stopwatch()..start();
    await SpeedProbeKernel.instance.ensureStarted(nodes);
    stdout.writeln('  探测内核已启动: port=${SpeedProbeKernel.instance.controllerPort}');
    final kernelResult = <String, int>{};
    for (final n in nodes) {
      final ms = await SpeedProbeKernel.instance
          .testDelay(n.tag, timeout: const Duration(seconds: 5));
      kernelResult[n.tag] = ms;
      stdout.writeln('  ${pad(n.tag, 34)} ${pad(ms < 0 ? '失败' : '$ms ms', 12)}');
    }
    stdout.writeln('  完成，耗时 ${kernelSw.elapsedMilliseconds}ms');

    // -------------------------------------------------- ③ URL 编码对照
    stdout.writeln('\n──────────────────────────────────────────────────────────────');
    stdout.writeln('③ 节点名 URL 编码对照（同一条真实请求）');
    // 未编码：斜杠被当成路径分隔符、空格直接进 URL
    final rawPath = '/proxies/$_tagGood/delay'
        '?timeout=5000&url=${Uri.encodeComponent(defaultKernelDelayUrl)}';
    final rawStatus = await SpeedProbeKernel.instance.rawGetStatus(rawPath);
    stdout.writeln('  未编码路径: $rawPath');
    stdout.writeln('    → HTTP $rawStatus  (期望 400/404：内核收到截断的名字)');
    final encPath = '${kernelDelayPath(_tagGood)}'
        '?timeout=5000&url=${Uri.encodeComponent(defaultKernelDelayUrl)}';
    final encStatus = await SpeedProbeKernel.instance.rawGetStatus(encPath);
    stdout.writeln('  编码后路径: $encPath');
    stdout.writeln('    → HTTP $encStatus  (期望 200)');

    // -------------------------------------------------------- ④ 结论对照
    stdout.writeln('\n──────────────────────────────────────────────────────────────');
    stdout.writeln('④ 对照结论');
    stdout.writeln('${pad('节点', 34)}${pad('TCP 测速', 14)}${pad('内核测速', 14)}判定');
    var tcpFalsePositive = 0;
    var kernelFailures = 0;
    for (final n in nodes) {
      final tcp = tcpResult.firstWhere((r) => r.tag == n.tag);
      final tcpOk = mfLatencyUsable(tcp.latencyMs);
      final k = kernelResult[n.tag] ?? -1;
      final kOk = mfLatencyUsable(k);
      final isGood = n.tag == _tagGood;
      if (!isGood && tcpOk) tcpFalsePositive++;
      if (!isGood && !kOk) kernelFailures++;
      stdout.writeln('${pad(n.tag, 34)}'
          '${pad(tcpOk ? '${tcp.latencyMs} ms (online)' : '失败', 14)}'
          '${pad(kOk ? '$k ms' : '失败', 14)}'
          '${isGood ? '可用节点' : (tcpOk && !kOk ? '★ TCP 假阳性' : '?')}');
    }
    stdout.writeln('\n  TCP 测速假阳性（不可用节点仍显示延迟）: $tcpFalsePositive/3');
    stdout.writeln('  内核测速如实判失败（不可用节点）:      $kernelFailures/3');
    stdout.writeln('  可用节点两种方式: TCP=${tcpResult.first.latencyMs}ms, '
        '内核=${kernelResult[_tagGood]}ms');
    stdout.writeln('\n  结论: ${tcpFalsePositive == 3 && kernelFailures == 3 ? "✅ 复现成功：TCP 测速给出假阳性，内核测速如实失败" : "⚠️ 结果与预期不符，见上表"}');
  } finally {
    await SpeedProbeKernel.instance.stop();
    for (final s in blackholeSockets) {
      s.destroy();
    }
    await blackhole.close();
    await httpServer.close(force: true);
    upstream.kill(ProcessSignal.sigkill);
    try {
      await upstream.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {}
    stdout.writeln('\n[清理] 探测内核 / 上游代理 / 假服务 已全部退出');
  }
}

Future<String> _kernelVersion() async {
  try {
    final r = await Process.run(singBoxBin, ['version']);
    final out = (r.stdout as String).trim().split('\n');
    return out.isEmpty ? '（未知）' : out.first;
  } catch (_) {
    return '（未知）';
  }
}
