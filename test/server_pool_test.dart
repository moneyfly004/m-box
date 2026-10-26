import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/api/server_pool.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ServerPool 域名池', () {
    test('域名池：主域名在前，且都是 /api/v1 基底、去重', () {
      final pool = ServerPool.instance;
      final all = pool.all;
      expect(all.length, greaterThanOrEqualTo(2), reason: '至少要有主域名 + 1 个备用域名');
      expect(all.first, contains('dy.moneyfly.top'));
      expect(all.every((u) => u.endsWith('/api/v1')), isTrue,
          reason: '每一项都应是 scheme://host/api/v1 形式的基底');
      expect(all.toSet().length, all.length, reason: '不应有重复域名');
    });

    test('normalizeBase：补 https、补 /api/v1、去尾斜杠', () {
      expect(ServerPool.normalizeBase('example.com'), 'https://example.com/api/v1');
      expect(ServerPool.normalizeBase('https://example.com/'), 'https://example.com/api/v1');
      expect(ServerPool.normalizeBase('  sub.example.com  '), 'https://sub.example.com/api/v1');
      expect(ServerPool.normalizeBase(''), '');
      expect(ServerPool.normalizeBase('   '), '');
    });

    test('公网明文 http 一律拒绝：令牌是 Bearer 明文头，走 http 等于送人', () {
      expect(ServerPool.normalizeBase('http://a.b.c/api/v1/'), '');
      expect(ServerPool.normalizeBase('http://panel.example.com'), '');
      expect(ServerPool.normalizeBase('ftp://a.b.c/api/v1'), '');
      expect(ServerPool.normalizeBase('file:///tmp/x'), '');
    });

    test('回环 / 私有网段仍允许 http（内网自建面板、本机调试不出公网）', () {
      expect(ServerPool.normalizeBase('http://127.0.0.1:8000/api/v1'),
          'http://127.0.0.1:8000/api/v1');
      expect(ServerPool.normalizeBase('http://localhost:8000'),
          'http://localhost:8000/api/v1');
      expect(ServerPool.normalizeBase('http://192.168.1.5'),
          'http://192.168.1.5/api/v1');
      expect(ServerPool.normalizeBase('http://10.0.0.9/api/v1'),
          'http://10.0.0.9/api/v1');
      expect(ServerPool.normalizeBase('http://172.16.3.4/api/v1'),
          'http://172.16.3.4/api/v1');
    });

    test('默认走主域名；markWorking 记住可用域名并可恢复', () async {
      final pool = ServerPool.instance;
      await pool.reset();
      expect(pool.activeBase, pool.all.first);
      expect(pool.usingCustom, isFalse);

      final backup = pool.all[1];
      await pool.markWorking(backup);
      expect(pool.activeBase, backup);
      expect(pool.activeIndex, 1);
      expect(pool.activeHost, Uri.parse(backup).host);

      await pool.reset();
      expect(pool.activeBase, pool.all.first);
    });

    test('lastResortCandidates：跳过已试过的域名，池内试完返回 null', () {
      final pool = ServerPool.instance;
      final all = pool.all;
      final tried = <String>[all.first];
      final next = pool.nextUntried(tried);
      expect(next, isNotNull);
      expect(next, isNot(all.first));

      // 把所有域名都标记为已尝试 → 没有可切换的了
      tried.addAll(all);
      expect(pool.nextUntried(tried), isNull);
    });

    test('自定义域名优先于池内域名', () async {
      final pool = ServerPool.instance;
      await pool.setCustom('my.example.com');
      expect(pool.usingCustom, isTrue);
      expect(pool.activeBase, 'https://my.example.com/api/v1');

      await pool.clearCustom();
      expect(pool.usingCustom, isFalse);
      expect(pool.all.contains(pool.activeBase), isTrue);
      await pool.reset();
    });

    test('整链验证：主域名连接失败 → 自动改打备用域名并记住它', () async {
      final pool = ServerPool.instance;
      await pool.reset();
      final primary = pool.activeBase;
      final primaryHost = Uri.parse(primary).host;
      final backupHost = Uri.parse(pool.all[1]).host;

      final dio = Dio(BaseOptions(baseUrl: primary));
      final adapter = _FailoverAdapter(deadHost: primaryHost);
      dio.httpClientAdapter = adapter;
      dio.interceptors.add(buildServerFailoverInterceptor(dio));

      final r = await dio.get('/users/me');
      expect(r.statusCode, 200);
      expect(r.data, {'success': true, 'data': {'ok': true}});
      expect(adapter.calls.length, 2, reason: '主域名失败后应重试一次备用域名');
      expect(adapter.calls.first, contains(primaryHost));
      expect(adapter.calls.last, contains(backupHost));
      expect(pool.activeHost, backupHost, reason: '成功的域名要被记住');

      await pool.reset();
    });

    test('写操作不因"响应超时"重试（避免重复下单/签到），但"没连上"仍可重试', () {
      RequestOptions opts() => RequestOptions(path: '/orders');

      DioException err(DioExceptionType t) =>
          DioException(requestOptions: opts(), type: t);

      // 连接没建立 → 任何方法都可安全换域名重试
      expect(ServerPool.isRetryableOnRotation(err(DioExceptionType.connectionError), 'POST'), isTrue);
      expect(ServerPool.isRetryableOnRotation(err(DioExceptionType.connectionTimeout), 'POST'), isTrue);

      // 连接已建立、请求可能已送达 → 写操作不重试，幂等读操作可以
      expect(ServerPool.isRetryableOnRotation(err(DioExceptionType.receiveTimeout), 'POST'), isFalse);
      expect(ServerPool.isRetryableOnRotation(err(DioExceptionType.sendTimeout), 'POST'), isFalse);
      expect(ServerPool.isRetryableOnRotation(err(DioExceptionType.receiveTimeout), 'GET'), isTrue);
      expect(ServerPool.isRetryableOnRotation(err(DioExceptionType.sendTimeout), 'PUT'), isFalse);

      // 非连接层失败一律不重试
      expect(ServerPool.isRetryableOnRotation(Exception('boom'), 'GET'), isFalse);
    });

    test('isConnectionFailure：只把连接层失败判为需要换域名重试', () {
      RequestOptions opts() => RequestOptions(path: '/x');

      // 连不上 / 超时 → 值得换域名重试
      for (final t in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.connectionError,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      ]) {
        expect(
          ServerPool.isConnectionFailure(
              DioException(requestOptions: opts(), type: t)),
          isTrue,
          reason: '$t 应触发域名轮换',
        );
      }

      // 服务端明确回复（401/403/404/429/500）→ 换域名没有意义，不能掩盖业务错误
      for (final code in [401, 403, 404, 429, 500]) {
        expect(
          ServerPool.isConnectionFailure(DioException(
            requestOptions: opts(),
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: opts(), statusCode: code),
          )),
          isFalse,
          reason: 'HTTP $code 不应触发域名轮换',
        );
      }

      // 非 Dio 异常按"不是连接失败"处理（不擅自重试）
      expect(ServerPool.isConnectionFailure(Exception('boom')), isFalse);
    });
  });
}

/// 域名轮换整链验证：主域名连接失败 → 自动改打备用域名并记住它。
///
/// 用假的 HttpClientAdapter 模拟"主域名连不上、备用域名可用"，
/// 覆盖 ApiClient 里真实使用的拦截器（buildServerFailoverInterceptor）。
class _FailoverAdapter implements HttpClientAdapter {
  _FailoverAdapter({required this.deadHost});

  final String deadHost;
  final List<String> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final url = '${options.baseUrl}${options.path}';
    calls.add(url);
    if (options.baseUrl.contains(deadHost)) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: 'connection refused',
        message: 'connection refused',
      );
    }
    return ResponseBody.fromString(
      '{"success":true,"data":{"ok":true}}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
