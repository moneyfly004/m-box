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

  void _onChange(List<ConnectivityResult> results) {
    if (_prev != null && !listEquals(results, _prev) && !results.contains(ConnectivityResult.none)) {
      AppLog.net('network changed: $_prev → $results');
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
    _prev = results;
  }
}
