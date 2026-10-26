import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'core/services/window_geometry.dart';

import 'core/api/api_client.dart';
import 'core/api/server_pool.dart';
import 'core/proxy/proxy_core.dart';
import 'core/proxy/proxy_core_cli.dart';
import 'core/services/account_service.dart';
import 'core/services/app_data_cleaner.dart';
import 'core/services/auth_service.dart';
import 'core/services/app_log.dart';
import 'core/services/autostart.dart';
import 'core/services/crash_logger.dart';
import 'core/services/local_notify.dart';
import 'core/services/network_monitor.dart';
import 'core/services/subscription_scheduler.dart';
import 'core/services/tray_service.dart';
import 'core/services/update_service.dart';
import 'core/services/settings_store.dart';
import 'core/services/single_instance.dart';
import 'core/proxy/system_proxy.dart';
import 'l10n/app_strings.dart';
import 'pages/auth/login_page.dart';
import 'pages/home/home_page.dart';
import 'pages/nodes/nodes_page.dart';
import 'pages/package/package_page.dart';
import 'pages/profile/profile_page.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

/// 全局会话状态
class SessionState extends ChangeNotifier {
  bool loggedIn = false;

  Future<void> restore() async {
    // 「自动登录」开关关闭时，不恢复登录态（见 login_page.setAutoLogin）
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('moneyfly_auto_login') == false) {
      loggedIn = false;
      notifyListeners();
      return;
    }
    final t = await ApiClient.readAccessToken();
    loggedIn = t != null && t.isNotEmpty;
    notifyListeners();
  }

  void setLoggedIn(bool v) {
    loggedIn = v;
    notifyListeners();
  }
}

/// 全局导航 key：会话失效/退出登录时清空路由栈，自动回到登录窗口
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  // Windows 单实例由**原生入口**（windows/runner/main.cpp 的 CreateMutexW）
  // 在创建窗口之前拦截：第二进程连窗口都不会创建就退出。这里不再做 Dart 侧
  // 检查——否则第一个实例会被自己持有的原生 mutex 误判成「已有实例」而自杀。
  WidgetsFlutterBinding.ensureInitialized();
  final isTest = Platform.environment.containsKey('FLUTTER_TEST');
  final isDesktopRuntime = !isTest &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  // ⚠️ 这一段（runApp 之前）**绝不能卡住、也绝不能抛错**：
  // Flutter 的 Windows 模板要等**第一帧渲染完成**才显示窗口
  // （windows/runner/flutter_window.cpp 的 SetNextFrameCallback → Show()），
  // 所以只要这里被挂住或异常抛出，客户看到的就是「装完了打不开、没有任何窗口」，
  // 而进程还活在任务管理器里 —— 正是客服报障最难定位的那种。
  // 因此：单实例守卫加超时兜底，窗口管理器初始化失败也只记日志；
  // 其余启动任务（插件初始化 / 线路池 / 数据清理 / 自启自愈）全部挪到
  // runApp 之后的首帧之后再跑（见 _postLaunchInit），任何一个失败都不影响出窗口。

  // macOS/Linux 没有原生入口层可挂，用排他文件锁补上单实例守卫。
  // 必须**早于**任何系统代理/内核清扫：否则第二个实例的启动巡检已经在动第一个
  // 实例的内核与系统代理了（多开互相打架的源头）。
  if (isDesktopRuntime && !Platform.isWindows) {
    var acquired = true; // 兜底：守卫本身出问题时**放行**（出窗口优先）
    try {
      acquired = await SingleInstance.acquire()
          .timeout(const Duration(seconds: 3), onTimeout: () => true);
    } catch (e) {
      AppLog.error('single instance guard failed (放行): $e');
    }
    if (!acquired) {
      AppLog.log('APP', 'another instance is running, exit this one');
      exit(0);
    }
  }
  // 桌面端窗口管理（关闭=隐藏到托盘，不退出进程）
  if (isDesktopRuntime) {
    try {
      await windowManager.ensureInitialized();
      unawaited(windowManager.setPreventClose(true));
      unawaited(windowManager.setTitle(AppStrings.t('app_name')));
      // 最小尺寸放宽到 340×520：旧值 380×620 在 1024×600 这类小屏 / 高 DPI 缩放的
      // 机器上会超过屏幕可用高度，窗口就没法完整显示（用户看到"界面打不开"）
      unawaited(windowManager.setMinimumSize(const Size(340, 520)));
      // 界面必须出现在**屏幕正中间**（用户明确要求），并把异常尺寸/残留屏外坐标纠正
      try {
        await WindowGeometry.centerOnLaunch();
      } catch (e) {
        AppLog.error('启动居中失败（不阻塞）: $e');
      }
    } catch (e) {
      AppLog.error('windowManager 初始化失败（不阻塞启动）: $e');
    }
  }

  // 先把 UI 起起来 —— 第一帧只依赖上面的最小初始化，不依赖任何网络/文件任务
  runApp(const MoneyFlyApp());
  unawaited(_postLaunchInit(isDesktopRuntime));
}

/// 首帧之后的启动任务：每一个都独立兜底。
/// 顺序保留了原有的语义（UA/设备信息要早于首个 API 请求；线路池要早于首个请求），
/// 但它们不再挡在 runApp 前面 —— 旧实现把它们按 await 串在 runApp 之前，
/// 任何一步抛异常或卡住都会导致「进程在、窗口不出现」。
Future<void> _postLaunchInit(bool isDesktopRuntime) async {
  // UA + 设备信息必须在首个 API 请求前就绪（登录 UA 不再为裸版本号）
  try {
    await UpdateService.instance
        .init()
        .timeout(const Duration(seconds: 10));
  } catch (e) {
    AppLog.error('UpdateService.init 失败（不阻塞启动）: $e');
  }
  // 恢复上次可用的服务器线路（某些地区官网域名被墙时，用户上次切到的备用域名要
  // 延续使用；未切换过则默认主域名）。见 core/api/server_pool.dart。
  try {
    await ServerPool.instance
        .ensureLoaded()
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    AppLog.error('ServerPool.ensureLoaded 失败（用默认主域名继续）: $e');
  }
  // 域名实测排序（不阻塞首帧、失败只记日志）：国内各地 ISP 对各域名的封锁/速度
  // 差别很大，谁快用谁 —— 结果持久化，下次启动直接按它来（见 ServerPool）。
  unawaited(() async {
    try {
      final ranked = await ApiClient.probeDomainLatency();
      if (ranked.isNotEmpty) await ServerPool.instance.applyLatencyRanking(ranked);
    } catch (e) {
      AppLog.error('域名测速排序失败（沿用上次结果）: $e');
    }
  }());
  // 后台静默检查更新：有新版则点亮全局红点（底部「我的」tab / 设置「版本更新」行）
  // 并（默认开启）在后台把匹配本机的安装包预下载好 —— 用户点「立即更新」时无需等待。
  unawaited(() async {
    try {
      final info = await UpdateService.instance.check();
      if (info == null || !info.isNewer) return;
      if (!UpdateService.canInstallInApp) return;
      final s = await SettingsStore.instance.load();
      if (s['autoDownloadUpdatePkg'] != true) return;
      await UpdateService.instance.downloadInstaller(info: info);
    } catch (_) {}
  }());
  // 全新安装检测：卸载残留/数据被清 → 清空旧配置、旧 token、旧缓存，
  // 保证重装后必须重新登录并重新拉取订阅（不沿用旧配置）；版本升级 →
  // 仅清理旧版本拉到的订阅缓存（下次启动强制重拉）。
  try {
    await AppDataCleaner.cleanupOnLaunch()
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    AppLog.error('AppDataCleaner.cleanupOnLaunch 失败（跳过清理）: $e');
  }
  AppLog.log('APP', 'launched v${UpdateInfo.currentVersion}, ${Platform.operatingSystem}');
  // 开机自启自愈：Windows 注册的是 **exe 绝对路径**，换目录安装/手动移动目录、
  // 或被任务管理器清掉后这条会失效 —— 设置里开着但系统里没有就补注册（失败只记
  // 日志，不影响启动）。
  if (isDesktopRuntime) {
    unawaited(() async {
      try {
        final s = await SettingsStore.instance.load();
        await AutostartService.syncOnStartup(
            prefEnabled: s['launchAtStartup'] == true);
      } catch (_) {}
    }());
  }
}

class MoneyFlyApp extends StatefulWidget {
  const MoneyFlyApp({super.key});

  @override
  State<MoneyFlyApp> createState() => _MoneyFlyAppState();
}

class _MoneyFlyAppState extends State<MoneyFlyApp> with WidgetsBindingObserver, WindowListener {
  final _session = SessionState();
  bool _wasLoggedIn = false;

  static bool get _isDesktopRuntime =>
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// 桌面：系统注销/关机的生命周期通道。
  /// Windows runner 在 WM_QUERYENDSESSION/WM_ENDSESSION、macOS runner 在
  /// applicationShouldTerminate 时通过它通知，给最后一次清理机会。
  static const _lifecycleChannel = MethodChannel('top.moneyfly/lifecycle');

  /// 注销/关机前的最后清理：只做最必要的两件事，且带短超时 —— 系统不会等太久。
  /// 用 `restore()`（本进程内 `_applied` 为 true，能精确还原用户原代理），
  /// 与启动巡检的 `clearResidual()` 不同：后者是给「已经死掉的进程」兜底的。
  Future<void> _cleanupBeforeSystemExit() async {
    try {
      await SystemProxyManager.restore().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await ProxyCoreCli.killStaleKernels()
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktopRuntime) {
      windowManager.addListener(this);
      // 窗口可见性自愈（Windows 客服报障：「装完打不开、没有窗口」）：
      // 原生侧已有「首帧 3 秒兜底显示」，但若 Dart 侧某一步把窗口藏了/没显示成功，
      // 这里 4 秒后再确认一次 —— 启动 4 秒内不可能有用户主动「关到托盘」，
      // 所以强制显示不会误伤。失败只记日志。
      _windowWatchdog = Timer(const Duration(seconds: 4), () async {
        try {
          final visible = await windowManager.isVisible();
          if (!visible) {
            AppLog.error('窗口启动 4 秒后仍不可见 → 强制显示（自愈）');
            await WindowGeometry.showAndFocus();
          } else {
            // 可见但可能整块/大半块在屏幕外（旧版本遗留坐标）→ 拉回中间
            await WindowGeometry.ensureOnScreen();
          }
        } catch (e) {
          AppLog.error('窗口可见性自愈失败: $e');
        }
      });
      TrayService.instance.init(
        showWindow: () async {
          // show + 还原 + 屏外自愈 + 置前（老机器上窗口可能停在屏幕外）
          await WindowGeometry.showAndFocus();
        },
        quit: _quitApp,
      );
      // 系统注销/关机钩子：不做的话关机时系统代理会留在 127.0.0.1:<port>
      // 指向已经死掉的端口 → 重启后整机断网，用户只能靠重新打开本 App
      // 触发启动巡检才恢复。
      _lifecycleChannel.setMethodCallHandler((call) async {
        if (call.method == 'systemShutdown') {
          await _cleanupBeforeSystemExit();
          return true;
        }
        return null;
      });
    }
    // 登录态变化 → 启停「定时更新订阅」（登录后每 30 分钟静默拉订阅覆盖旧配置，
    // 登出/会话失效即停）
    _session.addListener(_onSessionChanged);
    _session.restore();
    // 启动时应用持久化设置（自动测速 / 断线重连 / 默认模式）+ 恢复主题
    SettingsStore.instance
        .load()
        .then(ConnectionController.instance.applySettings)
        .catchError((_) {});
    ThemeController.instance.restore();
    // 恢复用户语言(设置页选择/首次按设备语言),否则每次启动都回到中文
    AppStrings.restore().then((_) {
      // 通知 UI 用恢复后的语言重建(不重复持久化)
      return LocaleController.instance.setLang(AppStrings.lang, persist: false);
    }).catchError((_) {});
    // 崩溃日志（设置开关控制）
    CrashLogger.init();
    // 本地通知初始化（到期提醒 / 连接异常）
    LocalNotify.instance.init();
    // 启动巡检(桌面)：先收残留内核，再判系统代理。
    //
    // 顺序不能反：残留判定用「本地端口是否还有进程监听」区分「死掉的残留」
    // 与「别的实例正在用的活代理」（见 SystemProxyManager.clearResidual）。
    // 若先判代理（此时被强杀留下的孤儿内核还活着、端口在听 → 保留代理），
    // 紧接着把它当孤儿收掉，系统代理就指向了一个刚被我们杀死的端口 ——
    // 用户重启 App 反而整机断网。先收内核，端口自然变死，代理才会被判为残留清掉。
    if (Platform.isMacOS || Platform.isWindows) {
      unawaited(() async {
        // 清扫上次残留的内核进程：占着 2080/9090 与 cache.db 锁会让
        // 之后每次连接都 bind 失败（表现为「退出后重开连不上」）
        try {
          await ProxyCoreCli.killStaleKernels();
        } catch (_) {}
        // 清掉指向死端口的残留系统代理（不能走 restore()：新进程里
        // _applied/_original 恒为空，restore 会直接 return 什么都不做，
        // 导致整机断网却无法自愈）
        try {
          final s = await SettingsStore.instance.load();
          final port =
              (s['localPort'] as num?)?.toInt() ?? SystemProxyManager.defaultPort;
          await SystemProxyManager.clearResidual(port: port);
        } catch (_) {}
      }());
    }
    // 网络变化监听（WiFi↔蜂窝切换自动重连）
    NetworkMonitor.instance.start();
    // 桌面：接管 SIGTERM/SIGINT（注销、kill、终端 Ctrl+C）→ 也走正常退出清理。
    // 否则进程被直接结束，系统代理会残留指向死端口（下次启动虽有巡检兜底，
    // 但用户在那之前是完全断网的状态）。
    if (Platform.isMacOS || Platform.isLinux) {
      for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
        try {
          sig.watch().listen((_) => unawaited(_quitApp()));
        } catch (_) {}
      }
    }
    // 会话失效（refresh 失败）→ 清空路由栈强制回登录页
    // （push 在栈上的设置/订单等页面会残留盖住登录页，需先 pop 到根）
    ApiClient.instance.onSessionExpired(() {
      AuthService.instance.logout();
      rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      _session.setLoggedIn(false);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktopRuntime) {
      _windowWatchdog?.cancel();
      windowManager.removeListener(this);
    }
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 防重复退出/关闭处理
  bool _quitting = false;

  /// 窗口可见性自愈定时器（桌面端）：见 initState 里的说明
  Timer? _windowWatchdog;

  /// 真正退出：先断开连接（停内核 + 恢复系统代理，避免残留内核占端口/
  /// cache 锁导致下次启动失败），再关闭窗口并结束进程。
  Future<void> _quitApp() async {
    if (_quitting) return;
    _quitting = true;
    try {
      final c = ConnectionController.instance;
      if (c.status != ConnStatus.disconnected) {
        await c.disconnect();
      }
    } catch (_) {}
    // 兜底清扫内核子进程：disconnect 在「状态已是 disconnected」时会被跳过
    // （例如内核崩溃后自动重连耗尽），此时内核可能仍在跑 → 残留占端口/缓存锁，
    // 也会让系统代理指向一个已死进程。这里无条件再扫一遍。
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      try {
        await ProxyCoreCli.killStaleKernels();
      } catch (_) {}
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {}
    // 兜底：某些平台 close 只关窗口不结束进程
    exit(0);
  }

  @override
  void onWindowClose() async {
    // 点右上角 X（macOS 红点 / Windows ×）→ 按记忆行为：最小化 / 退出 / 每次询问。
    // 注意：本 State 在 MaterialApp 之上，绝不能用自己的 context 弹窗
    // （Navigator.of 向上找不到 Navigator → showDialog 抛异常 → 旧代码无
    // 兜底 → 弹窗从未出现，而窗口又被 preventClose 拦截 = 「点 X 没反应」）。
    // 必须用 rootNavigatorKey.currentContext（MaterialApp 的 Navigator）。
    if (!mounted || _quitting) return;
    AppLog.log('APP', 'window close requested');
    // 已记住的关闭行为直接执行，不再询问
    final closeAction = await _loadCloseAction();
    if (!mounted || _quitting) return;
    if (closeAction == 'hide') {
      try {
        await windowManager.hide();
      } catch (_) {}
      return;
    }
    if (closeAction == 'quit') {
      await _quitApp();
      return;
    }
    try {
      // 启动极早期(路由未就绪)点 X：等一帧让 Navigator 可用
      if (rootNavigatorKey.currentContext == null) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted || _quitting) return;
      }
      // 取完立即使用(同一同步段,无跨 async gap)
      final navCtx = rootNavigatorKey.currentContext;
      if (navCtx == null || !navCtx.mounted) {
        // 没有可用的 Navigator(异常状态)：兜底最小化，避免"点了没反应"
        AppLog.error('onWindowClose: navigator not ready, hide to tray');
        await windowManager.hide();
        return;
      }
      var remember = false;
      final act = await showDialog<String>(
        context: navCtx,
        barrierDismissible: true,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            backgroundColor: MFColors.card2,
            title: Text(AppStrings.t('close_ask_title'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppStrings.t('close_ask_body'),
                    style: TextStyle(
                        fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
                CheckboxListTile(
                  value: remember,
                  onChanged: (v) => setState(() => remember = v ?? false),
                  title: Text(AppStrings.t('remember_choice'),
                      style: TextStyle(fontSize: 12.5, color: MFColors.txt2)),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(AppStrings.t('cancel'))),
              TextButton(
                onPressed: () {
                  if (remember) {
                    unawaited(SettingsStore.instance
                        .update((s) => s['closeAction'] = 'hide'));
                  }
                  Navigator.pop(ctx, 'hide');
                },
                child: Text(AppStrings.t('minimize_tray_btn'),
                    style: TextStyle(color: MFColors.txt)),
              ),
              TextButton(
                onPressed: () {
                  if (remember) {
                    unawaited(SettingsStore.instance
                        .update((s) => s['closeAction'] = 'quit'));
                  }
                  Navigator.pop(ctx, 'quit');
                },
                child: Text(AppStrings.t('quit_app_btn'),
                    style: TextStyle(color: MFColors.red)),
              ),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (act == 'hide') {
        // 最小化到托盘：常驻后台（内核/代理保持连接）
        await windowManager.hide();
      } else if (act == 'quit') {
        await _quitApp();
      }
      // act == null（点弹窗外/取消）→ 保持窗口，什么都不做
    } catch (e) {
      // 弹窗失败兜底：最小化到托盘而非"点了没反应"
      AppLog.error('onWindowClose dialog failed: $e');
      try {
        await windowManager.hide();
      } catch (_) {}
    }
  }

  Future<String> _loadCloseAction() async {
    try {
      final s = await SettingsStore.instance.load();
      final v = s['closeAction']?.toString() ?? 'ask';
      return (v == 'hide' || v == 'quit') ? v : 'ask';
    } catch (_) {
      return 'ask';
    }
  }

  void _onSessionChanged() {
    final v = _session.loggedIn;
    if (v == _wasLoggedIn) return;
    _wasLoggedIn = v;
    if (v) {
      // 登录后启动「每 30 分钟静默刷新订阅」：重判账号状态(到期/禁用/设备满)
      // + 覆盖本地订阅缓存，运行期间节点/线路保持最新、受限即时生效
      SubscriptionScheduler.instance.start();
    } else {
      // 登出停掉定时刷新，避免残留定时器
      SubscriptionScheduler.instance.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台自动补一次静默刷新(距上次成功 ≥10 分钟才拉,避免 JWT 抖动)
    if (state == AppLifecycleState.resumed) {
      SubscriptionScheduler.instance.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _session),
        ChangeNotifierProvider.value(value: ConnectionController.instance),
        ChangeNotifierProvider.value(value: ThemeController.instance),
        ChangeNotifierProvider.value(value: LocaleController.instance),
        // 账号可用状态（到期/设备满/禁用）——首页横幅、连接门禁、我的页共用
        ChangeNotifierProvider.value(value: AccountService.instance),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeCtrl, _) =>
            Consumer<LocaleController>(
          builder: (context, locale, _) => MaterialApp(
            title: AppStrings.t('app_name'),
            debugShowCheckedModeBanner: false,
            navigatorKey: rootNavigatorKey,
            theme: buildMoneyFlyTheme(brightness: Brightness.light),
            darkTheme: buildMoneyFlyTheme(brightness: Brightness.dark),
            themeMode: themeCtrl.mode,
            locale: locale.lang == 'en' ? const Locale('en') : const Locale('zh'),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('zh'), Locale('en')],
            home: RootShell(),
          ),
        ),
      ),
    );
  }
}

/// 未登录 → 登录页；已登录 → 主壳
class RootShell extends StatelessWidget {
  const RootShell({super.key});

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.select((SessionState s) => s.loggedIn);
    return loggedIn ? const MainShell() : const LoginPage();
  }
}

/// 全局主标签索引（供首页/我的等页面一键跳转「充值」tab）
final ValueNotifier<int> mainTabIndex = ValueNotifier<int>(0);

/// 主导航四个目的地（首页/节点/套餐/我的）——
/// 宽屏 NavigationRail 与窄屏 BottomNavigationBar 共用同一份定义，
/// 保证两套导航文案/图标一致；label 复用现有 AppStrings key
/// （home / nodes_title / purchase_title / profile_title），无需新增文案。
typedef _MainNavEntry = ({String labelKey, IconData icon, IconData activeIcon});

const List<_MainNavEntry> _mainNavEntries = [
  (labelKey: 'home', icon: Icons.home_outlined, activeIcon: Icons.home),
  (labelKey: 'nodes_title', icon: Icons.dns_outlined, activeIcon: Icons.dns),
  (labelKey: 'purchase_title', icon: Icons.payments_outlined, activeIcon: Icons.payments),
  (labelKey: 'profile_title', icon: Icons.person_outline, activeIcon: Icons.person),
];

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  /// 已访问过的 tab（懒构建 + 保活：切 tab 不重建、不动画闪烁）
  final Set<int> _visited = {0};

  static const _pageCount = 4;
  late final _pages = <Widget>[
    const HomePage(),
    const NodesPage(),
    const PackagePage(),
    const ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    mainTabIndex.addListener(_onExternalTabSwitch);
  }

  @override
  void dispose() {
    mainTabIndex.removeListener(_onExternalTabSwitch);
    super.dispose();
  }

  void _onExternalTabSwitch() {
    final i = mainTabIndex.value;
    if (i != _index && i >= 0 && i < _pageCount) {
      setState(() {
        _index = i;
        _visited.add(i);
      });
    }
  }

  void _onTap(int i) {
    mainTabIndex.value = i;
    setState(() {
      _index = i;
      _visited.add(i);
    });
  }

  /// 宽屏(≥840)切换为左侧 NavigationRail 的临界宽度；窗口默认尺寸不改，
  /// 仅按当前布局宽度响应（窗口管理器只设了最小 380×620）。
  static const double _railBreakpoint = 840;

  @override
  Widget build(BuildContext context) {
    // 响应式导航：宽屏 → 左侧 NavigationRail；窄屏 → 保持底部 BottomNavigationBar。
    // 两套导航共用 _index/_visited/_pages 与 _onTap/IndexedStack 保活逻辑，
    // 页面状态不因布局切换而重建；mainTabIndex 外部跳转（mainTabIndex.value = 2）
    // 依旧通过 _onExternalTabSwitch 生效，与布局无关。
    final wide = MediaQuery.sizeOf(context).width >= _railBreakpoint;
    final tabBody = _buildTabBody();
    return Scaffold(
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildNavigationRail(),
                Expanded(child: tabBody),
              ],
            )
          : tabBody,
      bottomNavigationBar: wide ? null : _buildBottomNavigationBar(),
    );
  }

  /// 主内容区（IndexedStack 保活已访问页面；未访问的用占位避免登录瞬间并发
  /// 拉取；TickerMode 停用非活动 Tab 的动画 ticker → 省电省 CPU）。
  /// 宽/窄两种导航共用这一份内容，切到宽屏时由 Expanded 铺满 rail 右侧。
  Widget _buildTabBody() {
    return IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < _pageCount; i++)
          _visited.contains(i)
              ? TickerMode(
                  enabled: i == _index,
                  child: _pages[i],
                )
              : const SizedBox.shrink(),
      ],
    );
  }

  /// tab 图标：有新版时右上角挂红点角标
  Widget _tabIcon(IconData icon, double size, bool showDot) {
    final i = Icon(icon, size: size);
    if (!showDot) return i;
    return Stack(clipBehavior: Clip.none, children: [
      i,
      Positioned(right: -2, top: -2, child: RedDot(size: 7)),
    ]);
  }

  /// 窄屏底部导航（原有外观与文案保持不变；「我的」tab 有新版时显示红点）
  Widget _buildBottomNavigationBar() {
    return ValueListenableBuilder<bool>(
      valueListenable: UpdateService.hasUpdate,
      builder: (context, hasUpdate, _) => Container(
        decoration: BoxDecoration(
          color: MFColors.bg,
          border: Border(top: BorderSide(color: MFColors.line)),
        ),
        child: SafeArea(
          top: false,
          child: BottomNavigationBar(
            currentIndex: _index,
            onTap: _onTap,
            items: [
              for (var i = 0; i < _mainNavEntries.length; i++)
                BottomNavigationBarItem(
                  icon: _tabIcon(
                      _mainNavEntries[i].icon, 22, i == 3 && hasUpdate),
                  activeIcon: _tabIcon(
                      _mainNavEntries[i].activeIcon, 22, i == 3 && hasUpdate),
                  label: AppStrings.t(_mainNavEntries[i].labelKey),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 宽屏左侧 NavigationRail：4 个 destination 与底部导航同源（图标/文案一致），
  /// 配色沿用底部导航语义（选中 brandLight / 未选中 txt3）。
  Widget _buildNavigationRail() {
    return ValueListenableBuilder<bool>(
      valueListenable: UpdateService.hasUpdate,
      builder: (context, hasUpdate, _) => Container(
        decoration: BoxDecoration(
          color: MFColors.bg,
          border: Border(right: BorderSide(color: MFColors.line)),
        ),
        child: NavigationRail(
          backgroundColor: Colors.transparent,
          selectedIndex: _index,
          onDestinationSelected: _onTap,
          labelType: NavigationRailLabelType.all,
          indicatorColor: MFColors.brand.withValues(alpha: .12),
          selectedIconTheme: IconThemeData(color: MFColors.brandLight),
          unselectedIconTheme: IconThemeData(color: MFColors.txt3),
          selectedLabelTextStyle: TextStyle(
              color: MFColors.brandLight, fontSize: 12, fontWeight: FontWeight.w500),
          unselectedLabelTextStyle:
              TextStyle(color: MFColors.txt3, fontSize: 12),
          destinations: [
            for (var i = 0; i < _mainNavEntries.length; i++)
              NavigationRailDestination(
                icon: _tabIcon(
                    _mainNavEntries[i].icon, 24, i == 3 && hasUpdate),
                selectedIcon: _tabIcon(
                    _mainNavEntries[i].activeIcon, 24, i == 3 && hasUpdate),
                label: Text(AppStrings.t(_mainNavEntries[i].labelKey)),
              ),
          ],
        ),
      ),
    );
  }
}
