// 原生侧内核启动失败的分类与文案映射 —— 单测。
//
// 起因（2026-09 线上日志，安卓 v2.2.16）：
//   [ERROR] connect failed: 内核启动超时：getPackageUid: Neither user 10235
//           nor current process has android.permission.INTERACT_ACROSS_USERS.
//
// 这条失败是 Android 框架在多用户/应用分身/工作资料空间下解析跨用户包 UID 时的
// 拒绝（详见 lib/core/proxy/native_start_failure.dart 的文件头注释），
// 普通 App 拿不到 INTERACT_ACROSS_USERS → 用户不换空间就永远失败。因此：
//   1) 必须给用户可执行的文案（而不是一串英文框架异常）；
//   2) 必须**不**做自动重连（否则每轮白等 20s，线上连续 3 次）。

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/conn_error.dart';
import 'package:mbox/core/proxy/native_start_failure.dart';

void main() {
  group('classifyNativeStartFailure：原生分类优先', () {
    test('Kotlin 侧显式分类 cross_user → crossUserBlocked', () {
      expect(
        classifyNativeStartFailure(
            kind: kNativeKindCrossUser, detail: 'whatever'),
        NativeStartFailure.crossUserBlocked,
      );
    });

    test('kind 大小写/空白不敏感', () {
      expect(
        classifyNativeStartFailure(kind: '  CROSS_USER ', detail: ''),
        NativeStartFailure.crossUserBlocked,
      );
    });

    test('vpn_not_prepared / app_missing', () {
      expect(classifyNativeStartFailure(kind: kNativeKindVpnNotPrepared),
          NativeStartFailure.vpnNotPrepared);
      expect(classifyNativeStartFailure(kind: kNativeKindAppMissing),
          NativeStartFailure.packageMissing);
    });
  });

  group('classifyNativeStartFailure：回退解析异常原文（老版本原生侧无 kind）', () {
    test('真实线上原文 → 跨用户拦截', () {
      const detail = 'getPackageUid: Neither user 10235 nor current process has '
          'android.permission.INTERACT_ACROSS_USERS.';
      expect(classifyNativeStartFailure(detail: detail),
          NativeStartFailure.crossUserBlocked);
      // 带环境诊断后缀也要能识别
      expect(
        classifyNativeStartFailure(
            detail: '$detail | uid=10235 userId=0 profiles=2'),
        NativeStartFailure.crossUserBlocked,
      );
    });

    test('INTERACT_ACROSS_USERS 大小写不敏感', () {
      expect(
        classifyNativeStartFailure(
            detail: 'neither user 1 nor current process has '
                'android.permission.interact_across_users'),
        NativeStartFailure.crossUserBlocked,
      );
    });

    test('未授权 / 应用不存在', () {
      expect(
        classifyNativeStartFailure(detail: 'android: missing vpn permission'),
        NativeStartFailure.vpnNotPrepared,
      );
      expect(
        classifyNativeStartFailure(
            detail: 'android: the application is not prepared or is revoked'),
        NativeStartFailure.vpnNotPrepared,
      );
      expect(
        classifyNativeStartFailure(
            detail: 'PackageManager\$NameNotFoundException: foo.bar'),
        NativeStartFailure.packageMissing,
      );
    });

    test('空 → none；无法识别 → unknown', () {
      expect(classifyNativeStartFailure(), NativeStartFailure.none);
      expect(classifyNativeStartFailure(kind: '', detail: '   '),
          NativeStartFailure.none);
      expect(classifyNativeStartFailure(detail: 'bind: address already in use'),
          NativeStartFailure.unknown);
    });
  });

  group('重试策略：确定性失败不自动重连', () {
    test('跨用户拦截不可重试，其余可重试', () {
      expect(isRetryableNativeStartFailure(NativeStartFailure.crossUserBlocked),
          isFalse);
      for (final f in [
        NativeStartFailure.none,
        NativeStartFailure.unknown,
        NativeStartFailure.vpnNotPrepared,
        NativeStartFailure.packageMissing,
      ]) {
        expect(isRetryableNativeStartFailure(f), isTrue,
            reason: '$f 应允许重试');
      }
    });
  });

  group('文案与 UI 引导', () {
    test('跨用户拦截 → 专门类型 + 专门文案（含可执行指引）', () {
      const f = NativeStartFailure.crossUserBlocked;
      expect(connErrorKindForNativeStartFailure(f),
          ConnErrorKind.androidMultiUserBlocked);
      expect(messageKeyForNativeStartFailure(f), 'vpn_multiuser_blocked');

      final msg = nativeStartFailureMessage(f, 'getPackageUid: Neither user ...');
      // 必须告诉用户「换回主空间 / 关闭分身」，否则他不知道怎么自救
      expect(msg.contains('分身'), isTrue);
      expect(msg.contains('主空间'), isTrue);
      // 原始详情仍保留（客服定位用）
      expect(msg.contains('getPackageUid'), isTrue);
    });

    test('跨用户拦截不显示「授权 VPN 权限」按钮（授权解决不了）', () {
      final g = guideForConnError(ConnErrorKind.androidMultiUserBlocked);
      expect(g.showGrantVpn, isFalse);
      expect(g.showGrantNotify, isFalse);
      expect(g.showRetry, isTrue);
      expect(g.foregroundHint, isFalse);
    });

    test('未授权 → 复用授权文案与引导', () {
      const f = NativeStartFailure.vpnNotPrepared;
      expect(connErrorKindForNativeStartFailure(f),
          ConnErrorKind.noVpnPermission);
      expect(messageKeyForNativeStartFailure(f), 'vpn_permission_needed');
    });

    test('无专门文案 → 回退「内核启动超时：详情」', () {
      expect(messageKeyForNativeStartFailure(NativeStartFailure.unknown), isNull);
      expect(connErrorKindForNativeStartFailure(NativeStartFailure.unknown),
          isNull);
      final msg = nativeStartFailureMessage(
          NativeStartFailure.unknown, 'bind: address already in use');
      expect(msg.contains('内核启动超时'), isTrue);
      expect(msg.contains('bind: address already in use'), isTrue);
      // 无详情时不出现孤零零的冒号
      final bare = nativeStartFailureMessage(NativeStartFailure.unknown, '  ');
      expect(bare.endsWith('：'), isFalse);
    });
  });
}
