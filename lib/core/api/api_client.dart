import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/log_rotation.dart';
import '../utils/serial_executor.dart';
import 'endpoints.dart';
import 'refresh_policy.dart';
import 'server_pool.dart';
import 'user_agent.dart';

/// 统一 API 客户端
/// 后端所有接口（除 XBoard 兼容与订阅原文外）返回信封：
/// { success, code, message, data, timestamp, request_id }
/// 本客户端统一解包：get/post/put/delete 直接返回 data（dynamic），
/// 无信封时（XBoard 兼容接口）返回整个响应体。
class ApiClient {
  /// 测试注入点：在测试中替换为 mock Dio（需在使用 ApiClient 之前设置）
  static Dio? debugDio;

  ApiClient._internal() {
    _dio = debugDio ?? Dio(BaseOptions(
      baseUrl: Endpoints.baseUrl,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      sendTimeout: const Duration(seconds: 15),
      headers: {'Accept': 'application/json', 'User-Agent': userAgent},
    ));
    if (debugDio != null) return; // 测试环境：跳过 JWT 拦截器
    // 请求日志（写入 App Support 目录 http.log，登录/网络问题排查用）
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        _logHttp('>>> ${o.method} ${_maskUri(o.uri)}\n'
            '    body: ${_isSensitivePath(o.path) ? '[REDACTED]' : o.data}');
        h.next(o);
      },
      onResponse: (r, h) {
        final data = r.data;
        // 二进制响应（订阅原文按 bytes 拉取以支持 gzip 解压）不做 toString：
        // 否则整份内容会变成 "[1, 2, 3, ...]" 巨串写进 http.log，既无意义又费内存
        final body = data is String
            ? data
            : (data is List<int>
                ? '<binary ${data.length}B>'
                : (data?.toString() ?? ''));
        // 敏感接口（登录/刷新/改密）响应体含 token，同样脱敏，避免凭据明文落盘
        final masked = _isSensitivePath(r.requestOptions.path) ? '[REDACTED]' : body;
        _logHttp('<<< ${r.statusCode} ${_maskUri(r.requestOptions.uri)}\n'
            '    body: ${masked.length > 400 ? masked.substring(0, 400) : masked}');
        h.next(r);
      },
      onError: (e, h) {
        final respBody = _isSensitivePath(e.requestOptions.path)
            ? '[REDACTED]'
            : e.response?.data;
        _logHttp('!!! ${e.type} ${_maskUri(e.requestOptions.uri)} status=${e.response?.statusCode}\n'
            '    err: $e\n    resp: $respBody');
        h.next(e);
      },
    ));
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // 每次请求都取「当前生效域名」：ServerPool 会在主域名不可达时切到备用域名，
          // 构造 Dio 时快照进 BaseOptions 的 baseUrl 不会跟着变，必须在这里刷新。
          options.baseUrl = ServerPool.instance.activeBase;
          // UA 每次请求强制覆盖：Dio 构造时会把 UA 快照进 BaseOptions，
          // 若 UpdateService 在单例创建后才更新 userAgent，直接赋值静态量
          // 不会生效；这里在发请求前统一刷新（与 Authorization 同机制）。
          // 例外：调用方通过 extra['_ua'] 传入的自定义 UA（按订阅配置）优先，
          // 否则会被这里无条件抹掉。
          final overrideUa = options.extra['_ua']?.toString();
          options.headers['User-Agent'] =
              (overrideUa != null && overrideUa.isNotEmpty)
                  ? overrideUa
                  : userAgent;
          // 注入设备详情头（型号/品牌/OS/类型），后端据此补充 UA 解析不全的设备信息
          for (final e in UserAgent.deviceHeaders.entries) {
            options.headers[e.key] = e.value;
          }
          final t = await readAccessToken();
          if (t != null && t.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $t';
            // 提前刷新：access token 剩余不足 10 分钟就静默续期，别等 401 再补
            // ——「401 → 刷新」那条路每次都是一次赌博，而客户大多开着代理，
            //   节点一抖刷新就失败（旧实现会因此登出，见 refresh_policy.dart）。
            if (options.extra['_noSessionExpired'] != true &&
                needsProactiveRefresh(t)) {
              unawaited(_tryRefresh());
            }
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          final resp = e.response;
          final noSession = e.requestOptions.extra['_noSessionExpired'] == true;
          if (resp?.statusCode == 401 && !noSession &&
              e.requestOptions.extra['_retried'] != true) {
            e.requestOptions.extra['_retried'] = true;
            final outcome = await _tryRefresh();
            if (outcome == RefreshOutcome.success) {
              final t = await readAccessToken();
              e.requestOptions.headers['Authorization'] = 'Bearer $t';
              try {
                final retried = await _dio.fetch(e.requestOptions);
                return handler.resolve(retried);
              } on DioException catch (e2) {
                return handler.next(e2);
              } catch (_) {
                return handler.next(e);
              }
            }
            if (shouldEndSession(outcome)) {
              // 服务端明确拒绝（令牌失效/被拉黑/账户禁用）→ 只能重新登录
              _onSessionExpired?.call();
              return handler.next(e);
            }
            // 传输层失败（超时/连不上/5xx…）：**不登出**，如实报「网络异常」。
            // 旧实现把这种情况也当会话失效 → 客户网络/代理一抖就被踢回登录页，
            // 这正是「软件无故退出」的主因（见 refresh_policy.dart 文件头注释）。
            _logHttp('!!! 刷新失败（传输层）→ 保留会话，报网络错误: ${e.requestOptions.uri}');
            return handler.next(DioException(
              requestOptions: e.requestOptions,
              response: e.response,
              type: DioExceptionType.connectionError,
              error: '令牌刷新失败：网络不可用',
            ));
          }
          handler.next(e);
        },
      ),
    );

    // 域名轮换拦截器（最后添加 → onError 最先执行）：见 server_pool.dart
    // 的实现与说明（只在「连接层失败」时换域名重试，4xx/5xx 业务错误不换）。
    _dio.interceptors.add(buildServerFailoverInterceptor(_dio, onLog: _logHttp));
  }

  static ApiClient? _instance;

  static ApiClient get instance => _instance ??= ApiClient._internal();

  /// 测试专用：重置单例，使下一次访问使用新的 debugDio
  @visibleForTesting
  static void resetInstance() => _instance = null;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    // macOS：默认 useDataProtectionKeyChain=true 走数据保护 Keychain，
    // adhoc 签名（未公证分发）无对应 entitlement → SecItem 报 -34018（登录失败）。
    // 显式关闭，改走传统 Keychain（无需 entitlement）。
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  /// 客户端 User-Agent（后端据此识别 mbox 客户端与操作系统/设备类型）。
  /// 规范：`MBox/<版本> (<操作系统特征串>)`，见 user_agent.dart。
  /// 默认值仅兜底；启动时由 UpdateService.init 用真实包版本 + OS 信息刷新
  /// （设备列表/登录历史会显示 MBox + Windows/macOS/Android + 版本号）。
  static String userAgent = 'MBox/0.0.1';

  /// 测试开关：false 时 token 存内存（避免 flutter test 无插件实现）
  static bool persistTokens = true;
  static String? _memAccess;
  static String? _memRefresh;

  late final Dio _dio;
  VoidCallback? _onSessionExpired;
  Future<RefreshOutcome>? _refreshing;

  // ---------- Token 存取 ----------
  static Future<String?> readAccessToken() async {
    if (_memAccess != null) return _memAccess;
    if (!persistTokens) return null;
    try {
      return await _storage.read(key: 'access_token');
    } catch (_) {
      return null;
    }
  }

  static Future<String?> readRefreshToken() async {
    if (_memRefresh != null) return _memRefresh;
    if (!persistTokens) return null;
    try {
      return await _storage.read(key: 'refresh_token');
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveTokens(String access, String refresh) async {
    _memAccess = access;
    _memRefresh = refresh;
    if (!persistTokens) return;
    // 存储失败（如 macOS Keychain 异常）不阻塞登录：内存 token 仍可用
    try {
      await _storage.write(key: 'access_token', value: access);
      await _storage.write(key: 'refresh_token', value: refresh);
    } catch (e) {
      _logHttp('!!! token 持久化失败（内存兜底）: $e');
    }
  }

  static Future<void> clearTokens() async {
    _memAccess = null;
    _memRefresh = null;
    if (!persistTokens) return;
    // 与 saveTokens 对齐：删除失败（如 macOS Keychain 异常）不抛出中断登出，
    // 内存 token 已清空即已登出，持久层异常仅记日志。
    try {
      await _storage.delete(key: 'access_token');
      await _storage.delete(key: 'refresh_token');
    } catch (e) {
      _logHttp('!!! token 清除失败（内存已清空，视为已登出）: $e');
    }
  }

  /// 会话失效回调（强制回登录页）
  void onSessionExpired(VoidCallback cb) => _onSessionExpired = cb;

  /// 并发 401 去重：同一时刻只允许一个刷新请求在途。
  /// 返回的是 [RefreshOutcome]（不是 bool）——「服务端明确拒绝」与「网络抖动」
  /// 必须分开：只有前者才终结会话（见 refresh_policy.dart 文件头注释）。
  Future<RefreshOutcome> _tryRefresh() =>
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<RefreshOutcome> _doRefresh() async {
    final rt = await _readRefreshTokenWithRetry();
    if (rt == null || rt.isEmpty) {
      // 本地没有可用的 refresh token：无法自愈，只能重新登录。
      // （读存储失败已在 _readRefreshTokenWithRetry 里兜一层，避免 Keychain
      //  抖动一次就把用户登出。）
      _logHttp('!!! 无可用 refresh token → 会话无法续期');
      return RefreshOutcome.rejected;
    }
    for (var attempt = 1; attempt <= kRefreshMaxAttempts; attempt++) {
      try {
        // 刷新请求自身标记 _retried + _noSessionExpired：若后端对失效 refresh_token
        // 也返 401，避免 onError 拦截器再次进入刷新分支 —— 那会重入 _tryRefresh()
        // 拿到「正在进行中的同一个 future」并 await 它，而该 future 正等这条 POST
        // 完成，形成自等待死锁。带上标记直接放行为普通失败。
        //
        // _noDomainFailover：刷新**禁止**换域名重试 —— 该接口会轮换并拉黑旧
        // refresh_token，第一次已成功而响应丢失时，换域名拿同一个旧 token 再刷
        // 必然 401，反而把用户登出。
        final r = await _dio.post(Endpoints.refresh,
            data: {'refresh_token': rt},
            options: Options(extra: {
              '_noSessionExpired': true,
              '_retried': true,
              '_noDomainFailover': true,
            }));
        final data = _unwrap(r.data);
        // 200 但正文不是标准信封（网关/WAF 页、维护页、后端改字段名）→ **不登出**：
        // 只当传输层异常，退避重试后如实报网络错误，会话留着。
        if (classifyRefreshSuccessBody(data) == RefreshOutcome.success) {
          final m = data as Map;
          await saveTokens(
            m['access_token'].toString(),
            (m['refresh_token'] as String?) ?? rt,
          );
          return RefreshOutcome.success;
        }
        _logHttp('!!! 刷新返回 2xx 但正文不含 access_token（疑似网关/契约变更）→ 按传输层异常处理，不登出');
        if (attempt == kRefreshMaxAttempts) break;
        await Future<void>.delayed(refreshBackoff(attempt));
      } catch (e) {
        final outcome = classifyRefreshError(e);
        if (outcome == RefreshOutcome.rejected) {
          _logHttp('!!! 刷新令牌被服务端拒绝 → 需要重新登录（$e）');
          return RefreshOutcome.rejected;
        }
        _logHttp('!!! 刷新令牌失败（第 $attempt/$kRefreshMaxAttempts 次，传输层）: $e');
        if (attempt == kRefreshMaxAttempts) break;
        await Future<void>.delayed(refreshBackoff(attempt));
      }
    }
    // 全部尝试都是传输层失败 → **绝不能**据此登出：客户多半只是网络/代理抖了一下
    return RefreshOutcome.transient;
  }

  /// 读 refresh token，存储异常时重试一次。
  /// 旧实现一次读失败就返回 null → 被当成「会话失效」→ 直接回登录页。
  Future<String?> _readRefreshTokenWithRetry() async {
    for (var i = 0; i < 2; i++) {
      final t = await readRefreshToken();
      if (t != null && t.isNotEmpty) return t;
      if (i == 0) await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }

  /// 逐域名实测延迟，返回**快到慢**的基底列表（失败/超时的排在后面）。
  ///
  /// 为什么必须客户端自测（2026-09-26 需求）：客户都是国内用户，各地 ISP 对
  /// 各域名的封锁与劣化完全不同 —— 在我这台机器上快的不等于在客户那儿快。
  /// 用公开的小接口（software-config，约 1KB，无需登录）做探测，避免为了排序
  /// 去拉 457KB 的订阅正文。
  ///
  /// 不经过本类拦截器（用一次性裸 Dio）：探测本身不该触发 401 刷新/域名轮换，
  /// 否则会互相递归。
  static Future<List<String>> probeDomainLatency({
    Duration timeout = const Duration(seconds: 3),
    List<String>? bases,
  }) async {
    final list = bases ?? ServerPool.instance.all;
    final dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      headers: {'Accept': 'application/json', 'User-Agent': userAgent},
    ));
    final ok = <({String base, int ms})>[];
    for (final base in list) {
      final sw = Stopwatch()..start();
      try {
        final r = await dio.getUri<List<int>>(
          Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/software-config'),
          options: Options(responseType: ResponseType.bytes),
        );
        sw.stop();
        if ((r.statusCode ?? 0) == 200) {
          ok.add((base: base, ms: sw.elapsedMilliseconds));
        }
      } catch (_) {
        // 探测失败的不参与排名（会被排到已知可用的后面）
      }
    }
    ok.sort((a, b) => a.ms.compareTo(b.ms));
    dio.close(force: true);
    return [for (final e in ok) e.base];
  }

  /// HTTP 日志文件（跨平台正确路径，惰性解析一次并缓存）。
  /// 旧实现每次请求同步 existsSync/createSync/writeAsStringSync：
  ///  - 阻塞调用 isolate（拦截器在主 isolate 跑）；
  ///  - 路径写死 HOME/Library/...（仅 macOS），Android 每次请求都失败重试；
  ///  - 无大小上限，日志无限增长。
  /// 改为：path_provider 解析一次 → 异步 fire-and-forget 追加 → 超 512KB 截断。
  static Future<File?>? _logFileFuture;

  /// http.log 串行写队列：append 与旋转依次执行，杜绝并发交错/半份改写
  static final SerialExecutor _logQueue = SerialExecutor();

  static Future<File?> _resolveLogFile() async {
    _logFileFuture ??= () async {
      try {
        final dir = await getApplicationSupportDirectory();
        return File('${dir.path}/http.log');
      } catch (_) {
        return null;
      }
    }();
    return _logFileFuture;
  }

  /// 响应体/请求体含凭据的敏感接口（登录/刷新/改密/验证码）。
  /// 这类路径的请求体与响应体都脱敏，避免 access_token/refresh_token 明文落盘。
  static const _sensitivePaths = [
    '/auth/login', '/auth/refresh', '/auth/register', '/auth/reset-password',
    '/auth/forgot-password', '/auth/verification', '/users/change-password',
  ];

  static bool _isSensitivePath(String path) =>
      _sensitivePaths.any((p) => path.contains(p));

  /// 日志用 URI 脱敏：query 含 token/subscribe_url 等敏感参数时整体打码，
  /// 避免订阅地址/token 明文落盘 http.log（凭据泄露风险）
  static String _maskUri(Uri u) {
    try {
      const sensitiveKeys = ['token', 'access_token', 'subscription_url', 'subscribe_url', 'key'];
      final q = u.queryParameters;
      if (q.keys.any(sensitiveKeys.contains)) {
        return u.replace(query: '[REDACTED]').toString();
      }
    } catch (_) {}
    return u.toString();
  }

  static void _logHttp(String line) {
    if (kIsWeb) return;
    // 不 await：日志写入绝不阻塞请求链路；经串行队列避免并发交错
    _logQueue.run(() async {
      try {
        final f = await _resolveLogFile();
        if (f == null) return;
        await f.writeAsString(
          '[${DateTime.now().toIso8601String()}] $line\n',
          mode: FileMode.append,
          flush: false,
        );
        // 大小上限：超 512KB 截断保留尾部（按整行，避免切半个字符）
        if (await f.length() > 512 * 1024) {
          final content = await f.readAsString();
          await f.writeAsString(keepSecondHalf(content), flush: true);
        }
      } catch (_) {}
    });
  }

  // ---------- 统一解包 ----------
  /// 后端业务错误（success:false）：抛出携带 message 的异常，
  /// 由 errorMsg() 归一化为中文提示，避免服务层拿到 null 后抛 TypeError
  static dynamic _unwrap(dynamic body) {
    if (body is Map && body['success'] == false) {
      final msg = body['message'] ?? body['error'] ?? body['detail'];
      throw ApiException(msg?.toString() ?? '请求失败，请稍后重试');
    }
    if (body is Map && body['success'] == true && body.containsKey('data')) {
      return body['data'];
    }
    // 兼容 success 缺失但带 data 的信封 / XBoard 原始返回
    if (body is Map && body.containsKey('data')) return body['data'];
    return body;
  }

  /// GET：返回解包后的 data
  Future<dynamic> get(String path,
      {Map<String, dynamic>? query, Map<String, dynamic>? extra}) async {
    final r = await _dio.get(path,
        queryParameters: query, options: Options(extra: extra));
    return _unwrap(r.data);
  }

  /// POST：返回解包后的 data；raw=true 时返回原始响应体。
  /// [extra] 传 {'_noSessionExpired': true} 可跳过 401 会话过期触发
  /// （logout 用：避免 token 失效后 logout 自身 401 → onSessionExpired →
  /// 再次 logout → 无限递归循环）。
  Future<dynamic> post(String path,
      {Object? data, bool raw = false, Map<String, dynamic>? extra}) async {
    final r = await _dio.post(path, data: data, options: Options(extra: extra));
    return raw ? r.data : _unwrap(r.data);
  }

  Future<dynamic> put(String path, {Object? data}) async {
    final r = await _dio.put(path, data: data);
    return _unwrap(r.data);
  }

  Future<dynamic> delete(String path, {Object? data}) async {
    final r = await _dio.delete(path, data: data);
    return _unwrap(r.data);
  }

  /// 拉取订阅原文（非 JSON）
  /// 订阅 URL 已带 type=clash 参数 → 后端按参数返回 Clash YAML；
  /// UA 默认用 MBox/<版本>（后端原生识别 mbox 客户端），可用 [ua] 覆盖。
  ///
  /// 三个健壮性要点：
  /// 1. **显式覆盖 `Accept: */*`**：全局默认 `application/json` 会诱导网关/后端
  ///    返回 JSON 或错误页而不是 Clash YAML；
  /// 2. **按响应魔数解压**：机场把 .gz/.zip 直接当正文返回（只给 Content-Type、
  ///    没有 `Content-Encoding`）时 dart:io 不会透明解压，会被 utf8 解成乱码 →
  ///    解析出 0 节点；
  /// 3. **按订阅自定义 UA**：部分机场按 UA 返回不同格式，用户需要能自救。
  Future<String> fetchText(String url, {String? ua}) async {
    final r = await _dio.getUri<List<int>>(
      Uri.parse(url),
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Accept': '*/*'},
        extra: {if (ua != null && ua.trim().isNotEmpty) '_ua': ua.trim()},
      ),
    );
    final bytes = r.data ?? const <int>[];
    return utf8.decode(_maybeDecompress(bytes), allowMalformed: true);
  }

  /// 按魔数解压订阅正文；无压缩特征时原样返回。
  /// zip 不引入额外依赖，直接给可读错误（比喂乱码去解析 0 节点强）。
  static List<int> _maybeDecompress(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      try {
        return gzip.decode(bytes);
      } catch (_) {}
    }
    if (bytes.length >= 2 && bytes[0] == 0x78) {
      try {
        return zlib.decode(bytes);
      } catch (_) {}
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      throw ApiException('订阅返回的是 zip 压缩包，请在服务端改为直接返回 Clash 配置');
    }
    return bytes;
  }

  // ---------- 错误归一化 ----------
  static String errorMsg(Object e) {
    if (e is ApiException) return e.message;
    if (e is DioException) {
      final d = e.response?.data;
      if (d is Map) {
        final msg = d['message'] ?? d['detail'] ?? d['error'];
        if (msg != null && msg.toString().isNotEmpty) return msg.toString();
      }
      if (d is String && d.isNotEmpty) {
        // 只在正文像「一句给人看的错误信息」时透出：短、且不是 HTML。
        // 网关/WAF/运营商的拦截页原样塞进提示框客户既看不懂，还会被
        // subscription_service 的关键词判据误用（把正在用的连接断开、清空节点）。
        final s = d.trim();
        final looksHtml = s.startsWith('<') ||
            s.contains('<html') ||
            s.contains('<!DOCTYPE') ||
            s.contains('<body');
        if (!looksHtml && s.length <= 200) return s;
      }
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.connectionError:
          return '网络连接失败，请检查网络后重试';
        case DioExceptionType.receiveTimeout:
          return '服务器响应超时，请稍后重试';
        case DioExceptionType.sendTimeout:
          return '发送请求超时，请稍后重试';
        case DioExceptionType.cancel:
          return '请求已取消';
        default:
          final code = e.response?.statusCode;
          if (code == 401) return '登录已过期，请重新登录';
          if (code == 403) return '没有权限执行此操作';
          if (code == 404) return '请求的资源不存在';
          if (code == 429) return '操作过于频繁，请稍后再试';
          if (code == 500) return '服务器开小差了，请稍后重试';
          return '请求失败（${code ?? '未知'}）';
      }
    }
    if (e is FormatException) return '数据解析失败';
    return e.toString();
  }
}

/// 后端业务错误异常（success:false 信封）
class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}
