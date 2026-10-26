import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows 单实例守护。
///
/// 问题：连续多次双击/重复启动安装版时会产生多个进程（各自带托盘/内核/
/// 系统代理管理，互相冲突）。解法：
/// 1. 命名互斥量 `CreateMutexW` 检测是否已有实例在运行；
/// 2. 已有时 → 尽力激活已有窗口（FindWindowW + ShowWindow(SW_RESTORE) +
///    SetForegroundWindow），随后本进程立即退出 —— 只保留一个进程，
///    且重复双击会把最小化到托盘的窗口重新唤出。
///
/// 说明：mutex 句柄由进程持有到退出（不 CloseHandle），进程结束时由系统
/// 自动释放；命名对象是内核对象，崩溃/被杀后自动清理，不会残留"假锁"。
class WinSingleInstance {
  WinSingleInstance._();

  /// 命名互斥量名（不带前缀 = Local 会话命名空间，同桌面重复启动即命中；
  /// 不同 Windows 会话互不影响，符合单用户语义）
  static const _mutexName = r'Local\MBox_SingleInstance';
  static const _errorAlreadyExists = 183; // ERROR_ALREADY_EXISTS

  static bool get _enabled =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  /// 返回 true = 已有实例在运行（已尽力唤醒其窗口），调用方应立即退出进程。
  static bool ensure() {
    if (!_enabled) return false;
    try {
      final name = _mutexName.toNativeUtf16();
      // 句柄不 CloseHandle：进程生命周期内持有命名 mutex（进程退出时系统
      // 自动释放，不会残留"假锁"）；Dart FFI 指针无自动回收，安全。
      final h = _Kernel32.createMutexW(nullptr, 0, name);
      malloc.free(name);
      if (h == nullptr) return false; // 创建失败不拦截，避免误判
      final err = _Kernel32.getLastError();
      if (err == _errorAlreadyExists) {
        _activateExistingWindow();
        return true;
      }
      return false;
    } catch (_) {
      return false; // FFI 异常时不拦截启动（宁可双开也不误杀）
    }
  }

  /// 唤醒已最小化/隐藏到托盘的既有窗口（尽力而为，失败不影响退出）
  static void _activateExistingWindow() {
    try {
      final title = 'MBox'.toNativeUtf16();
      final hwnd = _User32.findWindowW(nullptr, title);
      malloc.free(title);
      if (hwnd == nullptr) return;
      _User32.showWindow(hwnd, 9 /* SW_RESTORE */);
      _User32.setForegroundWindow(hwnd);
    } catch (_) {}
  }
}

/// kernel32.dll 绑定（惰性单例加载）
final class _Kernel32 {
  _Kernel32._();
  static final DynamicLibrary _lib = DynamicLibrary.open('kernel32.dll');

  static final createMutexW = _lib
      .lookup<
          NativeFunction<Pointer<Void> Function(
              Pointer<Void>, Uint32, Pointer<Utf16>)>>('CreateMutexW')
      .asFunction<Pointer<Void> Function(Pointer<Void>, int, Pointer<Utf16>)>();

  static final getLastError = _lib
      .lookup<NativeFunction<Int32 Function()>>('GetLastError')
      .asFunction<int Function()>();
}

/// user32.dll 绑定
final class _User32 {
  _User32._();
  static final DynamicLibrary _lib = DynamicLibrary.open('user32.dll');

  static final findWindowW = _lib
      .lookup<
          NativeFunction<
              Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>)>>(
      'FindWindowW')
      .asFunction<Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>)>();

  static final showWindow = _lib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'ShowWindow')
      .asFunction<int Function(Pointer<Void>, int)>();

  static final setForegroundWindow = _lib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'SetForegroundWindow')
      .asFunction<int Function(Pointer<Void>)>();
}
