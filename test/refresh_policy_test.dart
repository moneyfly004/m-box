// 令牌刷新策略 —— 单测。
//
// 起因（2026-09-25 工单：「软件无故退出，是后台踢的吗？」）：
// 客户端旧实现把**任何**刷新失败都当「会话失效」→ 登出回登录页，于是客户网络/
// 代理一抖就被踢。这里钉住语义：
//   · 传输层失败（超时/连不上/DNS/5xx/429）→ 绝不登出，退避重试；
//   · 服务端明确拒绝（401/400/403）→ 才终结会话；
//   · 提前刷新：access 剩余不足 10 分钟就静默续期，别等 401。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/api/refresh_policy.dart';

/// 造一个 JWT（只有 payload 有内容，签名随便）——只用于解析 exp
String _jwt({required Duration validFor, DateTime? from}) {
  final base = from ?? DateTime.now().toUtc();
  final exp = base.add(validFor).millisecondsSinceEpoch ~/ 1000;
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.${seg({'sub': 2, 'exp': exp})}.sig';
}

DioException _err(
    {int? status,
    DioExceptionType type = DioExceptionType.badResponse,
    Object? body}) {
  final opts = RequestOptions(path: '/auth/refresh', method: 'POST');
  return DioException(
    requestOptions: opts,
    type: type,
    response: status == null
        ? null
        : Response<dynamic>(
            requestOptions: opts,
            statusCode: status,
            data: body ?? {'message': 'x'}),
  );
}

void main() {
  group('刷新失败分类：只有服务端明确拒绝才终结会话', () {
    test('刷新接口 401（令牌已失效）→ rejected，允许登出', () {
      final o = classifyRefreshError(_err(status: 401));
      expect(o, RefreshOutcome.rejected);
      expect(shouldEndSession(o), isTrue);
    });

    test('400（缺少刷新令牌）→ rejected，允许登出', () {
      expect(classifyRefreshError(_err(status: 400)), RefreshOutcome.rejected);
    });

    test('403 且正文不是本服务端信封（CDN/WAF/维护页）→ transient，绝不登出', () {
      // 后端 /auth/refresh 只返回 400/401（见 handlers/auth.go），命中 403 基本都是
      // 网关/反代；旧实现一律当「账户被禁用」→ 登出，与「无故退出」同族。
      for (final body in <Object?>[
        '<html><head><title>403 Forbidden</title></head></html>',
        {'message': 'Forbidden'},
        {'errors': []},
        'Just a moment...',
      ]) {
        final o = classifyRefreshError(_err(status: 403, body: body));
        expect(o, RefreshOutcome.transient, reason: '正文=$body 不该终结会话');
        expect(shouldEndSession(o), isFalse, reason: '正文=$body 登出会误伤客户');
      }
    });

    test('403 且正文确是本服务端信封 → rejected（保留真实拒绝语义）', () {
      final o = classifyRefreshError(_err(status: 403, body: {
        'success': false,
        'code': 403,
        'message': '账户已被禁用',
      }));
      expect(o, RefreshOutcome.rejected);
      expect(shouldEndSession(o), isTrue);
    });

    test('连不上 / 超时 / DNS 失败（没有 response）→ transient，禁止登出', () {
      for (final t in [
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.unknown,
      ]) {
        final o = classifyRefreshError(_err(type: t));
        expect(o, RefreshOutcome.transient, reason: '$t 不该终结会话');
        expect(shouldEndSession(o), isFalse, reason: '$t 登出会误伤客户');
      }
    });

    test('429 / 5xx（服务端可达但当前不可用）→ transient，禁止登出', () {
      for (final s in [429, 500, 502, 503, 504]) {
        expect(classifyRefreshError(_err(status: s)), RefreshOutcome.transient,
            reason: 'HTTP $s 不该终结会话');
      }
    });

    test('非 Dio 异常（本地存储读写失败等）→ transient', () {
      expect(classifyRefreshError(StateError('keychain locked')),
          RefreshOutcome.transient);
      expect(shouldEndSession(RefreshOutcome.transient), isFalse);
      expect(shouldEndSession(RefreshOutcome.success), isFalse);
    });
  });

  group('2xx 但正文不可解析 → 保留会话（不登出）', () {
    test('标准信封 + access_token → success', () {
      expect(
        classifyRefreshSuccessBody({'access_token': 'a.b.c', 'refresh_token': 'r'}),
        RefreshOutcome.success,
      );
    });

    test('网关/WAF 页（HTML 字符串）→ transient', () {
      expect(classifyRefreshSuccessBody('<html><body>502 Bad Gateway</body></html>'),
          RefreshOutcome.transient);
      expect(classifyRefreshSuccessBody('{"code":401,"message":"令牌失效"}'),
          RefreshOutcome.transient, reason: '非标准信封（无 data/access_token）');
    });

    test('access_token 为空串 / null / 字段改名 → transient', () {
      expect(classifyRefreshSuccessBody({'access_token': ''}), RefreshOutcome.transient);
      expect(classifyRefreshSuccessBody({'access_token': null}), RefreshOutcome.transient);
      expect(classifyRefreshSuccessBody({'token': 'a.b.c'}), RefreshOutcome.transient);
      expect(classifyRefreshSuccessBody(null), RefreshOutcome.transient);
      expect(classifyRefreshSuccessBody([1, 2, 3]), RefreshOutcome.transient);
    });

    test('transient 不终结会话（只有 rejected 才登出）', () {
      expect(shouldEndSession(classifyRefreshSuccessBody('nope')), isFalse);
    });
  });

  group('退避重试', () {
    test('首次 0.5s → 1.5s → 3s，且不超过 3 次', () {
      expect(kRefreshMaxAttempts, 3);
      expect(refreshBackoff(1), const Duration(milliseconds: 500));
      expect(refreshBackoff(2), const Duration(milliseconds: 1500));
      expect(refreshBackoff(3), const Duration(seconds: 3));
      // 越界（调用方不会传，但兜底要安全）：按最长等待处理，绝不返回 0 造成忙等
      expect(refreshBackoff(0), const Duration(seconds: 3));
      expect(refreshBackoff(99), const Duration(seconds: 3));
    });
  });

  group('JWT exp 解析（提前刷新的依据）', () {
    test('正常解析 exp', () {
      final exp = DateTime.now().toUtc().add(const Duration(minutes: 30));
      final parsed = jwtExpiry(_jwt(validFor: const Duration(minutes: 30)));
      expect(parsed, isNotNull);
      expect(parsed!.difference(exp).inSeconds.abs() <= 1, isTrue);
    });

    test('解析不出（空/乱码/非 JWT）→ null，不抛', () {
      expect(jwtExpiry(null), isNull);
      expect(jwtExpiry(''), isNull);
      expect(jwtExpiry('not-a-jwt'), isNull);
      expect(jwtExpiry('a.b'), isNull);
      expect(jwtExpiry('a.!!!.c'), isNull);
    });

    test('url-safe 字母表与缺失 padding 都能解', () {
      // payload 里含 - / _ 的 token 也要能解出 exp
      final t = _jwt(validFor: const Duration(hours: 2));
      expect(jwtExpiry(t), isNotNull);
    });
  });

  group('提前刷新：剩余不足 10 分钟才触发', () {
    test('剩余 9 分钟 → 需要刷新；剩余 11 分钟 → 不需要', () {
      expect(
        needsProactiveRefresh(_jwt(validFor: const Duration(minutes: 9))),
        isTrue,
      );
      expect(
        needsProactiveRefresh(_jwt(validFor: const Duration(minutes: 11))),
        isFalse,
      );
    });

    test('已过期 → 需要刷新', () {
      expect(
        needsProactiveRefresh(_jwt(validFor: const Duration(minutes: -5))),
        isTrue,
      );
    });

    test('解析不出 exp 时不乱发请求', () {
      expect(needsProactiveRefresh(null), isFalse);
      expect(needsProactiveRefresh('garbage'), isFalse);
    });

    test('时间可注入（便于确定性测试）', () {
      final now = DateTime.utc(2026, 9, 25, 12);
      final token = _jwt(validFor: const Duration(minutes: 5), from: now);
      expect(needsProactiveRefresh(token, now: now), isTrue);
      // 5 分钟后再看：已过期 → 仍需刷新
      expect(
        needsProactiveRefresh(token, now: now.add(const Duration(minutes: 10))),
        isTrue,
      );
      // 提前看：还剩 30 分钟 → 不需要
      final fresh = _jwt(validFor: const Duration(minutes: 30), from: now);
      expect(needsProactiveRefresh(fresh, now: now), isFalse);
    });
  });
}
