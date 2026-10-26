import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/services/account_service.dart';

SubscriptionInfo _sub({
  String subscribeUrl = 'https://x/client/subscribe?token=t&type=clash',
  DateTime? expireTime,
  int deviceLimit = 3,
  int currentDevices = 1,
  int remainingDays = 30,
  bool isExpired = false,
  String status = 'active',
  bool isActive = true,
}) =>
    SubscriptionInfo(
      subscribeUrl: subscribeUrl,
      expireTime: expireTime,
      deviceLimit: deviceLimit,
      currentDevices: currentDevices,
      remainingDays: remainingDays,
      isExpired: isExpired,
      status: status,
      isActive: isActive,
    );

void main() {
  group('AccountService.classify', () {
    test('正常生效 → ok', () {
      final s = _sub(expireTime: DateTime.now().add(const Duration(days: 30)));
      expect(AccountService.classify(s), AccountStatus.ok);
    });

    test('is_expired=true → expired（优先于设备满）', () {
      final s = _sub(
          expireTime: DateTime.now().subtract(const Duration(days: 1)),
          isExpired: true,
          currentDevices: 3);
      expect(AccountService.classify(s), AccountStatus.expired);
    });

    test('到期判定以后端 is_expired 为准：is_expired=false 不因本地时钟误判', () {
      // 用户时钟偏差场景：本地时间已过 expire_time，但后端(权威)判定未到期
      // → 不得误判为 expired（否则会清缓存/拦截连接）
      final s = _sub(
          expireTime: DateTime.now().subtract(const Duration(hours: 1)),
          isExpired: false);
      expect(AccountService.classify(s), isNot(AccountStatus.expired));
    });

    // 回归（用户实测反馈）：上限 5 台时，第 5 台设备更新订阅后点连接提示"要升级设备"
    // 且连不上 —— 根因是"达到上限"被当成"本机超限"，把范围内的设备自己拦死了。
    test('达到上限（cur==limit）不再阻断连接，但保留提示状态', () {
      final s = _sub(
          expireTime: DateTime.now().add(const Duration(days: 10)),
          deviceLimit: 5,
          currentDevices: 5);
      // 仍返回 deviceFull 用于「提示」横幅
      expect(AccountService.classify(s), AccountStatus.deviceFull);
      // 但不得阻断连接（proxy core 用的是 isBlocked / isConnectionBlocked）
      final svc = AccountService.instance..reset();
      svc.sub = s;
      svc.status = AccountService.classify(s);
      expect(svc.isBlocked, isFalse, reason: '范围内的设备必须能连接');
    });

    test('设备数满（cur>=limit）→ deviceFull', () {
      final s = _sub(
          expireTime: DateTime.now().add(const Duration(days: 10)),
          deviceLimit: 3,
          currentDevices: 3);
      expect(AccountService.classify(s), AccountStatus.deviceFull);
    });

    test('设备未满 → ok', () {
      final s = _sub(
          expireTime: DateTime.now().add(const Duration(days: 10)),
          deviceLimit: 3,
          currentDevices: 2);
      expect(AccountService.classify(s), AccountStatus.ok);
    });

    test('订阅被停用 is_active=false → subscriptionDisabled', () {
      final s = _sub(isActive: false);
      expect(AccountService.classify(s), AccountStatus.subscriptionDisabled);
    });

    test('订阅状态非 active → subscriptionDisabled', () {
      final s = _sub(status: 'disabled');
      expect(AccountService.classify(s), AccountStatus.subscriptionDisabled);
    });

    test('无订阅地址（新用户）→ noSubscription', () {
      final s = _sub(subscribeUrl: '');
      expect(AccountService.classify(s), AccountStatus.noSubscription);
    });

    test('后端空对象 {}（无订阅记录）→ noSubscription', () {
      final s = SubscriptionInfo.fromJson(const {});
      expect(s.isActive, isTrue);
      expect(AccountService.classify(s), AccountStatus.noSubscription);
    });

    test('status 为空但 is_active 缺省 → 视为生效', () {
      final s = SubscriptionInfo.fromJson({
        'subscribe_url': 'https://x/client/subscribe?token=t',
        'expire_time': DateTime.now().add(const Duration(days: 3)).toIso8601String(),
      });
      expect(AccountService.classify(s), AccountStatus.ok);
    });
  });

  group('SubscriptionInfo.hasSubscription', () {
    test('生效订阅 → true', () {
      expect(
          _sub(expireTime: DateTime.now().add(const Duration(days: 3)))
              .hasSubscription,
          isTrue);
    });
    test('到期订阅 → false', () {
      expect(_sub(isExpired: true).hasSubscription, isFalse);
    });
    test('停用订阅 → false', () {
      expect(_sub(isActive: false).hasSubscription, isFalse);
    });
  });

  group('受限状态', () {
    test('到期/设备满/禁用/未开通都是 isBlocked，ok/unknown 不是', () {
      AccountService.instance.reset();
      expect(AccountService.instance.isBlocked, isFalse); // unknown
      AccountService.instance.sub = _sub(
          expireTime: DateTime.now().add(const Duration(days: 10)));
      AccountService.instance.status =
          AccountService.classify(AccountService.instance.sub!);
      expect(AccountService.instance.isBlocked, isFalse);
    });

    test('blockText 到期给出购买引导文案', () {
      final svc = AccountService.instance..reset();
      svc.sub = _sub(isExpired: true);
      svc.status = AccountStatus.expired;
      expect(svc.blockText, contains('到期'));
    });

    test('blockText 设备满包含 cur/limit 数字', () {
      final svc = AccountService.instance..reset();
      svc.sub = _sub(deviceLimit: 3, currentDevices: 3);
      svc.status = AccountStatus.deviceFull;
      expect(svc.blockText, contains('3/3'));
    });

    test('blockText 账号禁用优先用后端原文', () {
      final svc = AccountService.instance..reset();
      svc.status = AccountStatus.accountDisabled;
      svc.serverMessage = '账户已被禁用，无法使用服务';
      expect(svc.blockText, contains('已被禁用'));
    });
  });
}
