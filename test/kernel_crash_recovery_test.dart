// 内核异常退出处置策略（纯逻辑）+ 控制器层面的自愈入口回归。
//
// 背景（2026-09-10 真实日志）：内核进程 code=1 静默退出，日志里
// `unexpected exit, status=connected, autoReconnect=false, count=0` —— 因为
// 「断线自动重连」默认关闭，控制器一次都没重试，用户过了一小时才发现断网。
// 内核进程消失属于客户端自身故障，必须与用户偏好解耦、无条件自愈。
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

CrashRecoveryAction _decide({
  bool autoReconnect = false,
  bool burst = false,
  int reconnectCount = 0,
  int maxReconnect = 3,
  int kernelRecoverCount = 0,
  int maxKernelRecover = 3,
}) =>
    decideCrashRecovery(
      autoReconnect: autoReconnect,
      burst: burst,
      reconnectCount: reconnectCount,
      maxReconnect: maxReconnect,
      kernelRecoverCount: kernelRecoverCount,
      maxKernelRecover: maxKernelRecover,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('decideCrashRecovery：内核崩溃后是否自动拉起', () {
    test('autoReconnect 关闭时仍然自愈（核心回归：默认设置下不许静默躺平）', () {
      expect(_decide(autoReconnect: false), CrashRecoveryAction.recover);
    });

    test('自愈有额度：用满 maxKernelRecover 后放弃', () {
      expect(_decide(autoReconnect: false, kernelRecoverCount: 2),
          CrashRecoveryAction.recover);
      expect(_decide(autoReconnect: false, kernelRecoverCount: 3),
          CrashRecoveryAction.giveUp);
    });

    test('autoReconnect 开启时沿用 reconnectTimes 额度（不看自愈额度）', () {
      // 自愈额度已用尽，但用户允许重连 10 次且只重连了 1 次 → 继续
      expect(
          _decide(
            autoReconnect: true,
            reconnectCount: 1,
            maxReconnect: 10,
            kernelRecoverCount: 9,
          ),
          CrashRecoveryAction.recover);
      expect(_decide(autoReconnect: true, reconnectCount: 10, maxReconnect: 10),
          CrashRecoveryAction.giveUp);
    });

    test('熔断优先：10 分钟内反复崩溃 → 放弃（否则无限 connect→崩→重连）', () {
      expect(_decide(burst: true), CrashRecoveryAction.giveUp);
      expect(_decide(autoReconnect: true, burst: true, reconnectCount: 0),
          CrashRecoveryAction.giveUp);
    });

    test('重连次数耗尽时优先放弃（无论自愈额度是否还有）', () {
      expect(_decide(reconnectCount: 3), CrashRecoveryAction.giveUp);
    });
  });

  group('控制器入口：onDisconnectedUnexpectedly', () {
    test('用户未开启自动重连时，内核崩溃不会直接落到「已断开」', () async {
      final conn = ConnectionController.instance;
      conn.autoReconnect = false;
      conn.status = ConnStatus.connected;

      conn.onDisconnectedUnexpectedly();

      // 旧行为：直接 disconnected + 错误文案 + 系统代理还原，永不恢复
      expect(conn.status, ConnStatus.reconnecting);
      expect(conn.error, isNull);

      // 收尾：取消已排的重连定时器（否则 1s 后会真的去 connect）
      await conn.disconnect();
      expect(conn.status, ConnStatus.disconnected);
    });

    test('未连接/用户主动断开时不触发自愈', () {
      final conn = ConnectionController.instance;
      conn.autoReconnect = false;
      conn.status = ConnStatus.disconnected;

      conn.onDisconnectedUnexpectedly();

      expect(conn.status, ConnStatus.disconnected);
      expect(conn.error, isNull);
    });
  });
}
