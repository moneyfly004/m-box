// 「启动时自动连接」的正式回归测试（2.2.23 修 bug 时由诊断脚本升级而来）。
//
// 背景 bug：HomePage._ensureNodes 里 `if (conn.nodes.isNotEmpty && !force) return;`
// 提前 return，把 `autoConnectIfEnabled()` 那一行整个吃掉 —— 只要冷启动从磁盘
// 缓存秒显线路（老用户每次启动的常态），或 nodes 已经就绪，自动连接就永远不会
// 发生，开关形同虚设。
//
// 断言方式（关键）：**注入记录型内核桩**，直接看 `connect()` 有没有推进到
// 「启动内核」这一步，而不是去猜 `conn.error != null` 之类的间接副作用
// （error 也可能来自订阅/门禁路径，无法区分「触发了连接」与「没触发」）。
//
// 覆盖：
//   A. autoConnect=true + 无磁盘缓存（走网络拉订阅）→ 必须连
//   B. autoConnect=true + 同版本有效磁盘缓存（冷启动秒显线路）→ 必须连
//   C. autoConnect=true + 线路已就绪 → 必须连
//   D. autoConnect=false + 无磁盘缓存 → 绝不连
//   E. autoConnect=false + 同版本有效磁盘缓存 → 绝不连
//   门闩矩阵：只连一次 / 无线路不消费门闩 / 登出复位 / 门禁拦截 / 已在连接 /
//             并发调用只连一次
//
// 注意：testWidgets 跑在 fake-async zone 里，真实文件 I/O 必须放进
// tester.runAsync()，否则 future 永不完成（曾因此在 SubscriptionCache.write 上挂死）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/proxy/proxy_core_cli.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/local_paths.dart';
import 'package:moneyfly/core/services/settings_store.dart';
import 'package:moneyfly/core/services/subscription_cache.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/core/services/update_service.dart';
import 'package:moneyfly/l10n/app_strings.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/home/home_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

/// 记录型内核桩：`start()` 被调用 = `connect()` 真的推进到了启动内核。
///
/// start() 故意抛错（真机这里会因「内核二进制缺失/端口冲突」等失败），
/// 好处是 connect() 立刻走失败分支：不会进入 connected 后的出口国家实测
/// （真实网络请求）与后台定时测速，测试因此既快又确定、零外部依赖。
class _FakeKernel implements ProxyCore {
  final List<Map<String, dynamic>> startCalls = [];
  int stopCalls = 0;

  /// 记下本次配置，便于断言「连的是哪个节点/哪个模式」
  Map<String, dynamic>? get lastConfig =>
      startCalls.isEmpty ? null : startCalls.last;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    startCalls.add(config);
    throw const _FakeKernelFailure('fake kernel: 测试环境不启动真实内核');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> switchMode(bool smart) async {}

  @override
  Future<void> switchNode(String tag) async {}

  @override
  Future<int> testNodeDelay(String tag,
          {Duration timeout = const Duration(seconds: 5), String? url}) async =>
      -1;

  @override
  Future<void> setKernelLogLevel(String level) async {}

  @override
  bool get isRunning => startCalls.isNotEmpty;

  @override
  String? get lastError => 'fake kernel';

  @override
  VoidCallback? onUnexpectedExit;

  @override
  void Function(double upMbps, double downMbps)? onTraffic;

  @override
  void dispose() {}
}

class _FakeKernelFailure implements Exception {
  const _FakeKernelFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

Map<String, dynamic> _subInfo() => {
      'subscribe_url': 'https://example.invalid/api/v1/client/subscribe?token=X',
      'expire_time': '2032-06-06 08:00:00',
      'device_limit': 600,
      'current_devices': 3,
      'remaining_days': 2104,
      'is_expired': false,
      'status': 'active',
    };

/// 能被解析出的最小 Clash 订阅（两个合成占位节点，绝不含真实节点信息）
const _clashYaml = '''
proxies:
  - {name: 测试节点A, type: ss, server: 203.0.113.10, port: 8388, cipher: aes-128-gcm, password: pw}
  - {name: 测试节点B, type: ss, server: 203.0.113.11, port: 8388, cipher: aes-128-gcm, password: pw}
''';

const _subUrl = 'https://example.invalid/api/v1/client/subscribe?token=X';

ProxyNode _node(String tag) => ProxyNode(
      tag: tag,
      type: 'ss',
      server: '203.0.113.10',
      port: 8388,
      cipher: 'aes-128-gcm',
      password: 'pw',
      countryCode: 'HK',
      raw: const {},
    );

/// 记录型假后端：所有请求本地应答，绝不联网
class _FakeBackend implements HttpClientAdapter {
  final List<String> calls = [];

  /// true 时所有请求都失败（模拟断网）
  bool offline = false;

  /// 订阅接口返回的节点 YAML（可换成空订阅）
  String yaml = _clashYaml;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    final uri = options.uri;
    calls.add('${options.method} ${uri.path}');
    if (offline) {
      throw DioException.connectionError(
          requestOptions: options, reason: '测试注入：断网');
    }
    if (uri.path.contains('/client/subscribe')) {
      return ResponseBody.fromString(yaml, 200,
          headers: {Headers.contentTypeHeader: ['text/plain']});
    }
    if (uri.path.endsWith('/user/subscribe')) {
      return ResponseBody.fromString(
          jsonEncode({'success': true, 'code': 0, 'message': '', 'data': _subInfo()}), 200,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
    }
    return ResponseBody.fromString(
        jsonEncode({'success': true, 'code': 0, 'message': '', 'data': null}), 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildMoneyFlyTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SessionState()..setLoggedIn(true)),
          ChangeNotifierProvider.value(value: ConnectionController.instance),
          ChangeNotifierProvider.value(value: AccountService.instance),
        ],
        child: child,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final conn = ConnectionController.instance;
  late _FakeKernel kernel;

  /// 每个用例都从「干净的一次启动」开始：门闩复位 + 清空节点
  Future<void> freshLaunch() async {
    await conn.resetForLogout();
    conn.error = null;
    conn.errorKind = ConnErrorKind.none;
  }

  void setSettings(Map<String, dynamic> s) {
    SharedPreferences.setMockInitialValues({
      'moneyfly_settings_v1': jsonEncode(s),
      'moneyfly_auto_login': true,
    });
    SettingsStore.resetForTest();
  }

  setUp(() {
    // 不碰真实系统代理（本机可能正跑着真实实例）
    ProxyCoreCli.manageSystemProxy = false;
    kernel = _FakeKernel();
    conn.debugSetCore(kernel);
    AccountService.instance.reset();
    UpdateInfo.currentVersion = '9.9.9';
    SettingsStore.resetForTest();
  });

  tearDown(() async {
    ProxyCoreCli.manageSystemProxy = true;
    conn.debugSetCore(ProxyCoreFactory.create());
    AccountService.instance.reset();
    SettingsStore.resetForTest();
    SubscriptionService.instance.clearCache();
    try {
      if (conn.status != ConnStatus.disconnected) await conn.disconnect();
    } catch (_) {}
  });

  // ── 门闩矩阵（controller 级，直接驱动状态机）────────────────────────────
  group('门闩矩阵：autoConnectIfEnabled()', () {
    test('1) 开关开 + 有线路 → 真的发起连接（内核桩 start 被调用 1 次）', () async {
      setSettings({'autoConnect': true});
      await freshLaunch();
      await conn.loadNodes([_node('节点1')]);

      final r = await conn.autoConnectIfEnabled();

      expect(r, AutoConnectOutcome.started);
      expect(kernel.startCalls.length, 1, reason: '开关开着且有线路 → connect() 必须被触发');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('2) 开关关 + 有线路 → 绝不连接', () async {
      setSettings({'autoConnect': false});
      await freshLaunch();
      await conn.loadNodes([_node('节点1')]);

      final r = await conn.autoConnectIfEnabled();

      expect(r, AutoConnectOutcome.disabled);
      expect(kernel.startCalls, isEmpty, reason: '开关关掉就绝不允许自动连接');
      expect(conn.status, ConnStatus.disconnected);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('3) 开关开 + 无线路 → 不连，且**不消费门闩**（线路到位后补一次）', () async {
      setSettings({'autoConnect': true});
      await freshLaunch();

      final first = await conn.autoConnectIfEnabled();
      expect(first, AutoConnectOutcome.noNodes);
      expect(kernel.startCalls, isEmpty);

      // 线路到位（订阅重试成功 / 回前台读到缓存）→ 必须补上这一次自动连接
      await conn.loadNodes([_node('节点1')]);
      final second = await conn.autoConnectIfEnabled();

      expect(second, AutoConnectOutcome.started,
          reason: '空列表不能吃掉整次启动的自动连接机会');
      expect(kernel.startCalls.length, 1);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('4) 只尝试一次：连过之后不再重复连接', () async {
      setSettings({'autoConnect': true});
      await freshLaunch();
      await conn.loadNodes([_node('节点1')]);

      expect(await conn.autoConnectIfEnabled(), AutoConnectOutcome.started);
      expect(kernel.startCalls.length, 1);

      // 手动断开后再来一次（例如回前台）：门闩必须拦住
      await conn.disconnect();
      final r = await conn.autoConnectIfEnabled();

      expect(r, AutoConnectOutcome.alreadyTried);
      expect(kernel.startCalls.length, 1, reason: '每次启动只允许自动连一次');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('5) 已在连接/已连接 → 视为目标达成，不重复发起', () async {
      setSettings({'autoConnect': true});
      await freshLaunch();
      await conn.loadNodes([_node('节点1')]);
      // 模拟「用户手快，先自己点了连接」
      conn.status = ConnStatus.connecting;

      final r = await conn.autoConnectIfEnabled();

      expect(r, AutoConnectOutcome.busy);
      expect(kernel.startCalls, isEmpty);
      conn.status = ConnStatus.disconnected;
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('6) 账号门禁（到期）→ 不发起建连，但给出用户可见的门禁文案', () async {
      setSettings({'autoConnect': true});
      await freshLaunch();
      await conn.loadNodes([_node('节点1')]);
      final acc = AccountService.instance;
      acc.loaded = true;
      acc.status = AccountStatus.expired;

      final r = await conn.autoConnectIfEnabled();

      expect(r, AutoConnectOutcome.blocked);
      expect(kernel.startCalls, isEmpty, reason: '受限账号绝不允许自动建连');
      expect(conn.error, isNotNull, reason: '必须留下用户可见的原因，不能静默');
      expect(conn.error, acc.blockText);
      expect(conn.status, ConnStatus.disconnected);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('7) 登出（resetForLogout）复位门闩 → 换账号后仍会自动连接', () async {
      setSettings({'autoConnect': true});
      await freshLaunch();
      await conn.loadNodes([_node('节点1')]);
      expect(await conn.autoConnectIfEnabled(), AutoConnectOutcome.started);

      await freshLaunch(); // 登出：门闩复位 + 节点清空
      await conn.loadNodes([_node('节点1')]);
      final r = await conn.autoConnectIfEnabled();

      expect(r, AutoConnectOutcome.started);
      expect(kernel.startCalls.length, 2);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('8) 并发调用（启动/回前台/下拉刷新同时到达）只连一次，不双开内核', () async {
      setSettings({'autoConnect': true});
      await freshLaunch();
      await conn.loadNodes([_node('节点1')]);

      final results = await Future.wait([
        conn.autoConnectIfEnabled(),
        conn.autoConnectIfEnabled(),
        conn.autoConnectIfEnabled(),
      ]);

      expect(kernel.startCalls.length, 1, reason: '并发判定必须收敛成一次 connect()');
      expect(results.where((r) => r == AutoConnectOutcome.started).length, 1);
      expect(results.where((r) => r == AutoConnectOutcome.alreadyTried).length, 2);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ── 冷启动端到端（HomePage widget，A/B/C/D/E）───────────────────────────
  group('冷启动 HomePage', () {
    late Directory tmp;
    late _FakeBackend backend;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mf_autoconnect_test');
      LocalPaths.debugSupportDir = () async => tmp;
      backend = _FakeBackend();
      ApiClient.resetInstance();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
      dio.httpClientAdapter = backend;
      ApiClient.debugDio = dio;
    });

    tearDown(() async {
      LocalPaths.debugSupportDir = null;
      ApiClient.debugDio = null;
      ApiClient.resetInstance();
      // 磁盘缓存就落在本用例的临时目录里，随 tmp 一起删除
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 渲染首页并等「首屏异步链」跑完（拉订阅 → 解析 isolate → 装载节点 → 自动连接）。
    ///
    /// 不用固定等待时间：这条链路要跨 isolate 解析 + 假后端多轮请求，CI 上
    /// （尤其 Windows runner 多文件并行、CPU 抢占时）偶尔跑不完，会让"无磁盘缓存"
    /// 的用例偶发失败（v2.2.29 的发布就卡在这两条：nodes=0）。
    /// 改成**轮询到状态稳定**、上限 3s：快机器立刻返回，慢机器也不会假失败；
    /// 状态始终不成立时依旧如实失败（不是把断言放宽）。
    Future<void> pumpHome(WidgetTester tester) async {
      // 稳定 = 线路已装载 **且** 连接动作已真正发起（内核 start 被调用）或已给出错误。
      //
      // ⚠️ 不能只看 status != disconnected：connect() 一进入就是 connecting，
      // 而内核 start 是**之后**才调的 —— 只看状态会在 start 之前就退出轮询，
      // 断言 kernel.startCalls==1 随机失败（macOS arm64 上真实踩到过）。
      bool settled() {
        final nodesReady = conn.nodes.isNotEmpty;
        final attemptDone = kernel.startCalls.isNotEmpty ||
            conn.error != null ||
            conn.errorKind != ConnErrorKind.none;
        return nodesReady && attemptDone;
      }

      await tester.runAsync(() async {
        await tester.pumpWidget(_wrap(const HomePage()));
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (!settled() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pump();
    }

    Future<void> writeCache(WidgetTester tester) async {
      await tester.runAsync(() async {
        await SubscriptionCache.instance.write(subscribeUrl: _subUrl, raw: _clashYaml);
        expect(await SubscriptionCache.instance.readLatest(), isNotNull,
            reason: '前置条件：磁盘缓存必须有效（同版本）');
      });
    }

    testWidgets('A. autoConnect=true + 无磁盘缓存（走网络拉订阅）→ 必须自动连接', (tester) async {
      setSettings({'autoConnect': true});
      await freshLaunch();

      await pumpHome(tester);

      debugPrint('[A] status=${conn.status} nodes=${conn.nodes.length} '
          'kernel.start=${kernel.startCalls.length} calls=${backend.calls}');
      expect(conn.nodes.isNotEmpty, isTrue, reason: '订阅应已被拉取并装载');
      expect(kernel.startCalls.length, 1, reason: '有线路 + 开关开 → 必须尝试连接一次');
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('B. autoConnect=true + 同版本有效磁盘缓存（冷启动秒显线路）→ 必须自动连接',
        (tester) async {
      setSettings({'autoConnect': true});
      await writeCache(tester);
      await freshLaunch();

      await pumpHome(tester);

      debugPrint('[B] status=${conn.status} nodes=${conn.nodes.length} '
          'kernel.start=${kernel.startCalls.length} calls=${backend.calls}');
      expect(conn.nodes.isNotEmpty, isTrue, reason: '应已从磁盘缓存秒显线路');
      expect(kernel.startCalls.length, 1,
          reason: '修复点：线路来自磁盘缓存时也必须触发 connect()（旧实现在这里提前 return）');
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('C. autoConnect=true + 线路已就绪 → 必须自动连接', (tester) async {
      setSettings({'autoConnect': true});
      await freshLaunch();
      // 等价于「上一次会话已把线路装进连接器」的冷启动第 1 帧
      await conn.loadNodes([_node('缓存线路1'), _node('缓存线路2')]);

      await pumpHome(tester);

      debugPrint('[C] status=${conn.status} nodes=${conn.nodes.length} '
          'kernel.start=${kernel.startCalls.length} calls=${backend.calls}');
      expect(conn.nodes.isNotEmpty, isTrue);
      expect(kernel.startCalls.length, 1,
          reason: 'nodes 已就绪时也必须触发 connect() —— 这一支就是被提前 return 吃掉的');
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('D. 对照：autoConnect=false + 无磁盘缓存 → 绝不自动连接', (tester) async {
      setSettings({'autoConnect': false});
      await freshLaunch();

      await pumpHome(tester);

      debugPrint('[D] status=${conn.status} nodes=${conn.nodes.length} '
          'kernel.start=${kernel.startCalls.length}');
      expect(conn.nodes.isNotEmpty, isTrue, reason: '订阅仍应正常拉取');
      expect(kernel.startCalls, isEmpty, reason: '关掉开关就不该自动连');
      expect(conn.status, ConnStatus.disconnected);
      expect(find.text(AppStrings.t('sub_updated_click_connect')), findsOneWidget,
          reason: '用户应被告知「订阅已更新，请点击连接」');
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('E. 对照：autoConnect=false + 同版本有效磁盘缓存 → 绝不自动连接', (tester) async {
      setSettings({'autoConnect': false});
      await writeCache(tester);
      await freshLaunch();

      await pumpHome(tester);

      debugPrint('[E] status=${conn.status} nodes=${conn.nodes.length} '
          'kernel.start=${kernel.startCalls.length}');
      expect(conn.nodes.isNotEmpty, isTrue);
      expect(kernel.startCalls, isEmpty, reason: '关掉开关就不该自动连');
      expect(conn.status, ConnStatus.disconnected);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('F. 边界：开关开 + 无缓存 + 断网 → 不连接，但必须有可见提示（不静默）',
        (tester) async {
      setSettings({'autoConnect': true});
      await freshLaunch();
      backend.offline = true;

      await pumpHome(tester);
      await tester.pump(const Duration(milliseconds: 300));

      debugPrint('[F] status=${conn.status} nodes=${conn.nodes.length} '
          'kernel.start=${kernel.startCalls.length} error=${conn.error}');
      expect(kernel.startCalls, isEmpty, reason: '没有线路时无从连接');
      // 用户可见：订阅链路必须给出提示（可操作弹框 / SnackBar / 自动连接专用文案）
      final prompted = find.byType(AlertDialog).evaluate().isNotEmpty;
      final toasted = find.byType(SnackBar).evaluate().isNotEmpty;
      final autoMsg = find
          .textContaining('自动连接')
          .evaluate()
          .isNotEmpty;
      expect(prompted || toasted || autoMsg, isTrue,
          reason: '断网 + 自动连接开启：必须让用户看到「为什么没自动连上」');
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('G. 边界：开关开 + 缓存秒显 → 回前台刷新不再重复连接（门闩跨刷新有效）',
        (tester) async {
      setSettings({'autoConnect': true});
      await writeCache(tester);
      await freshLaunch();

      await pumpHome(tester);
      expect(kernel.startCalls.length, 1, reason: '前置条件：冷启动已自动连接一次');

      // 回前台 → didChangeAppLifecycleState → _ensureNodes()（缓存秒显支路）
      await tester.runAsync(() async {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();

      debugPrint('[G] status=${conn.status} kernel.start=${kernel.startCalls.length}');
      expect(kernel.startCalls.length, 1,
          reason: '每次启动只允许自动连接一次：回前台刷新不得再连一次');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
