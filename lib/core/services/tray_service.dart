import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../l10n/app_strings.dart';
import '../models/models.dart';
import '../proxy/proxy_core.dart';

/// 桌面系统托盘（macOS/Windows）：
/// - 连接/断开（显示当前节点）
/// - 模式快捷切换（智能/全局）
/// - 国家/地区快速切换（前 8 个热门国家，点击切到该国最优/首个在线节点）
/// - 显示窗口 / 退出
class TrayService with TrayListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _initialized = false;
  void Function()? onShowWindow;
  void Function()? onQuit;

  Future<void> init({void Function()? showWindow, void Function()? quit}) async {
    if (_initialized || kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    onShowWindow = showWindow;
    onQuit = quit;
    trayManager.addListener(this);
    await trayManager.setIcon(_iconPath());
    await trayManager.setToolTip('MBox');
    await _updateMenu();
    _initialized = true;
    ConnectionController.instance.addListener(_onStateChanged);
  }

  /// 托盘图标路径（相对 assets）：
  /// - Windows：tray_manager 底层用 LoadImage(IMAGE_ICON) 从文件加载，只支持
  ///   .ico —— PNG 会加载失败返回 NULL，托盘图标表现为「一片空白」；
  /// - macOS：插件把图标字节转 base64 交给 NSImage，PNG 可用。
  String _iconPath() =>
      Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png';

  void _onStateChanged() => _updateMenu();

  Future<void> _updateMenu() async {
    final ctrl = ConnectionController.instance;
    final connected = ctrl.status == ConnStatus.connected;
    final node = ctrl.current?.tag ?? '';

    // 模式子菜单（当前模式前加 ✓）
    final smart = ctrl.smartMode;
    final modeItems = <MenuItem>[
      MenuItem(
          label: '${smart ? '✓ ' : '   '}${AppStrings.t('smart_mode')}',
          key: 'mode:smart'),
      MenuItem(
          label: '${!smart ? '✓ ' : '   '}${AppStrings.t('global_mode')}',
          key: 'mode:global'),
    ];

    // 国家子菜单：按常用顺序取「前 8 个有节点的国家」
    final countryCodes = <String>[
      for (final code in ProxyNode.countryOrder)
        if (ctrl.nodes.any(
            (n) => (n.countryCode?.toUpperCase() ?? 'XX') == code)) code,
    ];
    final countryItems = <MenuItem>[
      for (final code in countryCodes.take(8))
        MenuItem(
          label:
              '${ProxyNode.flagEmoji(code)} ${ProxyNode.countryNames[code] ?? code}',
          key: 'country:$code',
        ),
    ];
    if (countryItems.isEmpty) {
      countryItems.add(MenuItem(
          label: AppStrings.t('no_available_nodes'), key: 'country:none', disabled: true));
    }

    final items = <MenuItem>[
      if (connected)
        MenuItem(label: '${AppStrings.t('disconnect')} ($node)', key: 'toggle')
      else
        MenuItem(label: AppStrings.t('connect'), key: 'toggle'),
      MenuItem.separator(),
      MenuItem.submenu(
          label: AppStrings.t('tray_mode'), submenu: Menu(items: modeItems)),
      MenuItem.submenu(
          label: AppStrings.t('tray_country'),
          submenu: Menu(items: countryItems)),
      MenuItem.separator(),
      MenuItem(label: AppStrings.t('show_window'), key: 'show'),
      MenuItem.separator(),
      MenuItem(label: AppStrings.t('quit'), key: 'quit'),
    ];
    await trayManager.setContextMenu(Menu(items: items));
  }

  @override
  void onTrayIconMouseDown() => onShowWindow?.call();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final ctrl = ConnectionController.instance;
    final key = menuItem.key ?? '';
    if (key == 'mode:smart') {
      if (!ctrl.smartMode) unawaitedSafe(ctrl.toggleMode(true));
      return;
    }
    if (key == 'mode:global') {
      if (ctrl.smartMode) unawaitedSafe(ctrl.toggleMode(false));
      return;
    }
    if (key.startsWith('country:')) {
      final code = key.substring('country:'.length);
      // switchCountry：锁定国家（该国范围内自动选最优，允许换节点），
      // 同时解除节点固定 —— 与首页点国家格子的语义完全一致
      unawaitedSafe(ctrl.switchCountry(code));
      return;
    }
    switch (key) {
      case 'toggle':
        // 状态守卫(与首页 _toggleConnect 一致):断开中不允许再启停交错 ——
        // 否则旧内核 stop 的 /shutdown 可能误关刚就绪的新内核。
        // 但「连接中/重连中」从托盘点按应当**取消**（等同首页的「取消连接」）：
        // 旧实现在这些状态静默 return，用户从托盘根本停不下来，观感就是
        // 「明明点了关，它又自己连上了」。
        final s = ctrl.status;
        if (s == ConnStatus.disconnecting || ctrl.switchingMode) {
          return;
        }
        if (s == ConnStatus.connecting ||
            s == ConnStatus.testing ||
            s == ConnStatus.reconnecting) {
          unawaitedSafe(ctrl.disconnect());
          return;
        }
        if (s == ConnStatus.connected) {
          unawaitedSafe(ctrl.disconnect());
        } else {
          unawaitedSafe(ctrl.connect());
        }
      case 'show':
        onShowWindow?.call();
      case 'quit':
        onQuit?.call();
    }
  }

  void unawaitedSafe(Future<void> f) => f.catchError((_) {});

  void dispose() {
    ConnectionController.instance.removeListener(_onStateChanged);
    trayManager.removeListener(this);
  }
}
