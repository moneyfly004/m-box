import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/mac_tun_helper.dart';
import '../proxy/port_guard.dart';
import '../proxy/proxy_core.dart';
import '../proxy/proxy_core_cli.dart';
import '../proxy/system_proxy.dart';
import 'app_log.dart';
import 'kernel_log.dart';
import 'settings_store.dart';

/// 一键导出诊断包：把排障需要的**所有现场**打成一个压缩包。
///
/// 为什么需要它：用户报「连不上/没网」时，客服要同时看 app_log、内核日志、
/// 崩溃转储、当前端口/代理状态、系统信息 —— 旧实现只能让用户逐个截图或
/// 反复来回问，一次排障要好几个回合。这里一次收齐并压缩，用户点一下就完事。
class DiagnosticExport {
  DiagnosticExport._();

  /// 生成诊断包并返回压缩包（或目录）的绝对路径。
  /// 压缩失败时退化为目录路径（至少文件都在）。
  static Future<String> exportBundle() async {
    final docs = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final stage = Directory('${docs.path}/mbox_diag_$stamp')
      ..createSync(recursive: true);

    Future<void> copyFile(String? path, String name) async {
      if (path == null || path.isEmpty) return;
      final f = File(path);
      if (!await f.exists()) return;
      await f.copy('${stage.path}/$name');
    }

    // 1) 现成日志
    await copyFile(await AppLog.filePath, 'app_log.txt');
    await copyFile(await KernelLog.filePath, 'kernel_log.txt');
    await copyFile(await KernelLog.crashFilePath, 'kernel_crash.log');

    // 2) 现场诊断快照
    final report = await _buildReport();
    await File('${stage.path}/diagnostics.txt').writeAsString(report);

    // 3) 压缩（tar 在各平台都有：macOS/Linux 自带，Windows 10+ 带 bsdtar）
    final zipPath = '${docs.path}/mbox_diag_$stamp.tar.gz';
    try {
      final r = await Process.run(
          'tar', ['-czf', zipPath, '-C', stage.path, '.']);
      if (r.exitCode == 0) {
        await stage.delete(recursive: true);
        return zipPath;
      }
    } catch (_) {}
    return stage.path;
  }

  static Future<String> _buildReport() async {
    final b = StringBuffer();
    void line(String s) => b.writeln(s);

    line('MBox 诊断报告');
    line('生成时间: ${DateTime.now()}');
    line('');

    // App / 系统
    try {
      final info = await PackageInfo.fromPlatform();
      line('[App] ${info.appName} ${info.version}+${info.buildNumber}');
    } catch (_) {
      line('[App] 版本未知');
    }
    line('[系统] ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}');
    line('[进程] pid=$pid '
        'arch=${Platform.version.split(' ').last}');
    line('');

    // 设置（脱敏：不导出任何 token / secret / 订阅地址）
    try {
      final s = await SettingsStore.instance.load();
      line('[设置] localPort=${s['localPort']} '
          'clashApiPort=${s['clashApiPort']} '
          'tunMode=${s['tunMode']} '
          'defaultMode=${s['defaultMode']} '
          'kernelLogLevel=${s['kernelLogLevel']}');
      line('[设置] 节点数=${ConnectionController.instance.nodes.length} '
          '当前节点=${ConnectionController.instance.current?.tag ?? '-'}');
    } catch (e) {
      line('[设置] 读取失败: $e');
    }
    line('');

    // 连接状态
    try {
      final c = ConnectionController.instance;
      line('[连接] status=${c.status} connected=${c.status == ConnStatus.connected} '
          'error=${c.error ?? '-'}');
      line('[连接] 真实出口=${c.realCountry ?? '-'} '
          '检测失败=${c.realCountryFailed}');
    } catch (e) {
      line('[连接] 读取失败: $e');
    }
    line('');

    // 端口状态
    try {
      final s = await SettingsStore.instance.load();
      final local = (s['localPort'] as num?)?.toInt() ?? 2080;
      final api = (s['clashApiPort'] as num?)?.toInt() ?? 9090;
      for (final e in [
        ('本地代理端口', local),
        ('Clash API 端口', api),
      ]) {
        final free = await PortGuard.isFree(e.$2);
        final tw = await PortGuard.timeWaitCount(e.$2);
        final holder = await PortGuard.whoListens(e.$2);
        line('[端口] ${e.$1} ${e.$2}: free=$free '
            'TIME_WAIT=$tw '
            'holder=${holder?.describe ?? '无'}');
      }
    } catch (e) {
      line('[端口] 检测失败: $e');
    }
    line('');

    // 系统代理（macOS）
    if (Platform.isMacOS || Platform.isWindows) {
      try {
        line('[系统代理] 指向本机=${await SystemProxyManager.pointsToLocal(
          (await SettingsStore.instance.load())['localPort'] as int? ?? 2080,
        )}');
      } catch (e) {
        line('[系统代理] 检测失败: $e');
      }
      line('');
    }

    // macOS TUN 授权
    if (Platform.isMacOS) {
      try {
        final core = await ProxyCoreCli.resolveKernelBinary();
        line('[TUN 授权] 免密可用=${await MacTunHelper.isGranted(core)} '
            '内核=$core');
      } catch (e) {
        line('[TUN 授权] 检测失败: $e');
      }
      line('');
    }

    // 内核最近日志尾部
    try {
      final tail = ProxyCoreCli.logTailSnapshot();
      line('[内核日志尾部 ${tail.length} 行]');
      final start = tail.length > 60 ? tail.length - 60 : 0;
      for (final l in tail.skip(start)) {
        line(l);
      }
    } catch (_) {}

    return b.toString();
  }
}
