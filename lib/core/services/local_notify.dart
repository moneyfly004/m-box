import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/app_strings.dart';
import 'settings_store.dart';

/// 本地通知服务（到期提醒 / 连接异常）
class LocalNotify {
  LocalNotify._();
  static final LocalNotify instance = LocalNotify._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      const android = AndroidInitializationSettings('@drawable/ic_stat_vpn');
      const darwin = DarwinInitializationSettings();
      await _plugin.initialize(const InitializationSettings(
        android: android, macOS: darwin, iOS: darwin,
      ));
      _initialized = true;
    } catch (_) {
      // 测试环境或平台插件不可用时静默跳过
    }
  }

  /// 通知总开关（设置项 `notify`，默认开 —— 与 `_defaults()` 一致）。
  ///
  /// 旧实现：这个 key 在 defaults 里存在但**全仓库零读取**，设置页也没有入口，
  /// 等于「到期提醒 / 连接异常」两种通知用户无法关闭。现在设置页「通知与提醒」
  /// 组里的「允许通知」开关落这个 key，这里统一拦截。
  ///
  /// 为什么不缓存成静态值：通知调用点极少（到期提醒按天一次、重连失败偶发），
  /// 每次读一次 prefs 的代价远小于「用户刚关掉开关、下一条通知照旧弹出」。
  Future<bool> _enabled() async {
    try {
      final s = await SettingsStore.instance.load();
      return s['notify'] != false;
    } catch (_) {
      return true; // 读不到设置时不阻断通知（与默认值 true 行为一致）
    }
  }

  Future<void> showExpiryWarning(int remainingDays) async {
    if (!_initialized) return;
    if (!await _enabled()) return;
    final title = AppStrings.t('expiry_notify_title');
    final body = AppStrings.t('expiry_notify_body', {'days': '$remainingDays'});
    await _plugin.show(
      2001,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'mbox_expiry', 'Subscription Expiry',
          importance: Importance.high, priority: Priority.high,
        ),
        macOS: const DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> showReconnectFailed() async {
    if (!_initialized) return;
    if (!await _enabled()) return;
    await _plugin.show(
      2002,
      AppStrings.t('reconnect_fail_notify_title'),
      AppStrings.t('reconnect_fail_notify_body'),
      NotificationDetails(
        android: AndroidNotificationDetails(
          'mbox_conn', 'Connection Status',
          importance: Importance.defaultImportance,
        ),
        macOS: const DarwinNotificationDetails(),
      ),
    );
  }
}
