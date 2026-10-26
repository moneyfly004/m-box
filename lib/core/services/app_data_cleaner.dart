import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import 'local_paths.dart';
import 'subscription_cache.dart';

/// 本地数据清理器：
/// - [cleanupOnLaunch]：启动时执行 —— 全新安装（install_id 不存在）清空一切旧
///   残留（订阅缓存/日志/内核配置/规则集/偏好/登录 token），保证重装后从零
///   重新登录、重新拉取订阅，不沿用上一个安装的配置；老安装只清理版本过期的
///   订阅缓存（升级后强制重拉，不沿用旧版本拉到的订阅/节点）。
/// - [wipeForLogout]：退出登录时执行出厂级磁盘清理（保留 install_id，设备仍是
///   本安装，仅账号相关数据全部抹除，防止下一账号/下次登录读到旧配置）。
///
/// 注意：所有操作尽力而为（单点失败不影响整体），且不会删除安装标记
/// install_id —— 标记只随「卸载 / 手动清应用数据」消失，是区分
/// 「老安装升级」与「全新安装」的依据。
class AppDataCleaner {
  AppDataCleaner._();

  /// 启动时调用（必须在 UpdateService.init 之后：需要真实 app 版本号
  /// 参与订阅缓存版本比对，避免误清本版本刚写入的缓存）。
  static Future<void> cleanupOnLaunch() async {
    try {
      final fresh = !await LocalPaths.markerExists();
      if (fresh) {
        // 全新安装 / 应用数据被清（卸载残留复活、手动清数据等）→ 全量清理
        await _wipeAll();
      } else {
        // 老安装（覆盖升级/正常启动）→ 仅让版本过期的订阅缓存失效并删除
        await SubscriptionCache.instance.readLatest();
      }
      await LocalPaths.writeMarker();
    } catch (_) {
      // 清理失败不阻塞启动
    }
  }

  /// 退出登录的出厂级磁盘清理（token/偏好/内存态由 AuthService 编排）
  static Future<void> wipeForLogout() async {
    try {
      await _wipeAll();
    } catch (_) {}
  }

  static Future<void> _wipeAll() async {
    // 1) 应用支持目录内容：订阅缓存 / http.log / 规则集 / Android 内核 work 等，
    //    保留安装标记（区分全新安装的依据）
    final support = await LocalPaths.supportDir();
    if (support != null) {
      await LocalPaths.clearDirectoryContents(
        support,
        keepFiles: {LocalPaths.markerFileName},
      );
    }
    // 2) 文档目录下的崩溃日志
    final docs = await LocalPaths.documentsDir();
    if (docs != null) {
      await LocalPaths.deleteBestEffort(Directory('${docs.path}/crash_logs'));
    }
    // 3) 系统缓存目录内容（Android cacheDir = libmbox 临时文件）
    final cache = await LocalPaths.cacheDir();
    if (cache != null) {
      await LocalPaths.clearDirectoryContents(cache);
    }
    // 4) 桌面端内核工作目录（sing-box config.json + .srs 规则集）；
    //    Android 内核文件位于 filesDir（= 支持目录，第 1 步已清）
    if (!Platform.isAndroid && !Platform.isIOS) {
      await LocalPaths.deleteBestEffort(
        Directory('${Directory.systemTemp.path}/mbox_core'),
      );
    }
    // 5) 偏好全部清除（连接设置/自动登录/语言/主题…回出厂默认）
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {}
    // 6) 登录 token（内存 + 系统 Keychain / 加密存储）
    try {
      await ApiClient.clearTokens();
    } catch (_) {}
  }
}
