import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/server_pool.dart';
import '../proxy/proxy_core.dart';
import 'app_log.dart';

/// 网络变化监听：WiFi↔蜂窝切换 / 断网→恢复时通知 ConnectionController
/// 触发快速重连（3s 去抖，避免切换瞬间连续触发）
class NetworkMonitor {
  NetworkMonitor._();
  static final NetworkMonitor instance = NetworkMonitor._();

  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _debounce;
  List<ConnectivityResult>? _prev;

  void start() {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    stop();
    _sub = Connectivity().onConnectivityChanged.listen(_onChange);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _debounce?.cancel();
    _debounce = null;
    _prev = null;
  }

  /// 只比较「底层接入方式」，**忽略 VPN 隧道接口本身**（ConnectivityResult.other）。
  ///
  /// iOS 上隧道一起来，connectivity_plus 就会在结果里多出 `other`，并且会来回
  /// 抖动（实测日志：每 8 秒 wifi → [wifi, other] → wifi 循环）。旧实现把它当成
  /// "网络变了"，于是每次抖动都触发一次网络变化处理（重排测速、重连判定），
  /// 用户体感就是「连上没多久就自己断开/重连」。
  static List<ConnectivityResult> _underlying(List<ConnectivityResult> r) =>
      r.where((e) => e != ConnectivityResult.other).toList();

  void _onChange(List<ConnectivityResult> results) {
    final now = _underlying(results);
    final prevUnderlying = _prev == null ? null : _underlying(_prev!);
    final changed = _prev != null &&
        !listEquals(now, prevUnderlying ?? const <ConnectivityResult>[]) &&
        !results.contains(ConnectivityResult.none);
    _prev = results;
    if (changed) {
      AppLog.net('network changed: $prevUnderlying → $now');
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 3), () {
        // ⑥ 网络变了（WiFi↔蜂窝 / 断网→恢复）→ 之前"哪个域名可达/多快"的结论
        //    可能已经失效：清掉失败冷却，并重新实测排序（探测是约 1KB 的小接口）。
        ServerPool.instance.clearFailureCooldown();
        unawaited(() async {
          try {
            final ranked = await ApiClient.probeDomainLatency();
            if (ranked.isNotEmpty) {
              await ServerPool.instance.applyLatencyRanking(ranked);
            }
          } catch (e) {
            AppLog.error('网络变化后线路重排失败: $e');
          }
        }());
        ConnectionController.instance.onNetworkChanged();
      });
    }
  }
}
