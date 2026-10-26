import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 本地路径助手：统一解析各平台私有目录，并维护「安装标记 install_id」。
///
/// 为什么需要安装标记：
/// - Android 卸载后系统可能用 Auto Backup 恢复旧数据；桌面端卸载通常不清理
///   App Support 目录 —— 这些都会让「旧安装的配置/缓存」在重装后复活。
/// - 用 install_id 文件标记当前安装实例：标记不存在 = 全新安装 / 应用数据被清
///   （卸载残留、手动清数据等）→ 启动时清空一切旧残留（订阅缓存、日志、内核
///   配置、规则集、偏好、登录 token），强制重新登录并重新拉取订阅，
///   绝不沿用上一个安装留下的账号/订阅/节点配置。
class LocalPaths {
  LocalPaths._();

  /// 测试注入点：替换 support 目录（flutter test 无 path_provider 平台实现）。
  /// 用法与 ApiClient.debugDio 一致：仅在测试中设置。
  @visibleForTesting
  static Future<Directory> Function()? debugSupportDir;

  /// 安装标记文件名（保留：登出/清数据时不删除，只随卸载或手动清数据消失）
  static const markerFileName = 'install_id';

  static Future<Directory?> _supportDir() async {
    if (debugSupportDir != null) {
      try {
        return await debugSupportDir!();
      } catch (_) {
        return null;
      }
    }
    try {
      return await getApplicationSupportDirectory();
    } catch (_) {
      return null;
    }
  }

  /// 应用支持目录（macOS/Windows：App Support；Android：filesDir）
  static Future<Directory?> supportDir() => _supportDir();

  /// 文档目录（崩溃日志所在）
  static Future<Directory?> documentsDir() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
  }

  /// 缓存目录（Android：cacheDir，libmbox 临时文件；桌面端可空）
  static Future<Directory?> cacheDir() async {
    try {
      return await getApplicationCacheDirectory();
    } catch (_) {
      return null;
    }
  }

  /// 安装标记文件路径（不存在 = 全新安装/数据被清）
  static Future<File?> markerFile() async {
    final dir = await _supportDir();
    if (dir == null) return null;
    return File('${dir.path}/$markerFileName');
  }

  static Future<bool> markerExists() async {
    final f = await markerFile();
    if (f == null) return false;
    try {
      return f.existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<String> readMarker() async {
    final f = await markerFile();
    if (f == null) return '';
    try {
      return (await f.readAsString()).trim();
    } catch (_) {
      return '';
    }
  }

  /// 写入安装标记（每次启动调用：全新安装首次写入，旧安装保持原值）
  static Future<void> writeMarker() async {
    final f = await markerFile();
    if (f == null) return;
    try {
      if (f.existsSync()) return; // 已有标记保持不变
      final dir = f.parent;
      if (!dir.existsSync()) await dir.create(recursive: true);
      final rnd = Random.secure();
      final id = List.generate(
        16,
        (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await f.writeAsString(id, flush: true);
    } catch (_) {
      // 标记写入失败不阻塞启动
    }
  }

  /// 删除路径（尽力而为，单个失败不影响整体清理）
  static Future<void> deleteBestEffort(FileSystemEntity e) async {
    try {
      if (e is Directory && await e.exists()) {
        await e.delete(recursive: true);
      } else if (e is File && await e.exists()) {
        await e.delete();
      }
    } catch (_) {}
  }

  /// 删除目录下全部内容（保留目录本身），可跳过指定文件名
  static Future<void> clearDirectoryContents(
    Directory dir, {
    Set<String>? keepFiles,
  }) async {
    try {
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (keepFiles != null &&
            e is File &&
            keepFiles.contains(e.uri.pathSegments.last)) {
          continue;
        }
        await deleteBestEffort(e);
      }
    } catch (_) {}
  }
}
