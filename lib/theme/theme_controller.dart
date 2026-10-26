import 'package:flutter/material.dart';

import '../core/services/settings_store.dart';

/// 主题控制器：全局单例，随设置「外观模式」切换。
/// 6 套外观模式各自是完整配色（含明暗），MBColors 的颜色取值动态跟随
/// [appearance]，MaterialApp 随 [mode]（由当前外观的明暗推导）重建。
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  /// 外观模式 key：light / warm / gray / darkgray / darkblue / black
  String appearance = 'light';

  /// 当前外观是否为深色（模式 darkgray / darkblue / black 为深色）
  bool get isDark {
    switch (appearance) {
      case 'darkgray':
      case 'darkblue':
      case 'black':
        return true;
      default:
        return false;
    }
  }

  /// MaterialApp 使用的亮暗模式（由外观明暗推导，无「跟随系统」）
  ThemeMode get mode => isDark ? ThemeMode.dark : ThemeMode.light;

  /// 切换外观模式并持久化（下次启动恢复）
  void setAppearance(String key) {
    if (key == appearance) return;
    appearance = key;
    notifyListeners();
    SettingsStore.instance
        .update((s) => s['appearance'] = key)
        .catchError((_) {});
  }

  /// 启动时从持久化设置恢复
  Future<void> restore() async {
    try {
      final s = await SettingsStore.instance.load();
      appearance = s['appearance']?.toString() ?? 'light';
      notifyListeners();
    } catch (_) {}
  }
}
