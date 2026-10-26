// 服务端限流 / 锁定的识别与文案 —— 单测。
//
// 用**真实后端返回的报文形态**做回归（2026-09-23 线上抓取，见 login_lock.dart
// 文件头注释）：
//   A. 按 IP 限流（中间件）：HTTP 429 + {"code":42900,"message":"请求过于频繁，请稍后再试"}
//   B. 失败次数锁定（auth.go）：HTTP 429 + Retry-After: <秒> +
//      {"code":42900,"message":"登录失败次数过多，请 30 分钟后再试"}
// 客户现象是「密码没错却登不进」+ 反复点登录让限流一直不解除，
// 所以文案必须区分这两种、给出剩余时间、并明确「可以换网络」。

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/api/endpoints.dart';
import 'package:mbox/core/services/login_lock.dart';

/// 构造一个与真实响应等价的 DioException
DioException _dio(int status, Object body, {Map<String, String>? headers}) {
  final opts = RequestOptions(path: Endpoints.login, method: 'POST');
  final resp = Response<dynamic>(
    requestOptions: opts,
    statusCode: status,
    data: body,
    headers: Headers.fromMap({
      Headers.contentTypeHeader: ['application/json'],
      for (final e in (headers ?? const {}).entries) e.key: [e.value],
    }),
  );
  return DioException(
    requestOptions: opts,
    response: resp,
    type: DioExceptionType.badResponse,
  );
}

/// 构造 IMF-fixdate 字符串（`Retry-After` / `X-RateLimit-Reset` 用的就是这种）
String _httpDate(DateTime utc) {
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final u = utc.toUtc();
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${wd[u.weekday - 1]}, ${p2(u.day)} ${mo[u.month - 1]} ${u.year} '
      '${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)} GMT';
}

void main() {
  group('识别：真实后端的两种 429（dy.moneyfly.top / LoginRateLimitMiddleware）', () {
    test('锁定态：「账户已被临时锁定15分钟」→ 抠出等待时长，按钮冷却仍只挡连点', () {
      final info = parseRateLimit(
        _dio(429, {
          'code': 429,
          'message': '登录失败次数过多，账户已被临时锁定15分钟，请稍后再试',
        }, headers: {
          'X-RateLimit-Limit': '500',
          'X-RateLimit-Remaining': '0',
        }),
        path: Endpoints.login,
      );
      expect(info, isNotNull);
      expect(info!.isAccountLock, isTrue);
      // 时长只在文案里（无 Retry-After 头）→ 必须能从文案抠出来
      expect(info.retryAfter, const Duration(minutes: 15));
      // 按钮冷却被夹在 30s~2min：换网络后不该被 15 分钟倒计时挡在门外
      expect(info.cooldown, const Duration(minutes: 2));
      expect(formatRemaining(info.retryAfter!), '15 分钟');
    });

    test('未锁定态：文案无时长 + X-RateLimit-Reset 头 → 头里解析剩余时间', () {
      final reset = DateTime.now().toUtc().add(const Duration(minutes: 3));
      final info = parseRateLimit(
        _dio(429, {'code': 429, 'message': '登录失败次数过多，请稍后再试'}, headers: {
          'X-RateLimit-Reset': _httpDate(reset),
        }),
        path: Endpoints.login,
      );
      expect(info!.retryAfter, isNotNull);
      expect(info.retryAfter!.inMinutes, inInclusiveRange(2, 3));
      expect(info.isAccountLock, isTrue, reason: '「次数过多」属于锁定语义');
    });

    test('验证码限流文案「请5分钟后再试」也能抠出时长', () {
      final info = parseRateLimit(
        _dio(429, {'code': 429, 'message': '验证码尝试次数过多，请5分钟后再试'}),
        path: '/auth/verification/verify',
      );
      expect(info!.scope, RateLimitScope.verification);
      expect(info.retryAfter, const Duration(minutes: 5));
    });
  });

  group('识别：中间件 IP 限流（cboard /auth/login 形态）', () {
    test('429 + code 42900 + 限流文案 → 命中，且判为「非账号锁定」', () {
      final info = parseRateLimit(
        _dio(429, {'code': 42900, 'message': '请求过于频繁，请稍后再试'}),
        path: Endpoints.login,
      );
      expect(info, isNotNull);
      expect(info!.message, '请求过于频繁，请稍后再试');
      expect(info.scope, RateLimitScope.login);
      expect(info.isAccountLock, isFalse);
      expect(info.retryAfter, isNull);
      // 服务端没给 Retry-After → 兜底 60s 冷却
      expect(info.cooldown, const Duration(seconds: 60));
    });

    test('429 空 message → 用兜底文案，不显示空提示', () {
      final info = parseRateLimit(_dio(429, {'code': 42900}), path: Endpoints.login);
      expect(info!.message, '请求过于频繁，请稍后再试');
    });
  });

  group('识别：失败次数锁定（B 形态，带 Retry-After）', () {
    test('Retry-After 秒数被解析成等待时长，并判为账号锁定', () {
      final info = parseRateLimit(
        _dio(429, {'code': 42900, 'message': '登录失败次数过多，请 30 分钟后再试'},
            headers: {'Retry-After': '1750'}),
        path: Endpoints.login,
      );
      expect(info, isNotNull);
      expect(info!.retryAfter, const Duration(seconds: 1750));
      expect(info.isAccountLock, isTrue);
      // 文案里也写了 30 分钟；头优先
      expect(formatRemaining(info.retryAfter!), '29 分 10 秒');
    });

    test('Retry-After 为 HTTP 日期也能解析（无依赖的 IMF-fixdate）', () {
      final d = parseRetryAfter(_httpDate(DateTime.now().add(const Duration(minutes: 5))));
      expect(d, isNotNull);
      expect(d!.inMinutes, inInclusiveRange(4, 5));
    });

    test('Retry-After 为 0 / 负数 / 垃圾值 → 不产生死循环或超长冷却', () {
      expect(parseRetryAfter('0'), Duration.zero);
      expect(parseRetryAfter('-5'), Duration.zero);
      expect(parseRetryAfter('abc'), isNull);
      expect(parseRetryAfter(null), isNull);
      // Retry-After: 0 → 等待时长为 0 不可用 → 落到按钮兜底 60s
      final zero = parseRateLimit(
        _dio(429, {'code': 42900, 'message': '请求过于频繁'}, headers: {'Retry-After': '0'}),
        path: Endpoints.login,
      );
      expect(zero!.retryAfter, isNull);
      expect(zero.cooldown, const Duration(seconds: 60));
    });

    test('按钮冷却夹在 30s~2min：异常大的 Retry-After 不会把按钮锁死', () {
      final huge = parseRateLimit(
        _dio(429, {'code': 42900, 'message': '登录失败次数过多'}, headers: {'Retry-After': '999999'}),
        path: Endpoints.login,
      );
      expect(huge!.retryAfter, const Duration(seconds: 999999));
      expect(huge.cooldown, const Duration(minutes: 2));
      // 很短的等待也被抬到 30s，避免用户连点把计数一直顶满
      final tiny = parseRateLimit(
        _dio(429, {'code': 42900, 'message': '请3秒后再试'}, headers: {'Retry-After': '3'}),
        path: Endpoints.login,
      );
      expect(tiny!.retryAfter, const Duration(seconds: 3));
      expect(tiny.cooldown, const Duration(seconds: 30));
    });
  });

  group('不误判', () {
    test('401 密码错误 → 不是限流（保持原有 toast 分支）', () {
      expect(
        parseRateLimit(_dio(401, {'code': 401, 'message': '用户名或密码错误'}),
            path: Endpoints.login),
        isNull,
      );
    });

    test('403 账户禁用 → 不是限流', () {
      expect(
        parseRateLimit(_dio(403, {'code': 403, 'message': '账户已被禁用'}),
            path: Endpoints.login),
        isNull,
      );
    });

    test('网络不通（无 response）→ 不是限流', () {
      final e = DioException(
        requestOptions: RequestOptions(path: Endpoints.login),
        type: DioExceptionType.connectionError,
      );
      expect(parseRateLimit(e, path: Endpoints.login), isNull);
    });

    test('普通异常文本不含限流语义 → 不是限流', () {
      expect(parseRateLimit(Exception('登录失败：未返回令牌'), path: Endpoints.login),
          isNull);
    });
  });

  group('兜底与范围', () {
    test('拿不到状态码时按文案兜底（代理把 429 改写成 200 的场景）', () {
      final info = parseRateLimit(
        Exception('操作过于频繁，请稍后再试'),
        path: Endpoints.login,
      );
      expect(info, isNotNull);
      expect(info!.scope, RateLimitScope.login);
    });

    test('带 message 字段的异常（ApiException 形态）也能识别', () {
      final info = parseRateLimit(_FakeApiException('登录失败次数过多，请 30 分钟后再试'),
          path: Endpoints.login);
      expect(info, isNotNull);
      expect(info!.isAccountLock, isTrue);
    });

    test('按路径区分范围：登录 / 刷新 / 验证码', () {
      expect(scopeForPath('/auth/login-json'), RateLimitScope.login);
      expect(scopeForPath('/auth/refresh'), RateLimitScope.refresh);
      expect(scopeForPath('/auth/verification/send'), RateLimitScope.verification);
      expect(scopeForPath('/auth/forgot-password'), RateLimitScope.verification);
      expect(scopeForPath('/user/subscribe'), RateLimitScope.other);
    });
  });

  group('文案', () {
    test('剩余时间人类可读', () {
      expect(formatRemaining(const Duration(seconds: 45)), '45 秒');
      expect(formatRemaining(const Duration(seconds: 90)), '1 分 30 秒');
      expect(formatRemaining(const Duration(minutes: 30)), '30 分钟');
      expect(formatRemaining(Duration.zero), '');
      expect(formatRemaining(const Duration(seconds: -3)), '');
    });

    test('限流文案关键词覆盖中英（客服/日志检索用）', () {
      expect(looksLikeRateLimitMessage('请求过于频繁，请稍后再试'), isTrue);
      expect(looksLikeRateLimitMessage('登录失败次数过多，请 30 分钟后再试'), isTrue);
      expect(looksLikeRateLimitMessage('发送频率过高，请 5 分钟后再试'), isTrue);
      expect(looksLikeRateLimitMessage('Too many requests'), isTrue);
      expect(looksLikeRateLimitMessage('用户名或密码错误'), isFalse);
    });
  });
}

/// 模拟 ApiClient 的 ApiException（本测试不 import 接口层，避免循环依赖）
class _FakeApiException implements Exception {
  _FakeApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
