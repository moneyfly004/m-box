import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/services/win_single_instance.dart';

/// Windows 单实例守护的平台安全测试：
/// - 非 Windows / 测试环境必须静默返回 false（不拦截、不加载 DLL、不退出），
///   防止未来重构把单实例逻辑带到 macOS/CI 造成误杀；
/// - ensure() 在本平台不应抛异常。
/// （真实单实例行为需在 Windows 上双击验证：第二个进程应退出并唤醒首进程。）
void main() {
  test('非 Windows 平台 ensure() 返回 false 且不抛', () {
    // 测试运行于 macOS/Linux CI：Platform.isWindows=false → 直接放行
    bool result;
    try {
      result = WinSingleInstance.ensure();
    } catch (e) {
      fail('ensure() 不应抛异常: $e');
    }
    expect(result, isFalse,
        reason: '非 Windows 平台不得判定"已有实例"（防止误杀正常启动）');
  });
}
