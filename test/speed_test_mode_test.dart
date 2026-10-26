// 测速方式（内核测速 = 真连接 / TCP 测速 = 仅端口握手）的单元与组件测试。
//
// 覆盖本次改动的关键契约：
//   1) 默认是 TCP 测速；老用户设置里**没有这个 key** 时回落默认（TCP），显式的 kernel 仍被识别；
//   2) 节点名带 emoji/空格/斜杠/中文时必须 URL 编码（否则内核收到截断的名字）；
//   3) 内核 delay 响应解析：成功 / 失败 / 超时 的口径（绝不返回假数字）；
//   4) 切换测速方式后**清空**另一种方式测出的延迟（不混用旧值）；
//   5) 内核测速不可用时**如实报错**，绝不静默退回 TCP（就是本次要修的问题）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/kernel_delay_api.dart';
import 'package:moneyfly/core/proxy/singbox_config.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/proxy/speed_probe_kernel.dart';
import 'package:moneyfly/core/services/settings_store.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/core/services/speed_test_mode.dart';
import 'package:moneyfly/core/services/speed_tester.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProxyNode _node(String tag,
        {String type = 'vless',
        String server = '127.0.0.1',
        int port = 9,
        int latencyMs = -1}) =>
    ProxyNode(
      tag: tag,
      type: type,
      server: server,
      port: port,
      countryCode: 'HK',
      latencyMs: latencyMs,
      raw: const {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsStore.resetForTest();
    SpeedProbeKernel.debugStartFailure = null;
    SpeedProbeKernel.debugDelayOverride = null;
    SpeedTester.debugProbeOverride = null;
    final conn = ConnectionController.instance;
    conn.speedTestMode = defaultSpeedTestMode;
    conn.speedTestError = null;
    conn.lastSpeedTestMode = null;
    conn.lastSpeedTestTime = null;
  });

  tearDown(() {
    SpeedProbeKernel.debugStartFailure = null;
    SpeedProbeKernel.debugDelayOverride = null;
    SpeedTester.debugProbeOverride = null;
    ConnectionController.instance.speedTestMode = defaultSpeedTestMode;
  });

  group('测速方式解析（SpeedTestMode）', () {
    test('默认是 TCP 测速', () {
      expect(defaultSpeedTestMode, SpeedTestMode.tcp);
      expect(speedTestModeKey(defaultSpeedTestMode), 'tcp');
    });

    test('缺 key / null / 空串 / 无法识别的值 一律回落默认（TCP）', () {
      // 老用户本地设置里没有 speedTestMode 这个 key → 回落到默认（TCP 测速），
      // 不能抛异常；显式的 kernel 仍必须被识别（见下一条用例）。
      expect(parseSpeedTestMode(null), SpeedTestMode.tcp);
      expect(parseSpeedTestMode(''), SpeedTestMode.tcp);
      expect(parseSpeedTestMode('   '), SpeedTestMode.tcp);
      expect(parseSpeedTestMode('内核'), SpeedTestMode.tcp);
      expect(parseSpeedTestMode(123), SpeedTestMode.tcp);
      // 显式选了内核测速的用户：不能被默认值回落吃掉
      expect(parseSpeedTestMode('kernel'), SpeedTestMode.kernel);
      expect(parseSpeedTestMode('KERNEL'), SpeedTestMode.kernel);
      expect(parseSpeedTestMode('connect'), SpeedTestMode.kernel);
      expect(parseSpeedTestMode(<String>[]), SpeedTestMode.tcp);
    });

    test('显式 tcp（以及 Shadowrocket 叫法的 ping）解析为 TCP 测速', () {
      expect(parseSpeedTestMode('tcp'), SpeedTestMode.tcp);
      expect(parseSpeedTestMode(' TCP '), SpeedTestMode.tcp);
      expect(parseSpeedTestMode('ping'), SpeedTestMode.tcp);
    });
  });

  group('SettingsStore 持久化与回落', () {
    test('默认值里 speedTestMode = tcp（TCP 测速）', () async {
      await SettingsStore.instance.reset();
      final s = await SettingsStore.instance.load();
      expect(s['speedTestMode'], 'tcp');
      expect(parseSpeedTestMode(s['speedTestMode']), SpeedTestMode.tcp);
    });

    test('老用户快照缺 key → 读取后回落 TCP 测速（不异常）', () async {
      // 模拟 2.2.21 及更早版本写下的设置：整份 JSON 里没有 speedTestMode
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('moneyfly_settings_v1',
          '{"localPort":2080,"autoTest":true,"lastSelectedTag":"香港-01"}');
      final s = await SettingsStore.instance.load();
      expect(s.containsKey('speedTestMode'), isTrue,
          reason: '缺 key 时 defaults 必须补齐');
      expect(parseSpeedTestMode(s['speedTestMode']), SpeedTestMode.tcp);
      // 老字段没被丢掉
      expect(s['lastSelectedTag'], '香港-01');
    });

    test('用户显式选了 TCP → 读取得到 TCP（切换真的生效）', () async {
      await SettingsStore.instance
          .update((s) => s['speedTestMode'] = speedTestModeKey(SpeedTestMode.tcp));
      final s = await SettingsStore.instance.load();
      expect(parseSpeedTestMode(s['speedTestMode']), SpeedTestMode.tcp);
      // 只改这一个键，其它字段不被覆盖
      expect(s['localPort'], 2080);
    });

    test('值被写坏（key 存在但内容非法）→ 回落默认（TCP）', () {
      expect(parseSpeedTestMode('tpc'), SpeedTestMode.tcp);
      expect(parseSpeedTestMode('1'), SpeedTestMode.tcp);
    });
  });

  group('内核 delay 接口（节点名 URL 编码 + 响应解析）', () {
    test('节点名含 emoji/空格/斜杠/中文 → 必须编码', () {
      const tag = '🇭🇰 香港-01 / 倍率:1.0';
      final path = kernelDelayPath(tag);
      // 斜杠必须编成 %2F：否则内核会把它当路径分隔符 → 404 proxy not found
      expect(path.contains('/proxies/'), isTrue);
      expect(path.endsWith('/delay'), isTrue);
      expect(path.contains('%2F'), isTrue, reason: '斜杠必须编码');
      expect(path.contains('%20'), isTrue, reason: '空格必须编码');
      expect(path.contains('%F0%9F%87%AD%F0%9F%87%B0'), isTrue,
          reason: 'emoji（🇭🇰）必须编码');
      // 未编码的名字拼出来的路径是坏的（反例，证明这条断言有意义）
      expect(path, isNot(contains('香港-01 / 倍率')));
    });

    test('纯 ASCII 名字不被过度编码（保持内核可读性）', () {
      expect(kernelDelayPath('HK-01'), '/proxies/HK-01/delay');
    });

    test('成功响应：200 + delay 数字 → 毫秒数', () {
      expect(parseKernelDelayResponse(200, {'delay': 123}), 123);
      expect(parseKernelDelayResponse(200, {'delay': 12.7}), 12);
    });

    test('失败/超时响应一律 -1（绝不编数字）', () {
      // 内核超时：408 Request Timeout
      expect(parseKernelDelayResponse(408, {'message': 'timeout'}), -1);
      // 节点不存在（名字编码错 / 占位伪节点）：400
      expect(parseKernelDelayResponse(400, {'message': 'proxy not found'}), -1);
      // 目标不可达：504
      expect(parseKernelDelayResponse(504, null), -1);
      // 非 Map / 缺 delay / 非数字
      expect(parseKernelDelayResponse(200, 'ok'), -1);
      expect(parseKernelDelayResponse(200, <String, dynamic>{}), -1);
      expect(parseKernelDelayResponse(200, {'delay': 'fast'}), -1);
      // 0 / 负数：内核配置异常，按失败处理（0ms 会被当成「极快」）
      expect(parseKernelDelayResponse(200, {'delay': 0}), -1);
      expect(parseKernelDelayResponse(200, {'delay': -5}), -1);
    });

    test('错误原因可提取（用于日志定位「为什么全失败」）', () {
      expect(kernelDelayErrorMessage(400, {'message': 'proxy not found'}),
          'proxy not found');
      expect(kernelDelayErrorMessage(408, null), 'HTTP 408');
      expect(kernelDelayErrorMessage(200, {'delay': 1}), isNull);
    });
  });

  group('测速专用内核配置（buildProbe）', () {
    /// 节点出站 = outbounds 里 selector/direct/block 之外的项
    List<Map<String, dynamic>> nodeOutbounds(Map<String, dynamic> cfg) =>
        (cfg['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .where((o) =>
                !const {'selector', 'direct', 'block'}.contains(o['type']))
            .toList();

    Map<String, dynamic> selectorOf(Map<String, dynamic> cfg) =>
        (cfg['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((o) => o['type'] == 'selector');

    test('不含任何入站监听 / TUN，不碰用户端口', () {
      final cfg = SingBoxConfigBuilder.buildProbe(
        nodes: [_node('香港-01')],
        controllerPort: 45678,
      );
      // 没有 inbounds → 不可能占用用户的 2080（mixed / socks 都不监听）
      expect(cfg.containsKey('inbounds'), isFalse,
          reason: '探测内核不得占用任何本地端口');
      // 无 tun → 不建虚拟网卡、不改路由表（无需管理员权限）
      expect(cfg.containsKey('tun'), isFalse);
      // 不引用 rule_set（.srs）→ 无需 geo 数据、启动零网络
      final route = cfg['route'] as Map;
      expect(route.containsKey('rule_set'), isFalse);
      final rules = (route['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules.any((r) => r.containsKey('rule_set')), isFalse);
      expect(rules.any((r) => r.containsKey('clash_mode')), isFalse);
      // 探测流量一律走 select（没有国内直连判定），兜底也是 select
      expect(rules.last, {'outbound': 'select'});
      expect(route['final'], 'select');
      // 不联网更新 geo（sing-box 无 geo-auto-update 字段，连键都不该有）
      expect(cfg.containsKey('geo-auto-update'), isFalse);
      final clashApi = (cfg['experimental'] as Map)['clash_api'] as Map;
      expect(clashApi['external_controller'], '127.0.0.1:45678');
      expect('${clashApi['secret']}'.isNotEmpty, isTrue);
    });

    test('节点序列化与真实连接完全一致（同一份 buildOutbounds）', () {
      final nodes = [_node('香港-01'), _node('日本 / 02', type: 'hysteria2')];
      final probe = SingBoxConfigBuilder.buildProbe(
          nodes: nodes, controllerPort: 1);
      final real = SingBoxConfigBuilder.build(
        nodes: nodes,
        selectedTag: '香港-01',
        smartMode: true,
        geoReady: false,
      );
      // sing-box：节点就是 outbounds 里的协议出站，必须逐字段相同
      expect(nodeOutbounds(probe), nodeOutbounds(real),
          reason: '测速内核与连接内核必须用同一份节点定义，否则「测速通过但连不上」');
      expect(nodeOutbounds(probe).map((o) => o['tag']).toList(),
          ['香港-01', '日本 / 02']);
      // select 组可选成员也要一致（测速内核默认选第一个，连接内核选 selectedTag）
      expect(selectorOf(probe)['outbounds'],
          ['香港-01', '日本 / 02', 'direct']);
      expect(selectorOf(real)['outbounds'],
          ['香港-01', '日本 / 02', 'direct']);
    });

    test('onlyTags 只保留被测节点（大批量时把探测内核缩到最小）', () {
      final cfg = SingBoxConfigBuilder.buildProbe(
        nodes: [_node('A'), _node('B'), _node('C')],
        controllerPort: 1,
        onlyTags: {'B'},
      );
      expect(nodeOutbounds(cfg).map((o) => o['tag']).toList(), ['B']);
      // select 组里也不能留下没被探测的节点（否则测速结果对不上 tag）
      expect(selectorOf(cfg)['outbounds'], ['B', 'direct']);
    });

    test('订阅解析阶段就把占位伪节点滤掉 → 探测/连接配置里都不会出现', () {
      // 现状（实测线上订阅）：占位项的主过滤点在 subscription_service 的
      // _nodesFromYamlMap，所以正常路径下它们到不了 buildProbe。
      const yaml = '''
proxies:
  - {name: "📢 官网: dy.moneyfly.top", type: socks5, server: baidu.com, port: 1234}
  - {name: "💬 客服", type: socks5, server: baidu.com, port: 1234}
  - {name: "香港-01", type: socks5, server: 1.2.3.4, port: 1080}
''';
      final nodes = SubscriptionService.parseClashYaml(yaml);
      expect(nodes.map((n) => n.tag).toList(), ['香港-01']);
      final cfg = SingBoxConfigBuilder.buildProbe(
          nodes: nodes, controllerPort: 1);
      expect(nodeOutbounds(cfg), hasLength(1));
      expect(selectorOf(cfg)['outbounds'], ['香港-01', 'direct']);
    });
  });

  group('伪节点（面板占位项）不给假延迟', () {
    test('识别口径', () {
      expect(isPanelPseudoNode('📢 官网', 'baidu.com'), isTrue);
      expect(isPanelPseudoNode('💬 客服', 'baidu.com'), isTrue);
      expect(isPanelPseudoNode('香港-01', 'baidu.com'), isTrue);
      expect(isPanelPseudoNode('香港-01', '1.2.3.4'), isFalse);
      expect(_node('⏰ 到期时间').isPanelPseudo, isTrue);
    });

    test('TCP 测速跳过占位项（否则连的是真 baidu.com → 假「8ms 超快节点」）', () async {
      final probed = <String>[];
      SpeedTester.debugProbeOverride = (n) async {
        probed.add(n.tag);
        return 8;
      };
      final tester = SpeedTester();
      final res = await tester.testAll([
        _node('📢 官网: dy.moneyfly.top', server: 'baidu.com', port: 1234),
        _node('香港-01'),
      ]);
      expect(probed, ['香港-01'], reason: '占位项不该被真实探测');
      final pseudo = res.firstWhere((n) => n.tag.startsWith('📢'));
      expect(pseudo.latencyMs, -1, reason: '占位项不给数字');
      expect(res.last.latencyMs, 8);
    });
  });

  group('ConnectionController：方式分流与不混用旧值', () {
    test('TCP 测速模式下**即使已连接**也走纯 TCP（尊重用户选择）', () async {
      final conn = ConnectionController.instance;
      conn.speedTestMode = SpeedTestMode.tcp;
      final tcpProbed = <String>[];
      SpeedTester.debugProbeOverride = (n) async {
        tcpProbed.add(n.tag);
        return 33;
      };
      // 内核测速通道若被误用会走到这里（应当**不会**）
      SpeedProbeKernel.debugDelayOverride = (_) async => 999;
      SpeedProbeKernel.debugStartFailure = '不该被调用';

      await conn.loadNodes([_node('香港-01')]);
      final tested = await conn.testAllNodes([_node('香港-01')]);
      expect(tcpProbed, ['香港-01']);
      expect(tested.single.latencyMs, 33);
    });

    test('内核测速模式下未连接 → 走探测内核（真连接），不走 TCP', () async {
      final conn = ConnectionController.instance;
      conn.speedTestMode = SpeedTestMode.kernel;
      var tcpCalls = 0;
      SpeedTester.debugProbeOverride = (_) async {
        tcpCalls++;
        return 7;
      };
      final kernelProbed = <String>[];
      SpeedProbeKernel.debugDelayOverride = (tag) async {
        kernelProbed.add(tag);
        return 88;
      };
      await conn.loadNodes([_node('香港-01')]);
      final tested = await conn.testAllNodes([_node('香港-01')]);
      expect(kernelProbed, ['香港-01'], reason: '内核测速必须由内核完成');
      expect(tcpCalls, 0, reason: '选了内核测速就不该有任何 TCP 探测');
      expect(tested.single.latencyMs, 88);
    });

    test('探测内核拉不起来 → 如实报错并返回 0，绝不静默退回 TCP', () async {
      final conn = ConnectionController.instance;
      conn.speedTestMode = SpeedTestMode.kernel;
      var tcpCalls = 0;
      SpeedTester.debugProbeOverride = (_) async {
        tcpCalls++;
        return 7;
      };
      SpeedProbeKernel.debugStartFailure = '未找到 mihomo 内核二进制';

      await conn.loadNodes([_node('香港-01')]);
      final tested = await conn.speedTest(userInitiated: true);
      expect(tested, 0, reason: '一个都没测到就不能谎报完成');
      expect(conn.speedTestError, isNotNull);
      expect(conn.speedTestError, contains('未找到 mihomo 内核二进制'));
      expect(tcpCalls, 0, reason: '绝不静默退回 TCP —— 那正是要修的假阳性来源');
    });

    test('切换测速方式会清空另一种方式测出的延迟（不混着显示）', () async {
      final conn = ConnectionController.instance;
      conn.speedTestMode = SpeedTestMode.tcp;
      await conn.loadNodes([
        ProxyNode(
            tag: '香港-01',
            type: 'vless',
            server: '127.0.0.1',
            port: 9,
            countryCode: 'HK',
            latencyMs: 12,
            raw: const {})
          ..online = true,
      ]);
      conn.lastSpeedTestTime = '12:00';

      // 用户在设置里切到内核测速：applySettings 检测到方式变化
      conn.applySettings({'speedTestMode': 'kernel'});
      expect(conn.speedTestMode, SpeedTestMode.kernel);
      expect(conn.nodes.single.latencyMs, -1,
          reason: 'TCP 的 12ms 不能留在内核测速界面里（两者口径不同）');
      expect(conn.lastSpeedTestTime, isNull);
      expect(conn.lastSpeedTestMode, isNull);
      expect(conn.speedTestError, isNull);
    });

    test('方式没变时不清空延迟（普通设置变更不打扰已有结果）', () async {
      final conn = ConnectionController.instance;
      conn.speedTestMode = SpeedTestMode.kernel;
      await conn.loadNodes([
        ProxyNode(
            tag: '香港-01',
            type: 'vless',
            server: '127.0.0.1',
            port: 9,
            countryCode: 'HK',
            latencyMs: 45,
            raw: const {})
          ..online = true,
      ]);
      conn.applySettings({'speedTestMode': 'kernel', 'autoTest': false});
      expect(conn.nodes.single.latencyMs, 45);
      expect(conn.autoTest, isFalse);
    });

    test('applySettings 缺 key 时保持默认（TCP）', () async {
      final conn = ConnectionController.instance;
      conn.applySettings({'localPort': 2080});
      expect(conn.speedTestMode, SpeedTestMode.tcp);
    });

    test('测速完成后记录「结果是哪种方式测的」', () async {
      final conn = ConnectionController.instance;
      conn.speedTestMode = SpeedTestMode.kernel;
      SpeedProbeKernel.debugDelayOverride = (_) async => 55;
      await conn.loadNodes([_node('香港-01')]);
      await conn.speedTest(userInitiated: true);
      expect(conn.lastSpeedTestMode, SpeedTestMode.kernel);
      expect(conn.lastSpeedTestTime, isNotNull);
      expect(conn.nodes.single.latencyMs, 55);
    });
  });

  group('平台边界', () {
    test('Android/iOS 不支持单独拉起探测内核（内核在系统隧道进程里）', () {
      // macOS/Linux/Windows 的测试环境应为 supported
      expect(SpeedProbeKernel.isSupported, !Platform.isAndroid && !Platform.isIOS);
    });
  });
}
