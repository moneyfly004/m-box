import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services/account_service.dart';
import '../core/proxy/proxy_core.dart';
import '../core/services/device_service.dart';
import '../core/services/app_log.dart';
import '../core/services/auth_service.dart';
import '../core/services/subscription_service.dart';
import '../core/services/user_service.dart';
import '../l10n/app_strings.dart';
import '../main.dart';
import '../pages/devices/devices_page.dart';
import '../theme/app_theme.dart';

/// 「更新订阅没节点」的可操作提示。
///
/// 背景（2026-09-21 真实工单）：用户套餐到期 → 在设备管理里删光了设备 →
/// 续费一年 → 打开软件更新订阅拿不到节点。客户端当时是**全静默**的：只有一句
/// 「订阅中没有可用节点」，用户既不知道是自己删掉了本机设备，也不知道该做什么。
///
/// 这里按 [SubscribeIssue] 给出「原因 + 下一步」：重新登录 / 去续费 / 去开通 /
/// 设备管理 / 重试 —— 每种情况都有一个用户自己能点的出口。
class SubscribeIssuePrompt {
  SubscribeIssuePrompt._();

  /// 同一类问题在一次会话里只弹一次，避免「首页 + 节点页 + 定时刷新」
  /// 三方同时触发时连续弹好几个框。
  static final Set<SubscribeIssue> _shownThisRun = {};

  /// 测试缝
  static void resetForTest() => _shownThisRun.clear();

  /// 有可展示的问题就弹框；返回是否弹了。
  /// [onRetry] 由调用方提供（通常是「重新更新订阅」）。
  static Future<bool> showIfAny(
    BuildContext context, {
    Future<void> Function()? onRetry,
    bool force = false,
  }) async {
    final issue = SubscriptionService.instance.lastIssue;
    if (issue == null) return false;
    // 首页/节点页已经有受限横幅解释的原因（到期/设备满/被禁用/未开通）不再弹框：
    // 横幅本身带 CTA，再弹一次对话框纯属打扰（也会让同一句文案出现两次）。
    // 但「本机被删除」这类**横幅不会显示**的原因必须弹 —— 否则用户完全没有线索。
    if (issue != SubscribeIssue.deviceKicked &&
        issue != SubscribeIssue.noSubscribeUrl &&
        issue != SubscribeIssue.network &&
        issue != SubscribeIssue.badContent &&
        AccountService.instance.isBlocked) {
      return false;
    }
    if (!force && _shownThisRun.contains(issue)) return false;
    _shownThisRun.add(issue);
    if (!context.mounted) return false;
    await _show(context, issue, onRetry: onRetry);
    return true;
  }

  static Future<void> _show(
    BuildContext context,
    SubscribeIssue issue, {
    Future<void> Function()? onRetry,
  }) async {
    final acc = AccountService.instance;
    final title = _title(issue, acc);
    final body = _body(issue, acc);
    final primary = _primaryLabel(issue);

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.card,
        title: Text(title, style: const TextStyle(fontSize: 15.5)),
        content: Text(body,
            style: TextStyle(
                fontSize: 13, color: MFColors.txt2, height: 1.55)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(AppStrings.t('cancel')),
          ),
          // 被踢场景的次选：重新登录（重新登记本机）——后端接口不可用时的兜底
          if (issue == SubscribeIssue.deviceKicked)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'relogin'),
              child: Text(AppStrings.t('issue_relogin')),
            ),
          // 状态类原因（到期/停用/设备数/被移除）都可能是后端还没刷新到最新：
          // 给一个「重新检查」，让用户续费/删设备后不必重开 App
          if (onRetry != null && _retryable(issue))
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'retry'),
              child: Text(AppStrings.t('issue_recheck')),
            ),
          if (primary != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'primary'),
              child: Text(primary,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
    if (action == 'relogin') {
      if (!context.mounted) return;
      await _relogin(context);
      return;
    }
    if (action == 'retry' && onRetry != null) {
      _shownThisRun.remove(issue);
      await onRetry();
      return;
    }
    if (action != 'primary' || !context.mounted) return;

    switch (issue) {
      case SubscribeIssue.deviceKicked:
        // 首选「重新绑定本机」：token 仍然有效，一次调用就能恢复，用户不用重新输密码。
        // 后端没上这个接口（旧版后端）或失败 → 回退「重新登录」。
        if (await _rebind(context, onRetry)) return;
        if (context.mounted) await _relogin(context);
        return;
      case SubscribeIssue.noSubscribeUrl:
        await _relogin(context);
        return;
      case SubscribeIssue.expired:
      case SubscribeIssue.noSubscription:
        mainTabIndex.value = 2; // 套餐页
        return;
      case SubscribeIssue.deviceFull:
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DevicesPage()));
        return;
      case SubscribeIssue.subscriptionDisabled:
      case SubscribeIssue.accountDisabled:
        // 只能联系客服：不提供动作（上面 primary 为 null）
        return;
      case SubscribeIssue.network:
      case SubscribeIssue.badContent:
        if (onRetry != null) await onRetry();
        return;
    }
  }

  /// 重新绑定本机（首选恢复路径）：调用后端自助接口 → 成功后立刻刷新账号与订阅。
  /// 返回 true = 已处理（成功或已引导去设备管理）；false = 应回退到「重新登录」。
  static Future<bool> _rebind(
      BuildContext context, Future<void> Function()? onRetry) async {
    final r = await DeviceService.instance.rebindCurrent();
    if (!context.mounted) return true;
    switch (r) {
      case DeviceRebindResult.ok:
        AppLog.conn('rebind device ok → 刷新账号与订阅');
        try {
          await AccountService.instance.refresh(force: true);
          final nodes =
              await SubscriptionService.instance.fetchNodes(force: true);
          await ConnectionController.instance.applySubscriptionNodes(nodes);
        } catch (e) {
          AppLog.error('refresh after rebind failed: $e');
        }
        if (!context.mounted) return true;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppStrings.t('rebind_ok'))));
        if (onRetry != null) await onRetry();
        return true;
      case DeviceRebindResult.deviceLimit:
        // 名额已满：引导先删闲置设备（这里直接换成「设备管理」提示）
        await _show(context, SubscribeIssue.deviceFull, onRetry: onRetry);
        return true;
      case DeviceRebindResult.unsupported:
        AppLog.log('REBIND', '后端未提供 rebind 接口（404）→ 回退「重新登录」');
        return false;
      case DeviceRebindResult.failed:
        return false;
    }
  }

  /// 重新登录：登出会清掉本地会话与缓存，界面自动回到登录页（RootShell 监听
  /// SessionState）——用户重新登录一次，本机设备就会重新登记，订阅恢复可用。
  static Future<void> _relogin(BuildContext context) async {
    try {
      await AuthService.instance.logout();
      UserService.instance.invalidateCache();
      if (!context.mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      context.read<SessionState>().setLoggedIn(false);
    } catch (e) {
      debugPrint('relogin failed: $e');
    }
  }

  static String _title(SubscribeIssue issue, AccountService acc) {
    switch (issue) {
      case SubscribeIssue.deviceKicked:
        return AppStrings.t('issue_kicked_title');
      case SubscribeIssue.expired:
        return AppStrings.t('account_expired_title');
      case SubscribeIssue.noSubscription:
        return AppStrings.t('no_sub_title');
      case SubscribeIssue.subscriptionDisabled:
        return AppStrings.t('sub_disabled_title');
      case SubscribeIssue.accountDisabled:
        return AppStrings.t('account_disabled_title');
      case SubscribeIssue.deviceFull:
        // 上限 0 = 该订阅未开放设备使用（后台显式设置）：删除设备/升级名额都无效，
        // 正确出路是联系客服
        return (acc.sub?.deviceLimit ?? 0) <= 0
            ? AppStrings.t('device_zero_title')
            : AppStrings.t('device_full_title');
      case SubscribeIssue.noSubscribeUrl:
        return AppStrings.t('issue_no_url_title');
      case SubscribeIssue.network:
        return AppStrings.t('issue_network_title');
      case SubscribeIssue.badContent:
        return AppStrings.t('issue_bad_content_title');
    }
  }

  static String _body(SubscribeIssue issue, AccountService acc) {
    switch (issue) {
      case SubscribeIssue.deviceKicked:
        return AppStrings.t('issue_kicked_body');
      case SubscribeIssue.expired:
        return AppStrings.t('account_expired_block');
      case SubscribeIssue.noSubscription:
        return AppStrings.t('no_sub_block');
      case SubscribeIssue.subscriptionDisabled:
        return AppStrings.t('sub_disabled_block');
      case SubscribeIssue.accountDisabled:
        return acc.serverMessage ?? AppStrings.t('account_disabled_block');
      case SubscribeIssue.deviceFull:
        if ((acc.sub?.deviceLimit ?? 0) <= 0) {
          return AppStrings.t('device_zero_block');
        }
        return AppStrings.t('device_full_block', {
          'cur': '${acc.sub?.currentDevices ?? 0}',
          'limit': '${acc.sub?.deviceLimit ?? 0}',
        });
      case SubscribeIssue.noSubscribeUrl:
        return AppStrings.t('issue_no_url_body');
      case SubscribeIssue.network:
        return AppStrings.t('issue_network_body');
      case SubscribeIssue.badContent:
        return AppStrings.t('issue_bad_content_body');
    }
  }

  /// 这些原因可能是「后端状态/本地判定还没刷新」造成的，值得给一个重新检查
  static bool _retryable(SubscribeIssue issue) => const {
        SubscribeIssue.expired,
        SubscribeIssue.noSubscription,
        SubscribeIssue.subscriptionDisabled,
        SubscribeIssue.deviceFull,
        SubscribeIssue.network,
        SubscribeIssue.badContent,
      }.contains(issue);

  static String? _primaryLabel(SubscribeIssue issue) {
    switch (issue) {
      case SubscribeIssue.deviceKicked:
        return AppStrings.t('issue_rebind');
      case SubscribeIssue.noSubscribeUrl:
        return AppStrings.t('issue_relogin');
      case SubscribeIssue.expired:
        return AppStrings.t('go_renew');
      case SubscribeIssue.noSubscription:
        return AppStrings.t('go_purchase');
      case SubscribeIssue.deviceFull:
        return AppStrings.t('device_manage');
      case SubscribeIssue.subscriptionDisabled:
      case SubscribeIssue.accountDisabled:
        return null; // 只能联系客服
      case SubscribeIssue.network:
      case SubscribeIssue.badContent:
        return AppStrings.t('retry_btn');
    }
  }
}
