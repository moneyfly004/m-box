#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <stdio.h>
#include <string>
#include <wchar.h>
#include <cwctype>

#include "flutter_window.h"
#include "utils.h"

// ---- 启动诊断日志 ----
// 为什么需要：Windows 客户报「装完打不开、没有窗口」时，进程往往还在任务管理器里，
// 而 Flutter 的 Dart 日志要等引擎起来才会写 —— 恰恰是引擎/首帧没起来时最需要日志。
// 这里在原生入口记几条关键事实，客服拿到 %LOCALAPPDATA%\MoneyFly\boot.log 就能定性：
//   mutex-exists / window-created / frame-first / fallback-shown / create-failed
static void BootLog(const wchar_t* msg) {
  wchar_t dir[MAX_PATH] = {0};
  DWORD n = ::GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    ::GetTempPathW(MAX_PATH, dir);
  } else {
    ::CreateDirectoryW((std::wstring(dir) + L"\\MoneyFly").c_str(), nullptr);
    wcscat_s(dir, L"\\MoneyFly");
  }
  std::wstring path = std::wstring(dir) + L"\\boot.log";
  HANDLE f = ::CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME st;
  ::GetLocalTime(&st);
  wchar_t line[512] = {0};
  swprintf_s(line, L"[%04d-%02d-%02d %02d:%02d:%02d] %s\r\n", st.wYear,
             st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, msg);
  DWORD written = 0;
  ::WriteFile(f, line, (DWORD)(wcslen(line) * sizeof(wchar_t)), &written, nullptr);
  ::CloseHandle(f);
}


// ---- 窗口几何：按「显示器工作区」居中 + 自适应大小（DPI 正确的逻辑像素） ----
//
// 旧实现（客户实测「装好了、托盘有图标、界面就是打不开」的真因）：
//   origin/size 用 GetSystemMetrics(SM_CXSCREEN/SM_CYSCREEN)（**主屏物理像素**）计算，
//   而 Win32Window::Create 把这两个值当成**逻辑像素**（内部再乘 DPI 缩放）：
//     · 1920×1080 @150%：420×780 逻辑 → 物理 630×1170（比屏幕还高），底部内容全在屏外
//     · 1366×768  @125%：y=(768-780)/2=-6 逻辑 → 物理 -7，标题栏跑到屏幕上方之外，
//       窗口只露出一部分且拖不回来 → 用户结论就是"打不开界面"，只看到托盘图标
// 现在：取光标所在显示器的工作区（去掉任务栏），换算逻辑像素，尺寸按工作区收缩后居中。
struct MFWindowGeometry {
  int x;
  int y;
  int w;
  int h;
};

static MFWindowGeometry ComputeWindowGeometry(int target_w, int target_h) {
  POINT cursor = {0, 0};
  ::GetCursorPos(&cursor);
  HMONITOR mon = ::MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO mi = {0};
  mi.cbSize = sizeof(mi);
  if (mon == nullptr || !::GetMonitorInfoW(mon, &mi)) {
    const int sw = ::GetSystemMetrics(SM_CXSCREEN);
    const int sh = ::GetSystemMetrics(SM_CYSCREEN);
    int w = target_w < sw - 40 ? target_w : (sw > 520 ? sw - 40 : sw);
    int h = target_h < sh - 64 ? target_h : (sh > 640 ? sh - 64 : sh);
    MFWindowGeometry g = {(sw - w) / 2, (sh - h) / 2, w, h};
    return g;
  }
  const UINT dpi = FlutterDesktopGetDpiForMonitor(mon);
  const double scale = dpi > 0 ? (dpi / 96.0) : 1.0;
  const int work_w_phys = mi.rcWork.right - mi.rcWork.left;
  const int work_h_phys = mi.rcWork.bottom - mi.rcWork.top;
  const int work_w = static_cast<int>(work_w_phys / scale);
  const int work_h = static_cast<int>(work_h_phys / scale);
  const int margin = 16;
  int w = target_w;
  int h = target_h;
  if (w > work_w - margin * 2) w = work_w - margin * 2;
  if (h > work_h - margin * 2) h = work_h - margin * 2;
  if (w < 320) w = work_w > 320 ? 320 : work_w;
  if (h < 480) h = work_h > 480 ? 480 : work_h;
  int x = static_cast<int>(mi.rcWork.left / scale) + (work_w - w) / 2;
  int y = static_cast<int>(mi.rcWork.top / scale) + (work_h - h) / 2;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  MFWindowGeometry g = {x, y, w, h};
  return g;
}

// 把已经存在（可能是旧版本留下的）窗口挪回可见区域：窗口尺寸超过工作区、
// 或标题栏跑到屏幕外时重新居中 —— 客户"再点一次图标"就能自愈老机器。
static bool EnsureWindowOnScreen(HWND hwnd) {
  if (hwnd == nullptr || !::IsWindow(hwnd)) return false;
  RECT wr = {0};
  if (!::GetWindowRect(hwnd, &wr)) return false;
  HMONITOR mon = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {0};
  mi.cbSize = sizeof(mi);
  if (mon == nullptr || !::GetMonitorInfoW(mon, &mi)) return false;
  const RECT work = mi.rcWork;
  const int win_w = wr.right - wr.left;
  const int win_h = wr.bottom - wr.top;
  const int work_w = work.right - work.left;
  const int work_h = work.bottom - work.top;
  const bool title_bar_reachable =
      (wr.top >= work.top - 4) && (wr.top <= work.bottom - 48);
  const bool size_ok = win_w <= work_w + 8 && win_h <= work_h + 8;
  const bool horizontally_visible =
      wr.right > work.left + 80 && wr.left < work.right - 80;
  if (title_bar_reachable && size_ok && horizontally_visible) return false;
  int w = win_w > work_w - 32 ? work_w - 32 : win_w;
  int h = win_h > work_h - 32 ? work_h - 32 : win_h;
  if (w < 320) w = 320;
  if (h < 480) h = 480;
  const int x = work.left + (work_w - w) / 2;
  const int y = work.top + (work_h - h) / 2;
  ::SetWindowPos(hwnd, nullptr, x, y, w, h,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  BootLog(L"window off-screen -> recentered");
  return true;
}

// 在当前会话里按标题**包含** "moneyfly" 查找主窗口（隐藏窗口也能枚举到）。
// 为什么不用 FindWindowW：它按精确标题匹配且只找当前桌面，标题带后缀 /
// 虚拟桌面切换时会漏掉，表现为"再点一次图标没反应"。
static BOOL CALLBACK FindMoneyFlyWindowProc(HWND hwnd, LPARAM lparam) {
  wchar_t title[256] = {0};
  ::GetWindowTextW(hwnd, title, 256);
  if (title[0] == 0) return TRUE;
  std::wstring t(title);
  for (size_t i = 0; i < t.size(); ++i) t[i] = (wchar_t)towlower(t[i]);
  if (t.find(L"moneyfly") == std::wstring::npos) return TRUE;
  *reinterpret_cast<HWND*>(lparam) = hwnd;
  return FALSE;  // 找到即停
}

static HWND FindExistingMainWindow() {
  HWND exact = ::FindWindowW(nullptr, L"MoneyFly");
  if (exact != nullptr) return exact;
  HWND found = nullptr;
  ::EnumWindows(FindMoneyFlyWindowProc, reinterpret_cast<LPARAM>(&found));
  return found;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // ---- 单实例：同一会话内只允许一个进程 ----
  // 必须在创建任何窗口之前拦截：否则重复双击会产生多个窗口/多个托盘/多个内核，
  // 各自管理系统代理与内核，互相冲突（状态被别的进程覆盖）。
  // 已有一个实例 → 唤醒它的窗口（可能最小化到托盘），本进程立即退出。
  {
    HANDLE mutex =
        ::CreateMutexW(nullptr, FALSE, L"Local\\MoneyFly_SingleInstance");
    if (mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
      // 已有实例：唤醒它的窗口（可能被最小化到托盘或被我方 hide() 隐藏）。
      // 旧实现只 FindWindow 一次就退出：若那一刻对方窗口还没创建出来（开机自启
      // 与用户双击几乎同时），或者因权限/消息过滤没被唤醒，客户看到的就是
      // 「双击图标毫无反应」—— 现在重试几秒，仍找不到就明确弹一句提示。
      HWND hwnd = nullptr;
      for (int i = 0; i < 20 && hwnd == nullptr; ++i) {
        hwnd = FindExistingMainWindow();
        if (hwnd == nullptr) ::Sleep(250);
      }
      if (hwnd != nullptr) {
        ::ShowWindow(hwnd, SW_SHOWNORMAL);
        ::ShowWindow(hwnd, SW_RESTORE);
        // 老机器上窗口可能被旧版本摆到屏幕外：先挪回可见区域再置前
        EnsureWindowOnScreen(hwnd);
        if (!::SetForegroundWindow(hwnd)) {
          // 后台进程调 SetForegroundWindow 常被系统拒绝（前台锁）
          ::AllowSetForegroundWindow(ASFW_ANY);
          ::SetForegroundWindow(hwnd);
          ::FlashWindow(hwnd, TRUE);
        }
        BootLog(L"second-instance: existing window restored");
      } else {
        BootLog(L"second-instance: mutex held but window not found");
        ::MessageBoxW(nullptr,
                      L"MoneyFly 已在运行，但没能把它的窗口调到前台。\n\n"
                      L"请检查任务栏右下角的托盘区（可能在「隐藏的图标」里），"
                      L"双击 MoneyFly 图标即可显示窗口；若托盘里也没有，"
                      L"请在任务管理器结束 moneyfly.exe 后重新打开。",
                      L"MoneyFly", MB_OK | MB_ICONINFORMATION);
      }
      return 0;
    }
    // mutex 句柄有意不关闭：进程存活期间持有命名互斥量，退出时系统自动释放，
    // 崩溃/被杀也不会残留「假锁」。
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // 竖版窗口（420×780），与手机端比例一致；
  // 位置/尺寸按「当前显示器工作区」计算，保证**一定在屏幕正中间且完整可见**
  // （DPI 换算见 ComputeWindowGeometry 的注释）
  MFWindowGeometry geo = ComputeWindowGeometry(420, 780);
  {
    wchar_t glog[256] = {0};
    swprintf_s(glog, L"geometry x=%d y=%d w=%d h=%d", geo.x, geo.y, geo.w, geo.h);
    BootLog(glog);
  }
  Win32Window::Size size(geo.w, geo.h);
  Win32Window::Point origin(geo.x, geo.y);
  if (!window.Create(L"MoneyFly", origin, size)) {
    BootLog(L"window create failed");
    ::MessageBoxW(nullptr,
                  L"MoneyFly 启动失败：无法创建窗口。\n\n"
                  L"常见原因：显卡驱动异常 / 远程桌面会话 / 安全软件拦截。\n"
                  L"诊断日志：%LOCALAPPDATA%\\MoneyFly\\boot.log",
                  L"MoneyFly", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  BootLog(L"window created");

  // ---- 首帧兜底：保证「一定有窗口」 ----
  // Flutter 的 Windows 模板只在**第一帧渲染完成**后才 Show 窗口
  // （flutter_window.cpp 的 SetNextFrameCallback → Show()）。因此只要首帧出不来
  // —— 老显卡/驱动、远程桌面、虚拟机、或 Dart 侧 runApp 之前被卡住 ——
  // 客户看到的就是「装完了但没有任何窗口」，而进程还活着。这里 3 秒后强制显示，
  // 让用户至少能看到界面（也便于判断是渲染问题还是启动卡住）。
  constexpr UINT_PTR kFallbackShowTimer = 0x4D46;
  HWND hwnd = window.GetHandle();
  if (hwnd != nullptr) {
    ::SetTimer(hwnd, kFallbackShowTimer, 3000, nullptr);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    if (msg.message == WM_TIMER && msg.wParam == kFallbackShowTimer) {
      ::KillTimer(msg.hwnd, kFallbackShowTimer);
      if (!::IsWindowVisible(msg.hwnd)) {
        BootLog(L"first frame late/missing: fallback show");
        EnsureWindowOnScreen(msg.hwnd);
        ::ShowWindow(msg.hwnd, SW_SHOWNORMAL);
      } else {
        BootLog(L"first frame ok (window shown by Flutter)");
      }
      continue;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
