import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../l10n/app_strings.dart';
import '../models/models.dart';
import 'app_log.dart';
import 'settings_store.dart';

/// 真实出口国家检测：连接成功后，通过隧道（本地混合代理端口，设置页可改，
/// 默认 2080）请求 IP 地理定位接口，返回**实际出口 IP 所在国家**——
/// 不是按节点名猜测。
class GeoLookupService {
  GeoLookupService._();
  static final GeoLookupService instance = GeoLookupService._();

  /// 本地混合代理端口默认值（与设置默认一致；实际值每次查询时读设置，
  /// 支持用户在设置页自定义端口）
  static const defaultPort = 2080;

  /// 清理缓存（切换账号/登出时调用，避免旧账号出口残留展示）
  void clearCache() {
    _cachedCode = null;
    _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 国家码 → 展示名。
  ///
  /// `'XX'` 是「无法识别」的内部哨兵值（见 ProxyNode._inferCountry），
  /// 绝不能原样显示 —— 用户看到的是一个写着「XX」的药丸（反馈原话：
  /// 「快速切换国家会显示一个国家XX 是什么意思」）。统一走本地化文案。
  static String countryName(String? code) {
    final c = code?.toUpperCase();
    if (c == null || c.isEmpty || c == 'XX') return AppStrings.t('country_unknown');
    return ProxyNode.countryNames[c] ?? c;
  }

  /// 结果缓存：连接成功后/切换节点会重复调用，10 分钟内命中直接返回，
  /// 避免每次用户动作都触发 1-2 次经隧道的外呼(ip-api 无 key 限 45/min)
  String? _cachedCode;
  DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _cacheTtl = Duration(minutes: 10);

  /// 最近一次定位失败时各源的错误摘要（供上层区分「节点不可用」与「目标侧问题」）
  String lastFailureDetail = '';

  /// 把异常压成一句可读的中文原因（日志/UI 展示用，避免整段 DioException 堆栈）
  static String _brief(Object e) {
    final s = e.toString();
    if (s.contains('HandshakeException')) return 'TLS 握手被中断';
    if (s.contains('Connection terminated')) return '连接被中断';
    if (s.contains('timeout') || s.contains('Timeout')) return '超时';
    if (s.contains('Connection refused')) return '连接被拒绝';
    if (s.contains('SocketException')) return '网络不可达';
    final i = s.indexOf('Error: ');
    return i >= 0 ? s.substring(i + 7, (i + 67).clamp(0, s.length)) : s;
  }

  /// 走隧道查询真实出口国家码；失败返回 null（不阻塞连接流程）。
  /// [force] 切换节点/国家、重新连接后出口 IP 已变，须强制重查绕过 TTL 缓存
  /// —— 否则 10 分钟内一直返回旧国家，表现为「切了国家真实出口不变」。
  Future<String?> lookupViaProxy({bool force = false}) async {
    // 缓存命中（10min 内）直接返回；force 时跳过读缓存（仍会写入新结果）
    final now = DateTime.now();
    if (!force && _cachedCode != null && now.difference(_cachedAt) < _cacheTtl) {
      return _cachedCode;
    }
    // 读当前生效的本地代理端口（设置页可改）：出口定位必须走同一个 mixed
    // 入站，端口不匹配时请求会落到空端口导致定位失败
    int port = defaultPort;
    try {
      final s = await SettingsStore.instance.load();
      port = (s['localPort'] as num?)?.toInt() ?? defaultPort;
    } catch (_) {}
    Dio? dio;
    final errors = <String>[];
    // 超时 8s（原 5s）：出口定位的外呼走刚建立的隧道，首包要等链路就绪 +
    // 握手 + 远端回源，5s 在跨境线路上偏紧，会把「慢但可用」判成失败
    // （日志里的 `The request connection took longer than 0:00:05` 即此）。
    const lookupTimeout = Duration(seconds: 8);
    try {
      dio = Dio(BaseOptions(
        connectTimeout: lookupTimeout,
        receiveTimeout: lookupTimeout,
        headers: {'Accept': 'application/json', 'User-Agent': 'MBox'},
      ));
      // 显式走本地混合代理（App 自身请求默认不走系统代理）
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.connectionTimeout = lookupTimeout;
          c.findProxy = (uri) => 'PROXY 127.0.0.1:$port';
          return c;
        },
      );

      // 主：Cloudflare trace（返回 loc=US 行；anycast 全球边缘、无按 IP 配额）。
      // ip-api.com 免费额度是按「来源 IP」限 45 次/分钟，而这里的查询走隧道、
      // 来源是出口节点 IP —— 同节点全部用户共享配额，上量后必然 429 全挂。
      // Cloudflare 无此问题，故为主源；ip-api / ipinfo 降为备用。
      for (var i = 0; i < 2; i++) {
        try {
          final r0 = await dio.get<String>(
            'https://www.cloudflare.com/cdn-cgi/trace',
            options: Options(responseType: ResponseType.plain),
          );
          final body = r0.data ?? '';
          final m =
              RegExp(r'^loc=([A-Za-z]{2})$', multiLine: true).firstMatch(body);
          final loc = m?.group(1)?.toUpperCase();
          // Cloudflare 定位不到时返回 loc=XX，视为无效落到备用源
          if (loc != null && loc != 'XX') {
            _cachedCode = loc;
            _cachedAt = DateTime.now();
            lastFailureDetail = '';
            return _cachedCode;
          }
          errors.add('cloudflare: 无有效 loc');
          break;
        } catch (e) {
          errors.add('cloudflare: ${_brief(e)}');
          // 隧道刚建立时首个外呼常因链路未就绪失败，短重试一次再换源
          if (i == 0) await Future.delayed(const Duration(milliseconds: 800));
        }
      }
      // 备 1：ip-api.com（免费无需 key，按出口 IP 限 45/min；http 免握手，最省）
      try {
        final r = await dio.get('http://ip-api.com/json?fields=countryCode,country');
        final d = r.data;
        if (d is Map && d['status'] == 'success' && d['countryCode'] != null) {
          _cachedCode = d['countryCode'].toString().toUpperCase();
          _cachedAt = DateTime.now();
          lastFailureDetail = '';
          return _cachedCode;
        }
        errors.add('ip-api: 返回异常');
      } catch (e) {
        errors.add('ip-api: ${_brief(e)}');
      }
      // 备 2：ipinfo.io（同样必须逐源捕获 —— 原先它没包 try/catch，
      // 其 TLS 异常会一路冒到外层，被记成一句含糊的「lookupViaProxy 失败」，
      // 掩盖了「三个源都挂了」这个真正的事实）
      try {
        final r2 = await dio.get('https://ipinfo.io/json');
        final d2 = r2.data;
        if (d2 is Map && d2['country'] != null) {
          _cachedCode = d2['country'].toString().toUpperCase();
          _cachedAt = DateTime.now();
          lastFailureDetail = '';
          return _cachedCode;
        }
        errors.add('ipinfo: 返回异常');
      } catch (e) {
        errors.add('ipinfo: ${_brief(e)}');
      }
    } catch (e) {
      errors.add('其它: ${_brief(e)}');
    } finally {
      dio?.close(force: true);
    }
    // 三个源全部失败：**不在此处打 ERROR**（出口定位是辅助功能，失败不等于连接
    // 失败；由调用方结合节点测速结果判定，避免日志里出现误导性的红色错误）
    lastFailureDetail = errors.join(' | ');
    AppLog.log('GEO', '出口定位失败（$lastFailureDetail）');
    return null;
  }
}
