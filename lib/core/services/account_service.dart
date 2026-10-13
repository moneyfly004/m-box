import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import '../api/api_client.dart';
import '../models/models.dart';
import 'subscription_service.dart';
import 'user_service.dart';

/// 账号可用状态（三端统一判定「能否连接 VPN / 该给什么提示」）：
///
/// - [AccountStatus.ok]：订阅生效、设备未满 → 可连接；
/// - [AccountStatus.expired]：套餐已到期 → 引导购买套餐；
/// - [AccountStatus.deviceFull]：设备数已达上限 → 引导升级设备套餐 / 管理设备；
/// - [AccountStatus.subscriptionDisabled]：订阅被停用/状态异常 → 提示联系客服；
/// - [AccountStatus.accountDisabled]：账号被禁用（后端 403「账户已被禁用…」）→ 提示联系客服；
/// - [AccountStatus.noSubscription]：尚未开通套餐 → 引导开通；
/// - [AccountStatus.unknown]：信息尚未拉取到（网络失败等），不据此拦连接，避免误伤。
enum AccountStatus {
  ok,
  unknown,
  noSubscription,
  expired,
  deviceFull,
  subscriptionDisabled,
  accountDisabled,
}

/// 登录后 / 进入主页时拉取一次订阅信息，全局缓存到期 / 设备 / 状态判定。
///
/// 设计要点：
/// - 登录成功后立刻 refresh()，主页不再等「拉节点时顺带拉订阅」——到期/超限/禁用
///   在进入主页前就已判定，可立即给出对应提示，而不是等到用户点连接才暴露；
/// - 登出时 reset()，避免上个账号的状态/节点残留到下个账号（切号误判）；
/// - 连接门禁（ConnectionController.connect）直接读本服务判定结果，自动连接、
///   重连同样被拦截，三个受限状态都无法建立 VPN。
class AccountService extends ChangeNotifier {
  AccountService._();
  static final AccountService instance = AccountService._();

  /// 最近一次成功的订阅信息（null = 尚未拿到）
  SubscriptionInfo? sub;

  /// 当前判定状态（初始 unknown，refresh 后更新）
  AccountStatus status = AccountStatus.unknown;

  /// 本会话是否已至少判定过一次（true 后连接门禁才生效；
  /// 单元测试直连内核时未加载即跳过门禁，不影响内核 e2e）
  bool loaded = false;

  /// 后端直返的提示（如「账户已被禁用，无法使用服务…」），优先展示原文
  String? serverMessage;

  /// 判定是否命中禁用类后端文案
  static bool _isDisableMessage(String msg) {
    final m = msg.toLowerCase();
    return msg.contains('禁用') ||
        msg.contains('禁止') ||
        m.contains('disabled') ||
        m.contains('banned');
  }

  /// 由订阅信息推导账号可用状态（纯函数，供单测）
  /// 优先级：订阅停用 > 到期 > 设备满 > 未开通 > 正常
  static AccountStatus classify(SubscriptionInfo s) {
    final subActive =
        s.isActive && (s.status.isEmpty || s.status == 'active');
    if (!subActive) return AccountStatus.subscriptionDisabled;
    // 到期判定以「后端返回的 is_expired」为准（服务器时间，权威），
    // 不用本地时钟与 expire_time 比较 —— 用户时钟偏差(快/慢)不再被误判
    // 到期而清缓存/拦截连接。
    final expired = s.isExpired;
    if (expired) return AccountStatus.expired;
    if (s.deviceLimit > 0 && s.currentDevices >= s.deviceLimit) {
      // ⚠️ 这里是「已达到上限」而不是「本机超限」：
      // 后端不会把超限设备计入 currentDevices，所以**第 6 台看到的数字同样是 5/5**。
      // 也就是说这个状态无法区分"我是被允许的第 5 台"和"我是多出来的第 6 台"。
      // 因此它只用于**提示**（首页 / 我的 → 琥珀色横幅 + 「管理设备」入口），
      // 绝不用于拦截连接 —— 否则第 5 台（合法范围内）会被自己拦死，
      // 表现为"更新订阅后点连接提示要升级设备"（用户实测反馈的缺陷）。
      // 拦截交给后端判定：超限设备拉订阅时后端只下发错误节点，
      // 客户端据此（SubscribeIssue.deviceFull）拒绝连接，见 isConnectionBlocked。
      return AccountStatus.deviceFull;
    }
    if (s.subscribeUrl.isEmpty) return AccountStatus.noSubscription;
    return AccountStatus.ok;
  }

  /// 是否处于受限状态（到期 / 停用 / 禁用 / 未开通 → 不发起连接）
  ///
  /// 注意 [AccountStatus.deviceFull] **不在其中**：设备数达到上限时，
  /// 在允许范围内的本机必须能正常更新订阅、正常连接，只做提示不阻断。
  bool get isBlocked =>
      status == AccountStatus.expired ||
      status == AccountStatus.subscriptionDisabled ||
      status == AccountStatus.accountDisabled ||
      status == AccountStatus.noSubscription;

  /// 首页横幅（提示，不阻断连接）：受限状态 **或** 设备数达到上限都要提示，
  /// 但设备满只提示"可升级设备/删除闲置设备"，不影响本机连接与订阅更新。
  bool get needsAttention =>
      isBlocked || status == AccountStatus.deviceFull;

  /// 连接门禁（proxy core 使用）：账号受限，**或后端确实拒绝了本设备**。
  ///
  /// 后端对超限设备（如上限 5 台时的第 6 台）只下发 4 个消息节点（❌ 原因:
  /// 设备数量超限）→ 订阅里带拒绝载荷时 [SubscriptionService.deviceRejected]
  /// 为 true，此时才拒绝连接并引导升级设备。
  ///
  /// 注意这里**不能**用"当前设备数 ≥ 上限"来判断：上限 5 台时范围内的第 5 台
  /// 同样满足该条件，但它拿到的是真实节点、必须能正常连接（用户明确要求）。
  bool get isConnectionBlocked =>
      isBlocked || SubscriptionService.instance.deviceRejected;

  /// 拉取并重新判定（登录成功后 / 主页刷新 / 支付成功 时调用）。
  /// force=true 强制重新请求；否则会话内只拉一次。
  Future<AccountStatus> refresh({bool force = false}) async {
    if (loaded && !force) return status;
    try {
      final info = await SubscriptionService.instance.fetchInfo();
      sub = info;
      status = classify(info);
      serverMessage = null;
    } catch (e) {
      final msg = ApiClient.errorMsg(e);
      // 禁用账号：后端所有业务接口 403「账户已被禁用…」→ 明确判定为禁用，
      // 而不是当网络错误处理（否则会出现登录后无任何提示却连不上 VPN）
      if (_isDisableMessage(msg)) {
        status = AccountStatus.accountDisabled;
        serverMessage = msg;
      }
      // 其余失败（断网/超时等）：保留旧判定；若从未成功过则维持 unknown，
      // 连接门禁放行由内核报错兜底，不把网络抖动误判为「到期/禁用」
    }
    loaded = true;
    notifyListeners();
    return status;
  }

  /// 购买/升级成功后：失效用户资料缓存，并发刷新账号状态与订阅节点，返回最新节点。
  /// 节点应用到连接控制器由调用方在 context 校验后完成（本层不依赖 UI）。
  Future<List<ProxyNode>> refreshAfterPurchase() async {
    UserService.instance.invalidateCache();
    final accF = refresh(force: true);
    final nodesF = SubscriptionService.instance.fetchNodes(force: true);
    await accF;
    return nodesF;
  }

  /// 登出 / 切换账号时清理，防止旧账号状态残留
  void reset() {
    sub = null;
    status = AccountStatus.unknown;
    loaded = false;
    serverMessage = null;
    notifyListeners();
  }

  /// 受限状态对应的「连接被拒」提示正文（首页横幅 / 弹窗 / 内核错误共用）
  String get blockText {
    switch (status) {
      case AccountStatus.expired:
        return AppStrings.t('account_expired_block');
      case AccountStatus.deviceFull:
        return AppStrings.t('device_full_block', {
          'cur': '${sub?.currentDevices ?? 0}',
          'limit': '${sub?.deviceLimit ?? 0}',
        });
      case AccountStatus.accountDisabled:
        return serverMessage?.isNotEmpty == true
            ? serverMessage!
            : AppStrings.t('account_disabled_block');
      case AccountStatus.subscriptionDisabled:
        return AppStrings.t('sub_disabled_block');
      case AccountStatus.noSubscription:
        return AppStrings.t('no_sub_block');
      case AccountStatus.ok:
      case AccountStatus.unknown:
        return '';
    }
  }

  /// 受限状态对应的弹窗标题（UI 用）
  String get blockTitle {
    switch (status) {
      case AccountStatus.expired:
        return AppStrings.t('account_expired_title');
      case AccountStatus.deviceFull:
        return AppStrings.t('device_full_title');
      case AccountStatus.accountDisabled:
        return AppStrings.t('account_disabled_title');
      case AccountStatus.subscriptionDisabled:
        return AppStrings.t('sub_disabled_title');
      case AccountStatus.noSubscription:
        return AppStrings.t('no_sub_title');
      case AccountStatus.ok:
      case AccountStatus.unknown:
        return '';
    }
  }
}
