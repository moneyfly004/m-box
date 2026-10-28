import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/platform/elevation.dart';
import 'package:mbox/core/platform/mac_tun_helper.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/proxy/tun_failure.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:mbox/l10n/app_strings.dart';

/// 首页三态（智能 / 全局 / TUN）与「TUN 需要提权」的行为约定。
///
/// 背景（2026-10-28 虚拟机实证）：Windows 非管理员开 TUN，mihomo 打一行
///   `Start TUN listening error: configure tun interface: Access is denied.`
/// 立刻退出，App 把失败报成「内核启动后立即退出 + 0xC0000005/杀毒拦截」，
/// 用户根本不知道该提权。这里锁住三件事：
///  1) 这类退出必须被归类成 TUN 权限失败（privilege），而不是「未知退出」；
///  2) 首页三态的判定与设置键 tunMode 一一对应，TUN = force；
///  3) 未提权时不允许切进 TUN（UI 层据此弹「以管理员身份重启」）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Elevation.debugElevatedOverride = null;
    ConnectionController.instance.applySettings({
      'tunMode': 'off',
      'defaultMode': 'smart',
      'speedTestMode': 'kernel',
    });
  });

  tearDown(() {
    Elevation.debugElevatedOverride = null;
    MacTunHelper.debugGrantedOverride = null;
  });

  group('TUN 启动失败归类', () {
    test('Windows 未提权的真实内核日志 → privilege（不是 unknown）', () {
      // 这一行来自虚拟机里 mihomo 的 kernel_log.txt 原文
      const line =
          'level=error msg="Start TUN listening error: configure tun interface: Access is denied."';
      expect(isFatalTunLine(line), isTrue,
          reason: '必须命中致命串，否则内核退出会被当成未知原因');
      expect(detectTunStartFailure([line]), TunStartFailure.privilege,
          reason: 'Access is denied = 没提权，提示应引导管理员重启而不是查 CPU/杀毒');
      expect(isRetryableTunFailure(TunStartFailure.privilege), isFalse,
          reason: '提权失败重试多少次都一样，不该耗用户 8~30 秒');
    });

    test('正常 TUN 告警不会被判死（保持既有口径）', () {
      expect(
          detectTunStartFailure([
            '[TUN] default interface changed by monitor, => 以太网',
            '[TUN] Tun adapter listening at: mihomo(fd=11)',
          ]),
          TunStartFailure.none);
    });
  });

  group('首页三态', () {
    test('默认：智能 + TUN 关闭', () {
      final c = ConnectionController.instance;
      expect(c.tunMode, 'off');
      expect(c.tunActive, isFalse);
      expect(c.homeMode, HomeMode.smart);
      expect(c.supportsTun, Platform.isWindows || Platform.isMacOS);
    });

    test('启动时上次残留的 tunMode=force 会被归一化成智能（用户要求默认智能）', () async {
      final c = ConnectionController.instance;
      c.debugResetTunStartupNormalized();
      c.tunMode = 'off';
      c.applySettings({'tunMode': 'force', 'defaultMode': 'smart'});
      // 三平台口径不同（CI 跑在 Linux 上，也必须有明确断言）：
      //  - Windows/macOS：有 TUN 入口 → force 归一化成 off，首页=智能
      //  - Android/iOS：tunMode 恒 auto（VpnService/PacketTunnel 就是 TUN）
      //  - Linux：没有 TUN 入口，但归一化同样把 force 收成 off
      if (c.supportsTun) {
        expect(c.tunMode, 'off', reason: '没有 pendingTunConnect 时不该一启动就停在 TUN');
        expect(c.homeMode, HomeMode.smart);
      } else if (Platform.isAndroid || Platform.isIOS) {
        expect(c.tunMode, 'auto');
      } else {
        expect(c.tunMode, 'off');
      }
      // 归一化要落盘（否则设置页仍显示「强制」）。写入走串行队列，
      // 轮询到稳定为止，避免 CI 上固定延时不够导致偶发失败。
      String? stored;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        stored = (await SettingsStore.instance.load())['tunMode']?.toString();
        if (stored != 'force') break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(stored, isNot('force'));
    });

    test('提权重启续连（pendingTunConnect）时保留 force，不归一化', () {
      final c = ConnectionController.instance;
      c.debugResetTunStartupNormalized();
      c.tunMode = 'off';
      c.applySettings({'tunMode': 'force', 'pendingTunConnect': true});
      if (c.supportsTun) {
        expect(c.tunMode, 'force');
        expect(c.homeMode, HomeMode.tun);
      } else if (Platform.isAndroid || Platform.isIOS) {
        expect(c.tunMode, 'auto');
      } else {
        // Linux：无 TUN 入口，但「续连必须保留 force」的语义同样成立
        expect(c.tunMode, 'force');
      }
    });

    test('移动端语义：tunMode 恒为 auto（VpnService/PacketTunnel 就是 TUN）', () {
      // 只在移动端断言：Linux 也没有 TUN 入口，但语义是 off（桌面口径），
      // 之前用 `!supportsTun` 当「移动端」导致 CI 上误判。
      if (!Platform.isAndroid && !Platform.isIOS) return;
      final c = ConnectionController.instance;
      c.applySettings({'tunMode': 'off'});
      expect(c.tunMode, 'auto');
    });
  });

  group('switchHomeMode 的提权与持久化', () {
    test('macOS 一次性授权完成后（sudo 规则已装）→ 允许切 TUN', () async {
      if (!Platform.isMacOS) return;
      Elevation.debugElevatedOverride = false; // 进程仍是普通权限
      MacTunHelper.debugGrantedOverride = true; // 但内核免密规则已就绪
      final c = ConnectionController.instance;
      await c.switchHomeMode(HomeMode.tun);
      expect(c.tunMode, 'force');
      expect(c.homeMode, HomeMode.tun);
      MacTunHelper.debugGrantedOverride = null;
    });

    test('未提权点 TUN → StateError(tun_needs_admin)，不改设置', () async {
      if (!ConnectionController.instance.supportsTun) return; // 移动端没有该入口
      Elevation.debugElevatedOverride = false;
      final c = ConnectionController.instance;
      await expectLater(c.switchHomeMode(HomeMode.tun),
          throwsA(isA<StateError>()));
      expect(c.tunMode, 'off', reason: '拒绝后必须保持原状态，不能让 UI 显示成 TUN');
      final s = await SettingsStore.instance.load();
      expect(s['tunMode'], isNot('force'));
    });

    test('已提权点 TUN → tunMode=force 并落盘（与设置页「强制」同一个键）', () async {
      if (!ConnectionController.instance.supportsTun) return;
      Elevation.debugElevatedOverride = true;
      final c = ConnectionController.instance;
      await c.switchHomeMode(HomeMode.tun);
      expect(c.tunMode, 'force');
      expect(c.homeMode, HomeMode.tun);
      final s = await SettingsStore.instance.load();
      expect(s['tunMode'], 'force');
    });

    test('从 TUN 切回全局 → tunMode=off 且 defaultMode=global', () async {
      if (!ConnectionController.instance.supportsTun) return;
      Elevation.debugElevatedOverride = true;
      final c = ConnectionController.instance;
      await c.switchHomeMode(HomeMode.tun);
      await c.switchHomeMode(HomeMode.global);
      expect(c.tunMode, 'off');
      expect(c.smartMode, isFalse);
      expect(c.homeMode, HomeMode.global);
      final s = await SettingsStore.instance.load();
      expect(s['tunMode'], 'off');
      expect(s['defaultMode'], 'global');
    });

    test('切到智能 → defaultMode=smart，TUN 关闭', () async {
      if (!ConnectionController.instance.supportsTun) return;
      Elevation.debugElevatedOverride = true;
      final c = ConnectionController.instance;
      await c.switchHomeMode(HomeMode.tun);
      await c.switchHomeMode(HomeMode.smart);
      expect(c.tunMode, 'off');
      expect(c.smartMode, isTrue);
      final s = await SettingsStore.instance.load();
      expect(s['defaultMode'], 'smart');
    });
  });

  group('提权重启后的续连', () {
    test('pendingTunConnect=true → 即使 autoConnect 关也会连一次，并消费掉标记', () async {
      final c = ConnectionController.instance;
      await SettingsStore.instance.update((s) {
        s['autoConnect'] = false;
        s['pendingTunConnect'] = true;
        s['tunMode'] = 'force';
      });
      // 没有可用线路 → 返回 noNodes，但标记必须已被消费（避免每次启动都尝试）
      final outcome = await c.autoConnectIfEnabled();
      expect(outcome, AutoConnectOutcome.noNodes);
      final s = await SettingsStore.instance.load();
      expect(s.containsKey('pendingTunConnect'), isFalse,
          reason: '一次性标记必须消费掉');
    });

    test('autoConnect 关且无标记 → disabled（不误连）', () async {
      final c = ConnectionController.instance;
      c.debugResetAutoConnectLatch();
      await SettingsStore.instance.update((s) {
        s['autoConnect'] = false;
        s.remove('pendingTunConnect');
      });
      expect(await c.autoConnectIfEnabled(), AutoConnectOutcome.disabled);
    });
  });

  group('文案', () {
    test('中英都有 TUN 入口与提权对话框文案', () {
      for (final lang in ['zh', 'en']) {
        AppStrings.setLang(lang, persist: false);
        for (final key in [
          'home_mode_tun',
          'tun_admin_title',
          'tun_admin_body_win',
          'tun_admin_body_mac',
          'tun_admin_relaunch',
          'tun_admin_cancel',
          'tun_admin_cancelled',
          'tun_admin_fail',
          'tun_caption',
          'tun_mac_cmd_title',
          'tun_mac_copy_cmd',
          'tun_mac_cmd_copied',
          'tun_mac_grant',
          'tun_mac_grant_hint',
        ]) {
          expect(AppStrings.t(key), isNot(key), reason: '$lang 缺文案: $key');
        }
        expect(AppStrings.t('home_mode_tun'), isNotEmpty);
      }
    });

    test('取消提示带当前模式名（占位符被替换）', () {
      AppStrings.setLang('zh', persist: false);
      final msg = AppStrings.t('tun_admin_cancelled', {'mode': '智能模式'});
      expect(msg.contains('智能模式'), isTrue);
      expect(msg.contains('{mode}'), isFalse);
    });
  });
}
