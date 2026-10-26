// TUN 启动失败判定：只认真正的启动失败，不把正常告警当致命。
//
// 背景（旧实现 `_tunFailedInLog`）：判定是「行里同时含 tun 和 error/failed」，
// 而旧内核有一批正常日志同样命中 —— 最典型的是
// `[TUN] Auto detect interface for <名> failed, return '<invalid>' …`
// （多虚拟网卡 / Hyper-V / 某些 VPN 环境下探不到出口接口，属正常告警）。
// 后果：一条本来正常的连接被判死、提示「请以管理员身份运行」，用户按提示提权
// 后依旧失败，真因被掩盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/tun_failure.dart';

void main() {
  group('detectTunStartFailure：正常告警不得判为失败', () {
    test('auto-detect-interface 探测失败（最常见误判源）', () {
      expect(
        detectTunStartFailure([
          'time="..." level=warning msg="[TUN] Auto detect interface for Ethernet 2 failed, return \'<invalid>\' to avoid lookback"',
        ]),
        TunStartFailure.none,
      );
    });

    test('默认网卡监控/名称类日志', () {
      expect(
        detectTunStartFailure([
          'msg="[TUN] default interface changed by monitor, => Ethernet"',
          'msg="[TUN] default interface lost by monitor"',
          'msg="[TUN] use tun name Meta"',
          'msg="[TUN] Tun adapter listening at: Meta"',
        ]),
        TunStartFailure.none,
      );
    });

    test('数据面转发错误（连接期偶发，不代表 TUN 没起来）', () {
      expect(
        detectTunStartFailure([
          'error writing to TUN device',
          'Failed to read packet from TUN device',
          'error reading from TUN device',
        ]),
        TunStartFailure.none,
      );
    });

    test('空日志 / 正常启动日志', () {
      expect(detectTunStartFailure(const []), TunStartFailure.none);
      expect(
        detectTunStartFailure([
          'level=info msg="[TUN] Tun adapter listening at: MBox"',
        ]),
        TunStartFailure.none,
      );
    });
  });

  group('detectTunStartFailure：分类正确', () {
    test('权限不足 → privilege', () {
      expect(
        detectTunStartFailure([
          'level=error msg="Start TUN listening error: configure tun interface: Access is denied."',
        ]),
        TunStartFailure.privilege,
      );
      expect(
        detectTunStartFailure([
          'Start TUN listening error: operation not permitted',
        ]),
        TunStartFailure.privilege,
      );
    });

    test('同名网卡已存在 → adapterBusy（残留适配器，提权也没用）', () {
      expect(
        detectTunStartFailure([
          'level=error msg="Start TUN listening error: Cannot create a file when that file already exists."',
        ]),
        TunStartFailure.adapterBusy,
      );
    });

    test('驱动无法加载 → driver（多被安全软件拦截）', () {
      expect(
        detectTunStartFailure([
          'level=error msg="Start TUN listening error: unable to load library: wintun"',
        ]),
        TunStartFailure.driver,
      );
    });

    test('致命行与 OS 错误分行时也能归类（内核常见打两行）', () {
      expect(
        detectTunStartFailure([
          'level=error msg="Start TUN listening error"',
          'Access is denied.',
        ]),
        TunStartFailure.privilege,
      );
    });

    test('致命串无更多线索 → unknown（不编原因）', () {
      expect(
        detectTunStartFailure(['level=error msg="Start TUN listening error"']),
        TunStartFailure.unknown,
      );
      expect(
        detectTunStartFailure(['Start Tun interface timeout']),
        TunStartFailure.unknown,
      );
    });

    test('多条致命行取最后一条（本轮为准，不被上一轮残留带偏）', () {
      expect(
        detectTunStartFailure([
          'Start TUN listening error: Access is denied.',
          'Start TUN listening error: wintun unable to load library',
        ]),
        TunStartFailure.driver,
      );
    });
  });

  group('isFatalTunLine：单行判定（边收边判用，不受缓冲区容量影响）', () {
    test('只认真致命串', () {
      expect(isFatalTunLine('msg="Start TUN listening error: Access is denied."'),
          isTrue);
      expect(isFatalTunLine('Start Tun interface timeout'), isTrue);
      expect(
          isFatalTunLine(
              'msg="[TUN] Auto detect interface for X failed, return \'<invalid>\'"'),
          isFalse);
      expect(isFatalTunLine('msg="[TUN] Tun adapter listening at: MBox"'),
          isFalse);
    });
  });

  group('looksLikeTunTrouble：弱判据（只留痕，不中断）', () {
    test('已核实的正常日志不算可疑（避免多网卡机器每次连接都刷一条）', () {
      expect(
          looksLikeTunTrouble([
            'msg="[TUN] Auto detect interface for Ethernet 2 failed, return \'<invalid>\'"',
            'msg="[TUN] default interface changed by monitor"',
            'msg="[TUN] get tun name failed for fd 3"',
          ]),
          isFalse);
    });

    test('未知的 TUN 错误算可疑（内核换文案时的兜底线索）', () {
      expect(
          looksLikeTunTrouble([
            'msg="[TUN] setup route failed: some brand new error text"',
          ]),
          isTrue);
    });

    test('与 TUN 无关的错误不算可疑', () {
      expect(
          looksLikeTunTrouble(['msg="Start ShadowSocks server error: x"']),
          isFalse);
      expect(looksLikeTunTrouble(const []), isFalse);
    });
  });

  group('isRetryableTunFailure：确定性失败不重试', () {
    test('权限类不重试（运行中不可能拿到管理员权限，重试只会推迟提示）', () {
      expect(isRetryableTunFailure(TunStartFailure.privilege), isFalse);
    });

    test('网卡残留 / 驱动被拦可重试（上一轮内核可能还在拆适配器）', () {
      expect(isRetryableTunFailure(TunStartFailure.adapterBusy), isTrue);
      expect(isRetryableTunFailure(TunStartFailure.driver), isTrue);
      expect(isRetryableTunFailure(TunStartFailure.unknown), isTrue);
    });

    test('没有失败时不重试', () {
      expect(isRetryableTunFailure(TunStartFailure.none), isFalse);
    });
  });
}
