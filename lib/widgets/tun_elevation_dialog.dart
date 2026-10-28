import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/platform/elevation.dart';
import '../core/platform/mac_tun_helper.dart';
import '../core/proxy/proxy_core_cli.dart';
import '../core/services/settings_store.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// 提权结果：调用方据此决定「重启应用」还是「授权成功后继续切 TUN」。
enum TunElevationOutcome {
  /// 用户取消 / 授权失败：保持当前模式，不做任何变更
  cancelled,

  /// Windows：已安排以管理员身份重启（带 pendingTunConnect），调用方应 exit
  relaunching,

  /// macOS：刚完成一次管理员授权（sudoers 免密规则），可继续切 TUN
  granted,
}

/// 「TUN 需要管理员权限」对话框（首页三态开关与设置页「强制 TUN」共用）。
///
/// 两个平台两条路：
///  - **Windows**：UAC 重新以管理员启动（Clash Party 同款），重启后凭
///    `pendingTunConnect` 自动续连；
///  - **macOS**：整 App 提权会把 HOME 变成 /var/root、污染配置目录，所以改成
///    「一次性授权内核」——写一条只针对该内核二进制的 sudoers 免密规则，
///    之后内核以 root 启动、TUN 可用，App 本身仍是普通权限。
Future<TunElevationOutcome> requestTunElevation(BuildContext context) async {
  if (Elevation.isElevated) return TunElevationOutcome.granted;
  if (Platform.isWindows) return _windowsFlow(context);
  if (Platform.isMacOS) return _macFlow(context);
  return TunElevationOutcome.cancelled;
}

Future<TunElevationOutcome> _windowsFlow(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: MBColors.card2,
      title: Text(AppStrings.t('tun_admin_title'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      content: Text(AppStrings.t('tun_admin_body_win'),
          style: TextStyle(fontSize: 12.5, color: MBColors.txt2, height: 1.6)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(AppStrings.t('tun_admin_cancel'),
              style: TextStyle(color: MBColors.txt2, fontSize: 12.5)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(AppStrings.t('tun_admin_relaunch'),
              style: const TextStyle(fontSize: 12.5)),
        ),
      ],
    ),
  );
  if (confirmed != true) return TunElevationOutcome.cancelled;
  final ok = await Elevation.relaunchElevated();
  if (!ok) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('tun_admin_fail'))),
      );
    }
    return TunElevationOutcome.cancelled;
  }
  // 重启后要「接着把用户想做的事做完」：TUN 写进设置 + 一次性标记，
  // 新实例拿到线路后自动连接（Clash Party 用命令行参数做同一件事）。
  try {
    await SettingsStore.instance.update((s) {
      s['tunMode'] = 'force';
      s['pendingTunConnect'] = true;
    });
  } catch (_) {}
  return TunElevationOutcome.relaunching;
}

/// macOS：一键授权（推荐）或复制命令自己以 root 启动。
Future<TunElevationOutcome> _macFlow(BuildContext context) async {
  final corePath = await ProxyCoreCli.resolveKernelBinary();
  final manualCmd = 'sudo -E "${Platform.resolvedExecutable}"';
  if (!context.mounted) return TunElevationOutcome.cancelled;

  final choice = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: MBColors.card2,
      title: Text(AppStrings.t('tun_admin_title'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(AppStrings.t('tun_admin_body_mac'),
                style: TextStyle(
                    fontSize: 12.5, color: MBColors.txt2, height: 1.6)),
            const SizedBox(height: 14),
            Text(AppStrings.t('tun_mac_cmd_title'),
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: MBColors.txt)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: MBColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: MBColors.line),
              ),
              child: SelectableText(
                manualCmd,
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: MBColors.txt2),
              ),
            ),
            const SizedBox(height: 8),
            Text(AppStrings.t('tun_mac_grant_hint'),
                style:
                    TextStyle(fontSize: 11, color: MBColors.txt3, height: 1.5)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'copy'),
          child: Text(AppStrings.t('tun_mac_copy_cmd'),
              style: TextStyle(color: MBColors.txt2, fontSize: 12.5)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(AppStrings.t('tun_admin_cancel'),
              style: TextStyle(color: MBColors.txt2, fontSize: 12.5)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'grant'),
          child: Text(AppStrings.t('tun_mac_grant'),
              style: const TextStyle(fontSize: 12.5)),
        ),
      ],
    ),
  );

  if (choice == 'copy') {
    await Clipboard.setData(ClipboardData(text: manualCmd));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('tun_mac_cmd_copied'))),
      );
    }
    return TunElevationOutcome.cancelled;
  }
  if (choice != 'grant') return TunElevationOutcome.cancelled;

  final ok = await MacTunHelper.grant(corePath);
  if (!ok) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('tun_admin_fail'))),
      );
    }
    return TunElevationOutcome.cancelled;
  }
  return TunElevationOutcome.granted;
}
