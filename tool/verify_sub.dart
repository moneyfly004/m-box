// ignore_for_file: avoid_print, unnecessary_brace_in_string_interps
// 真实订阅全链路验证（运维/验收用）：
//   1) 解析订阅 Clash YAML（与生产同路径 ProxyNode.fromClashMap）
//   2) SingBoxConfigBuilder 生成配置 → sing-box check 校验
//   3) 启动真实内核 → Clash API 核对 select/GLOBAL 组
//   4) 对全部节点并发 delay 测速（走真实隧道），按协议类型统计成功率
//   5) 热切节点 + rule/global 模式切换
// 用法: dart run tool/verify_sub.dart <订阅.yaml> [测速URL]
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/singbox_config.dart';
import 'package:yaml/yaml.dart';

/// 定位 sing-box 内核：环境变量注入优先，其次仓库自带的开发内核（.core_dl），
/// 最后退回 PATH 里的 sing-box。
String _findKernel() {
  final injected = Platform.environment['MBOX_SINGBOX'];
  if (injected != null && injected.isNotEmpty && File(injected).existsSync()) {
    return injected;
  }
  final coreDl = Directory('.core_dl');
  if (coreDl.existsSync()) {
    for (final d in coreDl.listSync().whereType<Directory>()) {
      final candidate = '${d.path}/sing-box';
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return 'sing-box';
}

final singBox = _findKernel();

Future<void> main(List<String> args) async {
  final file = args.isNotEmpty ? args.first : '/tmp/mf_sub.yaml';
  final testUrl = args.length > 1
      ? args[1]
      : 'http://www.gstatic.com/generate_204';
  final raw = File(file).readAsStringSync();
  final doc = loadYaml(raw) as Map;
  final proxiesRaw = (doc['proxies'] as List).cast<Map>();
  final nodes =
      proxiesRaw.map((m) => ProxyNode.fromClashMap(Map<String, dynamic>.from(m))).toList();

  final types = <String, int>{};
  for (final n in nodes) {
    types[n.type] = (types[n.type] ?? 0) + 1;
  }
  print('解析节点总数: ${nodes.length}');
  print('类型分布: ${types}');

  // ===== 1. 生成配置（生产路径一致）=====
  final real = nodes.where((n) => !n.server.contains('baidu.com')).toList();
  final sel = real.firstWhere((n) => n.type == 'vless', orElse: () => real.first);
  print('选中默认节点: ${sel.tag} (${sel.type})');

  final cfg = SingBoxConfigBuilder.build(
    nodes: nodes, // 含面板伪节点，与生产一致
    selectedTag: sel.tag,
    smartMode: true,
    geoReady: true,
  );
  // 端口改成本次验证专用：生产配置占 2080/9090，本机上 App 可能正在用，
  // 直接用会 bind 失败（这正是这个工具最常见的「看起来内核起不来」）。
  final apiPort = 20090 + (DateTime.now().millisecondsSinceEpoch % 2000);
  final clashApi = ((cfg['experimental'] as Map?)?['clash_api'] as Map?);
  if (clashApi == null) {
    print('!!! 配置里没有 experimental.clash_api，无法做控制面校验');
    exit(1);
  }
  clashApi['external_controller'] = '127.0.0.1:$apiPort';
  final secret = (clashApi['secret'] as String?) ?? '';
  for (final inb in (cfg['inbounds'] as List? ?? const []).cast<Map>()) {
    if ('${inb['type']}' == 'mixed' || '${inb['type']}' == 'socks' ||
        '${inb['type']}' == 'http') {
      inb['listen_port'] = 22990;
    }
  }
  final yamlText = SingBoxConfigBuilder.encode(cfg);
  final tmp = Directory.systemTemp.createTempSync('mf_verify');
  try {
    // 离线规则集复制到 homeDir（生产由 GeoAssets 落盘）
    for (final f in ['geosite-cn.srs', 'geoip-cn.srs']) {
      final src = File('assets/rules/$f');
      if (src.existsSync()) src.copySync('${tmp.path}/$f');
    }
    File('${tmp.path}/config.json').writeAsStringSync(yamlText);

    // ===== 2. sing-box check 校验 =====
    final t = Process.runSync(singBox, ['check', '-c', '${tmp.path}/config.json'],
        environment: {'PATH': Platform.environment['PATH'] ?? ''});
    print('sing-box check exit=${t.exitCode}');
    if (t.exitCode != 0) {
      stdout.write('${t.stdout}\n${t.stderr}\n');
      exit(1);
    }
    print('=== 配置被 sing-box 接受 ✓ ===');

    // ===== 3. 启动真实内核 =====
    final proc = await Process.start(
        singBox, ['run', '-c', '${tmp.path}/config.json', '-D', tmp.path],
        environment: {'PATH': Platform.environment['PATH'] ?? ''});
    proc.stdout.transform(utf8.decoder).listen((l) {});
    proc.stderr.transform(utf8.decoder).listen((l) {});

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 3),
    ));
    dio.options.headers['Authorization'] = 'Bearer $secret';
    final api = 'http://127.0.0.1:$apiPort';

    var ready = false;
    for (var i = 0; i < 100; i++) {
      try {
        final r = await dio.get('$api/version',
            options: Options(validateStatus: (s) => true));
        if (r.statusCode == 200) {
          ready = true;
          break;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!ready) {
      print('!!! 内核 10s 未就绪');
      exit(1);
    }
    final v = await dio.get('$api/version');
    print('内核版本: ${v.data}');

    // ===== 4. 核对组 =====
    final px = await dio.get('$api/proxies');
    final pxMap = (px.data as Map)['proxies'] as Map;
    final select = (pxMap['select'] as Map);
    final members = (select['all'] as List).cast<String>();
    print('select 组: ${members.length} 项(含 DIRECT)');
    final dup = members.length - members.toSet().length;
    print('组内重复名: $dup');
    // sing-box 没有旧内核的 GLOBAL 组：全局模式由 clash_mode 规则实现，
    // 这里核对的是我们自己的 select 组（热切节点的入口）。
    print('GLOBAL 组存在: ${pxMap.containsKey('GLOBAL')}（sing-box 无此组，属预期）');
    print('select now=${select['now']}');

    // 核对每个解析节点都在组里（特殊字符名/超长名是否被 YAML 安全编码）
    final missing = real.where((n) => !members.contains(n.tag)).toList();
    print('真实节点缺失于组内: ${missing.length}'
        '${missing.isEmpty ? '' : ' 例: ${missing.take(3).map((n) => n.tag).join(" | ")}'}');

    // ===== 5. 全节点测速（真实隧道）=====
    print('开始全节点测速（8 并发, timeout 3.5s）...');
    final all = real;
    final results = <String, List<int>>{}; // type -> [success, fail]
    for (final n in all) {
      results[n.type] = [0, 0];
    }
    final failedSamples = <String>[];
    var done = 0;
    var nextIdx = 0;
    const workers = 8;

    Future<void> worker() async {
      while (true) {
        final idx = nextIdx;
        if (idx >= all.length) break;
        nextIdx++;
        final n = all[idx];
        final sw = Stopwatch()..start();
        var ok = false;
        try {
          final r = await dio.get(
              '$api/proxies/${Uri.encodeComponent(n.tag)}/delay',
              queryParameters: {
                'timeout': '3500',
                'url': testUrl,
              },
              options: Options(
                  validateStatus: (s) => true,
                  receiveTimeout: const Duration(seconds: 6)));
          if (r.statusCode == 200 && r.data is Map && r.data['delay'] is num) {
            ok = true;
          }
        } catch (_) {}
        sw.stop();
        if (ok) {
          results[n.type]![0]++;
        } else {
          results[n.type]![1]++;
          if (failedSamples.length < 8) {
            failedSamples.add('${n.type} | ${n.tag} | ${sw.elapsedMilliseconds}ms');
          }
        }
        done++;
        if (done % 100 == 0) print('  测速进度 $done/${all.length}');
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
    print('=== 测速结果 ===');
    for (final e in results.entries) {
      final ok = e.value[0];
      final fail = e.value[1];
      final rate = ok + fail == 0 ? 0 : (ok * 100 / (ok + fail)).toStringAsFixed(1);
      print('  ${e.key.padRight(10)} 成功 $ok / 失败 $fail  (${rate}%)');
    }
    final totOk = results.values.fold<int>(0, (a, b) => a + b[0]);
    final totFail = results.values.fold<int>(0, (a, b) => a + b[1]);
    print('总计: 成功 $totOk / 失败 $totFail / '
        '成功率 ${(totOk * 100 / (totOk + totFail)).toStringAsFixed(1)}%');
    if (failedSamples.isNotEmpty) {
      print('失败样例(前8):');
      for (final s in failedSamples) {
        print('  $s');
      }
    }

    // ===== 6. 热切节点 + 模式切换 =====
    final okNode = real.firstWhere((n) => n.type == 'vless');
    await dio.put('$api/proxies/select', data: {'name': okNode.tag},
        options: Options(validateStatus: (s) => true));
    await dio.patch('$api/configs', data: {'mode': 'global'},
        options: Options(validateStatus: (s) => true));
    await Future.delayed(const Duration(milliseconds: 300));
    final c1 = await dio.get('$api/configs');
    print('切到全局后 mode=${c1.data['mode']}');
    await dio.put('$api/proxies/select', data: {'name': okNode.tag},
        options: Options(validateStatus: (s) => true));
    await Future.delayed(const Duration(milliseconds: 300));
    final px2 = await dio.get('$api/proxies');
    print('select now=${(px2.data as Map)['proxies']['select']['now']}');
    await dio.patch('$api/configs', data: {'mode': 'rule'},
        options: Options(validateStatus: (s) => true));
    final c2 = await dio.get('$api/configs');
    print('切回智能后 mode=${c2.data['mode']}');

    proc.kill();
    await proc.exitCode;
    dio.close(force: true);
    print('=== 验证完成 ===');
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
