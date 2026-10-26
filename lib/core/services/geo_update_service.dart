import 'dart:io';

import 'package:dio/dio.dart';

import 'app_log.dart';

import '../api/api_client.dart';
import '../api/gh_mirror.dart';
import '../proxy/geo_assets.dart';

/// 分流规则手动更新服务：在「设置 → 更新分流数据」中由用户主动触发，
/// 从官方源下载最新 geosite-cn.srs / geoip-cn.srs（sing-box binary rule-set）
/// 到本地可写副本目录，随后 [GeoAssets] 落盘内核目录时优先使用副本。
///
/// 设计要点（对应「构建自带 + 设置手动更新 + 启动零联网」）：
/// - **出厂自带**：安装包内置构建当天最新的 geo 数据(assets/rules)，离线可用；
/// - **启动/连接零联网**：运行链路只读内置或本地副本，从不联网；本服务只在
///   用户显式点击「检查并更新」时才发起下载，失败不影响软件与内核启动；
/// - 下载文件先写临时文件再原子改名，避免半包损坏覆盖可用副本；
/// - 更新后的副本在 supportDir/geo/ 持久保留，版本升级(老安装)不清除。
class GeoUpdateService {
  GeoUpdateService._();
  static final GeoUpdateService instance = GeoUpdateService._();

  /// 更新来源：SagerNet 官方规则集仓库的 **rule-set 分支**（与 CI 构建、
  /// tool/fetch_ruleset.sh 完全同源）。
  ///
  /// 注意：不能用 `releases/latest/download/*.srs` —— SagerNet 的 release
  /// 只发 `.db`（sing-box 1.14 尚不支持该格式），`.srs` 只存在于 rule-set
  /// 分支（实测 releases 路径 404，raw 分支 200）。
  static const _urls = {
    'geosite-cn.srs':
        'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs',
    'geoip-cn.srs':
        'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs',
  };

  /// 每个文件最小合理体积（字节）：.srs 二进制规则集约 0.4–2MB，
  /// 小于 32KB 视为坏包/错误页
  static const _minSize = 32 << 10;

  /// 下载客户端：裸 GitHub（不经 ApiClient，避免注入登录 token 导致 401）
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 20),
    followRedirects: true,
    headers: {'User-Agent': ApiClient.userAgent},
  ));

  static const files = ['geosite-cn.srs', 'geoip-cn.srs'];

  /// 是否已存在手动更新副本
  static Future<bool> hasManualCopy(String file) async {
    final dir = await GeoAssets.updatedDir();
    if (dir == null) return false;
    try {
      final f = File('$dir/$file');
      return await f.exists() && await f.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 检查并更新：逐个下载最新 geo 文件到副本目录。
  /// 返回 (成功文件数, 失败信息列表)；空错误列表 = 全部成功。
  Future<({int ok, List<String> errors})> update(
      {void Function(int done, int total)? onFile}) async {
    final dir = await GeoAssets.updatedDir();
    if (dir == null) {
      return (ok: 0, errors: ['无法获取本地存储目录']);
    }
    try {
      await Directory(dir).create(recursive: true);
    } catch (_) {}

    var ok = 0;
    final errors = <String>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      try {
        await _downloadOne(dir, file);
        ok++;
      } catch (e) {
        errors.add('$file: $e');
      }
      onFile?.call(i + 1, files.length);
    }
    // 只要有文件更新成功就记录时间（旧实现要求 ok == files.length）。
    // GeoAssets 依据这个时间戳决定是否把「手动副本」强制覆盖到内核目录；
    // 若部分成功（如 geoip-cn.srs 失败）就不记，则已下载成功的新
    // geosite-cn.srs 永远不会同步到内核目录 —— 用户看到「更新失败」，磁盘上
    // 却躺着一个永不生效的新副本。
    if (ok > 0) {
      await GeoAssets.markUpdatedAt(DateTime.now());
    }
    return (ok: ok, errors: errors);
  }

  /// 下载单个文件：**依次尝试直连 + 各国内加速镜像**，首个成功即用。
  ///
  /// 为什么必须走镜像（2026-10-18 客户实测「更新分流数据失败」的真因）：
  /// 旧实现直连 `github.com/.../releases/latest/download/...`，国内网络下
  /// 这个域名经常超时/被阻断（原本 120s 接收超时也救不回来），于是每次点
  /// 「检查并更新」都失败 —— 而 App 的「检查更新」早就用上了镜像（GhMirror），
  /// 这里漏了。
  ///
  /// 失败时把**每个候选的具体原因**汇总上抛，用户能看到"到底卡在哪"，
  /// 而不是一句"更新失败"。
  Future<void> _downloadOne(String dir, String file) async {
    final tmp = File('$dir/.$file.part');
    final target = File('$dir/$file');
    final candidates = GhMirror.candidates(_urls[file] ?? '');
    final failures = <String>[];

    for (final url in candidates) {
      final host = Uri.tryParse(url)?.host ?? 'direct';
      try {
        final r = await _dio.download(url, tmp.path, deleteOnError: true);
        if (r.statusCode != 200) {
          throw HttpException('HTTP ${r.statusCode}');
        }
        final size = await tmp.length();
        if (size < _minSize) {
          throw Exception('文件过小(${(size / 1024).round()}KB)');
        }
        // 原子替换：先删旧再改名（跨平台安全）
        if (await target.exists()) {
          try { await target.delete(); } catch (_) {}
        }
        await tmp.rename(target.path);
        AppLog.log('GEO', '分流数据 $file 下载成功（$host，${(size / 1024 / 1024).toStringAsFixed(1)}MB）');
        return; // 成功即止
      } catch (e) {
        failures.add('$host: ${_shortError(e)}');
        try { if (await tmp.exists()) await tmp.delete(); } catch (_) {}
      }
    }
    final msg = '所有下载通道都失败 → ${failures.join(' / ')}';
    AppLog.error('GEO 分流数据 $file 更新失败：$msg');
    throw Exception(msg);
  }

  /// 把异常压成一句话（超时/HTTP 码/文件过小），便于展示与排查
  static String _shortError(Object e) {
    final s = e.toString();
    if (s.contains('timeout') || s.contains('Timeout')) return '超时';
    if (e is HttpException) return s.replaceFirst('HttpException: ', '');
    if (s.contains('SocketException')) return '连接失败';
    if (s.contains('HandshakeException')) return 'TLS 握手失败';
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }
}
