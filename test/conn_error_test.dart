import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/proxy/conn_error.dart';

/// 类型化连接失败：kind → UI 引导映射（纯函数，无 Flutter 依赖）
void main() {
  group('guideForConnError', () {
    test('缺 VPN 权限 → 只给「授权 VPN」，不给通用重试', () {
      final g = guideForConnError(ConnErrorKind.noVpnPermission);
      expect(g.showGrantVpn, isTrue);
      expect(g.showGrantNotify, isFalse);
      expect(g.showRetry, isFalse);
      expect(g.foregroundHint, isFalse);
    });

    test('缺通知权限 → 只给「允许通知」', () {
      final g = guideForConnError(ConnErrorKind.noNotificationPermission);
      expect(g.showGrantNotify, isTrue);
      expect(g.showGrantVpn, isFalse);
      expect(g.showRetry, isFalse);
    });

    test('后台启动受限 → 通用重试 + 保持前台提示', () {
      final g = guideForConnError(ConnErrorKind.backgroundStartBlocked);
      expect(g.showRetry, isTrue);
      expect(g.foregroundHint, isTrue);
      expect(g.showGrantVpn, isFalse);
      expect(g.showGrantNotify, isFalse);
    });

    test('未知/超时/内核退出 → 通用重试，无权限按钮', () {
      for (final k in [
        ConnErrorKind.unknown,
        ConnErrorKind.kernelTimeout,
        ConnErrorKind.kernelExited,
      ]) {
        final g = guideForConnError(k);
        expect(g.showRetry, isTrue, reason: '$k 应可重试');
        expect(g.showGrantVpn, isFalse, reason: '$k 不应显示授权按钮');
        expect(g.showGrantNotify, isFalse);
        expect(g.foregroundHint, isFalse);
      }
    });

    test('端口被占用 → 给「换端口并重连」（换端口才是解法）+ 保留重试', () {
      final g = guideForConnError(ConnErrorKind.portInUse);
      expect(g.showFixPort, isTrue, reason: '端口被占用时必须能换端口');
      expect(g.showRetry, isTrue, reason: '占用者刚退出时会想直接重试');
      expect(g.showGrantVpn, isFalse);
      expect(g.showGrantNotify, isFalse);
      expect(g.foregroundHint, isFalse);
    });

    test('其余类型都不显示「换端口」（别把无关故障引导成改端口）', () {
      for (final k in [
        ConnErrorKind.none,
        ConnErrorKind.unknown,
        ConnErrorKind.kernelTimeout,
        ConnErrorKind.kernelExited,
        ConnErrorKind.noVpnPermission,
        ConnErrorKind.noNotificationPermission,
        ConnErrorKind.backgroundStartBlocked,
        ConnErrorKind.androidMultiUserBlocked,
      ]) {
        expect(guideForConnError(k).showFixPort, isFalse, reason: '$k 不该显示换端口');
      }
    });

    test('none（无错误）→ 无任何按钮', () {
      final g = guideForConnError(ConnErrorKind.none);
      expect(g.showRetry, isFalse);
      expect(g.showGrantVpn, isFalse);
      expect(g.showGrantNotify, isFalse);
    });
  });

  group('TypedConnError', () {
    test('携带 kind 与 message', () {
      const e = TypedConnError(ConnErrorKind.kernelTimeout, '内核启动超时');
      expect(e.kind, ConnErrorKind.kernelTimeout);
      expect(e.toString(), '内核启动超时');
    });
  });
}
