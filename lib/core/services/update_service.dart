import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/gh_mirror.dart';
import '../api/user_agent.dart';
import 'app_log.dart';
import 'single_instance.dart';

/// macOS 就地安装的结果
enum MacInstallResult {
  /// 已替换 /Applications 里的 App 并拉起新版本
  installed,

  /// 只能把安装包交给用户手动装（开发模式运行、或权限不足时的降级）
  openedExternally,

  /// 安装包损坏（挂载失败 / 卷里没有 .app）—— 多半是下载不完整
  damaged,

  /// 其它失败（复制失败、替换失败、权限不足……）
  failed,
}

/// 软件升级信息
class UpdateInfo {
  final String latestVersion;
  final String? downloadUrl;
  final String? sizeText;
  final bool forced;

  /// 与本机平台/架构匹配的那个安装包的文件名（下载落盘用它命名）
  final String? assetName;

  /// 该安装包在 `SHA256SUMS*.txt` 里的校验值（拿不到则为空）
  final String sha256;

  /// 该安装包的精确字节数（GitHub API 给的，用于判断**已缓存的包是否下完整**）。
  /// 0 = 未知。
  final int sizeBytes;

  UpdateInfo({
    required this.latestVersion,
    this.downloadUrl,
    this.sizeText,
    this.forced = false,
    this.assetName,
    this.sha256 = '',
    this.sizeBytes = 0,
  });

  bool get isNewer {
    final cur = _parse(currentVersion);
    final latest = _parse(latestVersion);
    if (cur == null || latest == null) return latestVersion != currentVersion;
    return latest.compareTo(cur) > 0;
  }

  static String? _parse(String v) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(v);
    if (m == null) return null;
    return '${int.parse(m.group(1)!).toString().padLeft(3, '0')}'
        '${int.parse(m.group(2)!).toString().padLeft(3, '0')}'
        '${int.parse(m.group(3)!).toString().padLeft(3, '0')}';
  }

  static String currentVersion = '0.0.1';
}

/// 软件升级服务：检测 GitHub Releases 最新版 → **后台下载匹配本机的安装包**
/// → 点击「立即更新」直接调起安装器（对齐 mclash 的更新体验）。
///
/// 为什么不能只丢一个下载链接：
/// - 用户得自己找对平台/架构的包（下错架构会启动即崩）；
/// - 浏览器下载完还要手动找文件双击；
/// - 下载中没有任何进度反馈。
/// 现在这些都由客户端完成：挑包 → 预下载（带进度、校验 sha256）→ 调起安装器。
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  /// 初始化：读取当前应用版本（flutter_test 环境跳过，避免平台通道挂起）
  /// 并用真实包版本 + OS 特征串刷新 User-Agent
  Future<void> init() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final info = await PackageInfo.fromPlatform();
      UpdateInfo.currentVersion = info.version;
      ApiClient.userAgent = await UserAgent.resolve(version: info.version);
    } catch (_) {}
  }

  /// GitHub Releases 最新版本信息（缓存 5 分钟）
  static UpdateInfo? _cacheInfo;
  static DateTime _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 最近一次检查到的更新信息（弹窗用它拿版本号/体积/下载地址）
  static UpdateInfo? get lastInfo => _cacheInfo;

  /// 是否有新版本（全局红点：底部「我的」tab、设置「版本更新」行共用）。
  /// 启动后台检查与设置页手动检查都会刷新它。
  static final ValueNotifier<bool> hasUpdate = ValueNotifier(false);

  /// 后台下载进度（0~1；null = 未在下载）
  static final ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  static const String githubRepo = 'moneyfly004/m-box';

  /// GitHub API 专用裸客户端（不经 [ApiClient]）。
  /// 更新检测不能复用后端通道：ApiClient 会为每个请求注入
  /// `Authorization: Bearer <登录 token>`，GitHub 对无效 Bearer 一律返回 401
  /// （实测日志 Bad credentials）→ 检测永远失败、UI 误报「已是最新版本」。
  /// 这里不带任何登录态，只带 UA 直连 GitHub。
  static final Dio _ghDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    sendTimeout: const Duration(seconds: 15),
    headers: {'Accept': 'application/json', 'User-Agent': ApiClient.userAgent},
  ));

  /// 上一次 check() 是否**因为失败**而没拿到结果（网络全不通 / 面板不可用），
  /// 与「已是最新版本」是两件事：UI 必须据此显示「检查更新失败」而不是「已是最新」。
  bool lastCheckFailed = false;

  /// 测试缝：替换 GitHub 裸客户端（单测用假适配器覆盖「直连不通 → 走镜像」分支）
  @visibleForTesting
  static Dio? debugGhDio;

  static Dio get _gh => debugGhDio ?? _ghDio;

  /// 最近一次成功的通道下标（0 = 直连，>0 = [GhMirror.prefixes] 里第 n 个镜像）。
  /// 记住它有两个作用：后续的校验和与安装包下载直接走同一通道，不必各自再试错一轮；
  /// 「打开下载页」也能据此把 GitHub 直链换成国内镜像地址。
  static int _ghChannel = 0;

  /// 当前是否已在走镜像通道（供日志/排查使用）
  static bool get usingGhMirror => _ghChannel > 0;

  /// 候选尝试顺序：先试上次成功的通道，再按「直连 → 各镜像」补齐其余。
  static List<int> _attemptOrder(String url) {
    final n = GhMirror.candidates(url).length;
    if (n <= 1) return [for (var i = 0; i < n; i++) i];
    final start = _ghChannel.clamp(0, n - 1);
    return [start, for (var i = 0; i < n; i++) if (i != start) i];
  }

  /// 带镜像兜底的请求：直连不通（连接层错误/超时）就依次换镜像重试；
  /// 全部失败返回 null 并记日志（调用方各自决定「当作没有更新」还是「放弃校验」）。
  static Future<T?> _withMirrorFallback<T>(
    String url,
    Future<T> Function(String url) attempt,
  ) async {
    Object? lastError;
    for (final idx in _attemptOrder(url)) {
      final candidate = GhMirror.at(url, idx);
      try {
        final result = await attempt(candidate);
        if (idx != _ghChannel) {
          AppLog.net(
              'GitHub 通道切换为${idx == 0 ? '直连' : '镜像 #$idx'}（$candidate）');
        }
        _ghChannel = idx;
        return result;
      } catch (e) {
        lastError = e;
      }
    }
    AppLog.error('GitHub 直连与镜像均不可用: $url（$lastError）');
    return null;
  }

  /// 供「打开下载页」用：把 GitHub 直链换成当前已确认可用的通道地址。
  /// 直连正常（从未切换过通道）时原样返回，不改变既有行为。
  static String mirroredUrl(String url) =>
      _ghChannel == 0 ? url : GhMirror.at(url, _ghChannel);

  /// 测试缝：替换整段「查最新版本」逻辑（单测不打网络）
  @visibleForTesting
  static Future<UpdateInfo?> Function()? debugCheckOverride;

  /// 测试缝：替换真实下载（单测不写盘、不打网络）
  @visibleForTesting
  static Future<void> Function(String url, String savePath)? debugDownloadOverride;

  /// 测试缝：替换「调起安装器」
  @visibleForTesting
  static Future<bool> Function(String path)? debugLaunchInstallerOverride;

  /// 测试缝：替换缓存目录
  @visibleForTesting
  static Future<Directory?> Function()? debugCacheDir;

  /// 检查更新：读取 GitHub Releases 最新版 → 比对 → 返回更新信息。
  /// 网络异常返回 null（UI 提示已是最新或稍后再试）。
  Future<UpdateInfo?> check() async {
    final override = debugCheckOverride;
    if (override != null) {
      final info = await override();
      _cacheInfo = info;
      hasUpdate.value = info?.isNewer ?? false;
      return info;
    }
    // 5 分钟缓存，避免重复请求限流
    if (_cacheInfo != null &&
        DateTime.now().difference(_cacheAt) < const Duration(minutes: 5)) {
      hasUpdate.value = _cacheInfo!.isNewer;
      return _cacheInfo;
    }
    // 先问 GitHub（信息最全）；直连不通时再问自己的面板（见 _checkViaPanel）
    lastCheckFailed = false;
    final info = await _checkViaGitHub() ?? await _checkViaPanel();
    if (info == null) {
      // 两条路都没拿到结果 = **检查失败**，不是「已是最新」。
      // 旧实现在这里直接 return null，而 UI 只在抛异常/超时时才判 failed，
      // 于是国内网络（GitHub + 4 个镜像 + 面板全不通）会看到
      // 「已是最新版本」，实际早有新版 —— 用户永远停在旧版还自认为最新。
      lastCheckFailed = true;
      return null;
    }
    _cacheInfo = info;
    _cacheAt = DateTime.now();
    hasUpdate.value = info.isNewer;
    return info;
  }

  /// 直接问 GitHub Releases API（带镜像兜底；网络异常/取不到包返回 null）
  Future<UpdateInfo?> _checkViaGitHub() async {
    try {
      // 直连 api.github.com 在国内常超时/被阻断 → 依次退到镜像（见 GhMirror）
      final data = await _withMirrorFallback<dynamic>(
        'https://api.github.com/repos/$githubRepo/releases/latest',
        (u) async => (await _gh.get(u)).data,
      );
      if (data is! Map) return null;
      final tag = data['tag_name']?.toString() ?? '';
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (version.isEmpty) return null;

      // 按平台匹配资产（同时取回被选中资产的体积，保证展示与实际下载一致）
      final assets = (data['assets'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final picked = await _pickAsset(assets);
      if (picked == null) return null;

      return UpdateInfo(
        latestVersion: version,
        downloadUrl: picked.url,
        sizeText: _sizeText(picked.size),
        assetName: picked.name,
        // 顺带取 sha256：下载完校验完整性（拿不到就跳过校验，不阻塞更新）
        sha256: await _fetchSha256(assets, picked.name),
        sizeBytes: picked.size,
      );
    } catch (_) {
      return null;
    }
  }

  /// 问自己的面板：服务器代查 GitHub（`GET /api/v1/software/latest`）。
  ///
  /// 为什么必须有这条兜底（2026-09-23 实测）：GitHub 加速镜像**只代理 Release
  /// 资产、不代理 API**（ghfast.top 对 api.github.com 返回 403，gh.ddlc.top 404），
  /// 所以「App 端换镜像」解决不了国内检查更新失败；而服务器本身能直连 GitHub。
  /// 这条路径只依赖「App 能连上自己的面板」—— 那正是 ServerPool 已经保证的事
  /// （多域名 + 连不上自动换域名）。
  static Future<Map?> Function(String configKey)? debugPanelLatestOverride;

  Future<UpdateInfo?> _checkViaPanel() async {
    final key = await _panelConfigKey();
    if (key.isEmpty) return null; // 该平台面板没有对应入口（如 iOS 侧载包）
    Map<String, dynamic>? data;
    try {
      final override = debugPanelLatestOverride;
      if (override != null) {
        final r = await override(key);
        data = r == null ? null : Map<String, dynamic>.from(r);
      } else {
        final r = await ApiClient.instance
            .get('/software/latest', query: {'key': key});
        if (r is Map) data = Map<String, dynamic>.from(r);
      }
    } catch (e) {
      AppLog.net('面板代查最新版本失败: $e');
      return null;
    }
    if (data == null) return null;

    final version = (data['version'] ?? '').toString().trim();
    final assetName = (data['asset_name'] ?? '').toString().trim();
    if (version.isEmpty || assetName.isEmpty) return null;
    final size = (data['size_bytes'] as num?)?.toInt() ?? 0;
    final rawUrl = (data['download_url'] ?? '').toString().trim();
    if (rawUrl.isEmpty) return null; // 拿不到下载地址就没法更新，不如如实返回 null
    // 面板可能还配着**旧仓库/旧产物名**的地址（moneyfly004/moneyfly、MoneyFly-*）。
    // 这里统一归一化到新仓库，避免把用户带回老 release。
    final url = normalizeReleaseUrl(rawUrl);
    final normalizedAsset = normalizeAssetName(assetName);

    return UpdateInfo(
      latestVersion: version,
      downloadUrl: url,
      sizeText: _sizeText(size),
      assetName: normalizedAsset,
      sha256: (data['sha256'] ?? '').toString().trim(),
      sizeBytes: size,
    );
  }

  /// 旧仓库 → 新仓库（moneyfly004/moneyfly → moneyfly004/m-box）
  static const String legacyRepo = 'moneyfly004/moneyfly';

  /// 把任意 release 地址归一化到当前仓库与产物命名。
  ///
  /// 为什么需要：面板（后端「软件下载配置」）里可能仍写着旧仓库地址或旧产物名
  /// （MoneyFly-setup-x.y.z.exe / MoneyFly-macos-arm64-*.dmg）。不归一化的话，
  /// 应用内「检查更新 → 下载」会把用户带到**老 release**（甚至 404）。
  /// 只做纯字符串改写，非 GitHub 地址原样返回。
  static String normalizeReleaseUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (u.contains(legacyRepo)) {
      u = u.replaceAll(legacyRepo, githubRepo);
    }
    // 旧产物名 → 新产物名（只改**文件名主体**，不动路径）
    final slash = u.lastIndexOf('/');
    if (slash >= 0) {
      final head = u.substring(0, slash + 1);
      final name = u.substring(slash + 1);
      u = head + normalizeAssetName(name);
    }
    return u;
  }

  /// 旧产物名 → 新产物名（MoneyFly-* → MBox-*）
  static String normalizeAssetName(String name) {
    final n = name.trim();
    if (n.startsWith('MoneyFly-')) return 'MBox-${n.substring('MoneyFly-'.length)}';
    return n;
  }

  /// 本平台在面板「软件下载配置」里的键名（与后端同步目录的 ConfigKey 一致）
  static Future<String> _panelConfigKey() async {
    if (kIsWeb) return '';
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'moneyfly_windows_url';
      case TargetPlatform.android:
        return 'moneyfly_android_url';
      case TargetPlatform.macOS:
        return await _isMacIntel()
            ? 'moneyfly_macos_url'
            : 'moneyfly_macos_arm_url';
      default:
        // iOS 走侧载 IPA，面板没有对应入口 → 不兜底（与「检查失败」同表现）
        return '';
    }
  }

  /// 选择本平台安装包资产(macOS 按真实架构选 arm64/x64 dmg,避免 Intel 拿到 arm64)
  static Future<({String url, int size, String name})?> _pickAsset(
      List<Map> assets) async {
    final entries = assets
        .map((a) => (
              name: a['name']?.toString() ?? '',
              url: a['browser_download_url']?.toString() ?? '',
              size: (a['size'] as num?)?.toInt() ?? 0,
            ))
        .toList();
    if (kIsWeb) return null;
    // 本平台的**可接受前缀集合**：兜底也只在集合内挑，避免把 Android APK
    // 或另一架构的包发给当前平台（旧兜底是「名字含 MBox- 就用」）。
    final List<String> prefixes;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // 主流机型 arm64-v8a(个别老 32 位机型请手动装对应 APK)
        prefixes = const ['MBox-android-arm64-v8a-'];
        break;
      case TargetPlatform.iOS:
        // iOS 走侧载分发（IPA 挂 GitHub Releases）：TrollStore / 自签安装。
        // 只提示新版本 + 给出 IPA 下载地址，不在 App 内自更新（系统不允许）。
        prefixes = const ['MBox-ios-'];
        break;
      case TargetPlatform.macOS:
        prefixes = await _isMacIntel()
            ? const ['MBox-macos-x64-']
            : const ['MBox-macos-arm64-'];
        break;
      case TargetPlatform.windows:
        prefixes = const ['MBox-setup-'];
        break;
      default:
        return null; // 未知平台：宁可不提示更新，也不给错包
    }
    for (final p in prefixes) {
      for (final e in entries) {
        if (e.name.startsWith(p) && e.url.isNotEmpty) {
          return (url: e.url, size: e.size, name: e.name);
        }
      }
    }
    // 宽松兜底仍限定在同平台前缀内（例如版本号命名变化导致前缀不完全匹配）
    final platTag = prefixes.first.replaceAll(RegExp(r'(x64|arm64|arm64-v8a|ia32)-$'), '');
    for (final e in entries) {
      if (e.url.isNotEmpty && e.name.startsWith(platTag)) {
        return (url: e.url, size: e.size, name: e.name);
      }
    }
    return null;
  }

  static Future<bool> _isMacIntel() async {
    try {
      final r = await Process.run('uname', ['-m']);
      final out = (r.stdout as String).trim();
      return out.contains('x86_64');
    } catch (_) {
      return false;
    }
  }

  static String? _sizeText(int size) {
    if (size <= 0) return null;
    if (size >= 1 << 30) return '${(size / (1 << 30)).toStringAsFixed(1)} GB';
    if (size >= 1 << 20) return '${(size / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }

  /// 从 `SHA256SUMS*.txt` 里取本平台安装包的校验值（缺失返回空串）。
  static Future<String> _fetchSha256(List<Map> assets, String assetName) async {
    // 候选校验和文件名：先平台/架构专属那份，再退回发布时合并的 SHA256SUMS.txt。
    // 两个都留着是有原因的：合并文件由 release job 生成（覆盖全部 10 个产物），
    // 而专属文件由各构建 job 生成 —— 任一步骤改动都不该让「校验」整条失效。
    final candidates = <String>[
      switch (defaultTargetPlatform) {
        TargetPlatform.android => 'SHA256SUMS-android-apk.txt',
        TargetPlatform.windows => 'SHA256SUMS-windows.txt',
        TargetPlatform.iOS => 'SHA256SUMS-ios.txt',
        TargetPlatform.macOS => assetName.contains('-macos-arm64-')
            ? 'SHA256SUMS-macos-arm64.txt'
            : assetName.contains('-macos-universal-')
                ? 'SHA256SUMS-macos-universal.txt'
                : 'SHA256SUMS-macos-x64.txt',
        _ => '',
      },
      'SHA256SUMS.txt',
    ];
    for (final sumsName in candidates) {
      if (sumsName.isEmpty) continue;
      final sums = assets
          .where((a) => a['name'] == sumsName)
          .map((a) => a['browser_download_url']?.toString() ?? '')
          .firstWhere((u) => u.isNotEmpty, orElse: () => '');
      if (sums.isEmpty) continue;
      // 校验和与安装包走同一通道：既然直连不通，独立再试一轮只会让用户白等
      final text = await _withMirrorFallback<String>(
            sums,
            (u) async =>
                (await _gh.get<String>(u,
                            options:
                                Options(responseType: ResponseType.plain)))
                        .data ??
                    '',
          ) ??
          '';
      for (final line in text.split('\n')) {
        if (!line.contains(assetName)) continue;
        // 兼容 Windows 上 sha256sum 的二进制模式标记：`<hash> *<name>`
        final hash = line.trim().split(RegExp(r'\s+')).first.toLowerCase();
        if (hash.length == 64) return hash;
      }
    }
    return '';
  }

  // ==================== 下载 / 安装（对齐 mclash 的更新体验）====================

  /// 测试缝：强制「本平台支持应用内安装」。
  ///
  /// 为什么必须有：CI 的 Android job 在 **ubuntu** 上跑测试，而真实判定依赖
  /// 宿主平台 → 那里恒为 false，凡是断言「点了立即更新就会调起安装器」的用例
  /// 都会红（实测 v2.2.9 就是这么挂的）。把判定做成可注入，用例就能在任意宿主
  /// 上覆盖两条分支。
  @visibleForTesting
  static bool? debugCanInstallInApp;

  /// 本平台是否支持**应用内直接调起安装**
  ///
  /// 只有桌面端（Windows / macOS）走应用内安装：这两者「下载完 → 打开安装包 →
  /// 退出自己」是纯文件操作，行为确定。移动端一律走浏览器下载页：
  /// - iOS 系统不允许自更新（侧载 IPA）；
  /// - Android 需要 FileProvider + 安装意图 + REQUEST_INSTALL_PACKAGES 权限，
  ///   属于原生改动且真机行为无法在开发机上验证（曾因此把 CI 的 assembleRelease
  ///   搞挂）。与其带一个验证不了的原生路径，不如老老实实打开下载页。
  static bool get canInstallInApp =>
      debugCanInstallInApp ?? (!kIsWeb && (Platform.isWindows || Platform.isMacOS));

  Future<Directory?> _updateDir() async {
    final base = debugCacheDir != null
        ? await debugCacheDir!()
        : await getApplicationCacheDirectory();
    if (base == null) return null;
    final dir = Directory('${base.path}/update');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 已下载安装包的路径（存在、非空、且**大小与发布方给出的字节数一致**才有值）。
  ///
  /// 这里以前只判 `lengthSync() > 0`，于是**半截文件会被当成「已下好」**：
  /// 下载中途退出/断网留下的残包，之后每次点更新都直接拿它去装 ——
  /// 表现就是 macOS 挂载失败（用户看到「磁盘映像已损坏/无法识别」，即
  /// 「点击安装 → 提示磁盘损坏」）。现在大小不符直接删掉重新下。
  Future<String?> downloadedInstaller([UpdateInfo? info]) async {
    final i = info ?? _cacheInfo;
    final name = i?.assetName;
    if (name == null || name.isEmpty) return null;
    final dir = await _updateDir();
    if (dir == null) return null;
    final f = File('${dir.path}/$name');
    if (!f.existsSync() || f.lengthSync() == 0) return null;
    final expect = i?.sizeBytes ?? 0;
    if (expect > 0 && f.lengthSync() != expect) {
      AppLog.error('更新包不完整（${f.lengthSync()} != $expect），丢弃重下: $name');
      try {
        f.deleteSync();
      } catch (_) {}
      return null;
    }
    return f.path;
  }

  /// 安装前再核一次 sha256（有校验值时必须一致，否则删包返回 false）。
  /// 缓存命中路径也要核：只有「下载那一刻」校验过是不够的 —— 磁盘写坏、
  /// 手动替换、下载被 kill 都可能留下一个大小正确但内容错误的包。
  Future<bool> verifyInstaller(String path, [UpdateInfo? info]) async {
    final i = info ?? _cacheInfo;
    final expect = (i?.sha256 ?? '').toLowerCase();
    if (expect.isEmpty) return true; // 发布方没给校验值：不阻塞安装（大小已核过）
    final key = '$path|$expect';
    if (_verifiedSha[key] == true) return true;
    try {
      final actual = await _sha256Of(File(path));
      if (actual == expect) {
        _verifiedSha[key] = true;
        return true;
      }
      AppLog.error('更新包校验失败（sha256 不匹配），丢弃: $path');
      try {
        File(path).deleteSync();
      } catch (_) {}
      _verifiedSha.remove(key);
      return false;
    } catch (e) {
      AppLog.error('更新包校验异常: $e');
      return false;
    }
  }

  /// sha256 校验结果缓存（key = 路径|期望值）：避免弹窗/安装流程重复哈希几十 MB
  static final Map<String, bool> _verifiedSha = {};

  /// 后台/前台下载本机匹配的安装包（幂等：已下好直接返回路径）。
  ///
  /// [onProgress] 0~1；有 sha256 就校验，校验失败会删掉文件并返回 null
  /// （宁可让用户重新下，也不装一个被篡改/下坏的包）。
  Future<String?> downloadInstaller({
    UpdateInfo? info,
    void Function(double progress)? onProgress,
  }) async {
    final i = info ?? _cacheInfo;
    final url = i?.downloadUrl;
    final name = i?.assetName;
    if (url == null || url.isEmpty || name == null || name.isEmpty) return null;
    final dir = await _updateDir();
    if (dir == null) return null;
    final path = '${dir.path}/$name';
    final dest = File(path);
    if (dest.existsSync() && dest.lengthSync() > 0) {
      // 缓存命中也要「大小 + sha256」过关才算数（见 downloadedInstaller 的说明）
      final sizeOk = i!.sizeBytes <= 0 || dest.lengthSync() == i.sizeBytes;
      if (sizeOk && await verifyInstaller(path, i)) {
        downloadProgress.value = 1;
        return path;
      }
      try {
        dest.deleteSync();
      } catch (_) {}
    }
    // 并发去重：后台预下载与用户点「立即更新」会同时触发同一份下载，
    // 两个写入方写同一个文件会把包写坏 → 后来的等前一个的结果。
    final pending = _inFlight[name];
    if (pending != null) return pending;
    final task = _downloadTo(url, name, path, dest, onProgress, i!.sha256);
    _inFlight[name] = task;
    try {
      return await task;
    } finally {
      // ignore: unawaited_futures — Map.remove 返回被删的 Future，这里只是清理表项
      _inFlight.remove(name);
    }
  }

  static final Map<String, Future<String?>> _inFlight = {};

  static Future<String?> _downloadTo(String url, String name, String path,
      File dest, void Function(double progress)? onProgress,
      String expectSha) async {
    final override = debugDownloadOverride;
    downloadProgress.value = 0;
    try {
      if (override != null) {
        await override(url, path);
      } else {
        // 下载同样带镜像兜底：几十 MB 的包直连 github.com 在国内大概率半路断，
        // 逐个候选重试；每次重试前清掉半截文件，避免续写出一个坏包。
        Object? lastError;
        var downloaded = false;
        for (final idx in _attemptOrder(url)) {
          final candidate = GhMirror.at(url, idx);
          try {
            await _gh.download(candidate, path,
                onReceiveProgress: (received, total) {
              if (total <= 0) return;
              final p = received / total;
              downloadProgress.value = p;
              onProgress?.call(p);
            });
            _ghChannel = idx;
            downloaded = true;
            break;
          } catch (e) {
            lastError = e;
            downloadProgress.value = 0;
            try {
              if (dest.existsSync()) dest.deleteSync();
            } catch (_) {}
          }
        }
        if (!downloaded) {
          AppLog.error('安装包下载失败（直连 + 镜像均不可用）: $url（$lastError）');
          downloadProgress.value = null;
          return null;
        }
      }
      // 校验值取自**本次下载用的 info**：早先写成读全局缓存，导致「显式传 info
      // 的调用」压根不校验（单测直接抓到：给了错哈希仍然返回成功）。
      if (expectSha.isNotEmpty) {
        final actual = await _sha256Of(dest);
        if (actual != expectSha) {
          try {
            dest.deleteSync();
          } catch (_) {}
          downloadProgress.value = null;
          return null;
        }
      }
      downloadProgress.value = 1;
      return path;
    } catch (_) {
      try {
        if (dest.existsSync()) dest.deleteSync();
      } catch (_) {}
      downloadProgress.value = null;
      return null;
    }
  }

  static Future<String> _sha256Of(File f) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  /// 测试用：算一段字节的 sha256（避免测试自己再引一份 crypto 实现）
  @visibleForTesting
  static String sha256HexForTest(List<int> bytes) => sha256.convert(bytes).toString();

  /// 「重启即更新」用：缓存里已下好、且比当前版本新的安装包。
  ///
  /// 只认本平台的安装器文件名前缀（Windows: `MBox-setup-<ver>.exe`），
  /// 版本从文件名解析并与当前版本比较 —— 比当前版本旧或相同的缓存一律忽略
  /// （用户手里可能留着老包）。多个候选取版本最高的。
  Future<({String path, String version})?> pendingNewerInstaller() async {
    final dir = await _updateDir();
    if (dir == null || !dir.existsSync()) return null;
    ({String path, String version})? best;
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.isEmpty ? '' : f.uri.pathSegments.last;
      final m = RegExp(r'^MBox-setup-(\d+\.\d+\.\d+)\.exe$').firstMatch(name);
      if (m == null) continue;
      final v = m.group(1)!;
      if (!_newerThanCurrent(v)) continue;
      if (f.lengthSync() == 0) continue;
      if (best == null || _versionKey(v).compareTo(_versionKey(best.version)) > 0) {
        best = (path: f.path, version: v);
      }
    }
    return best;
  }

  static String _versionKey(String v) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(v);
    if (m == null) return v;
    return '${int.parse(m.group(1)!).toString().padLeft(6, '0')}'
        '${int.parse(m.group(2)!).toString().padLeft(6, '0')}'
        '${int.parse(m.group(3)!).toString().padLeft(6, '0')}';
  }

  static bool _newerThanCurrent(String v) =>
      _versionKey(v).compareTo(_versionKey(UpdateInfo.currentVersion)) > 0;

  /// 当前是否以「安装版」形态运行（%LOCALAPPDATA%\Programs\MoneyFly）。
  ///
  /// 便携版（解压 zip 直接跑）不该走静默自动安装：那会装出第二份到
  /// Programs 目录，而用户双击的还是旧的便携 exe，观感更糟。
  static bool get runningFromInstalledLayout {
    if (!Platform.isWindows) return false;
    final local = (Platform.environment['LOCALAPPDATA'] ?? '')
        .replaceAll('\\', '/')
        .toLowerCase();
    if (local.isEmpty) return false;
    final exe =
        Platform.resolvedExecutable.replaceAll('\\', '/').toLowerCase();
    return exe.startsWith('$local/programs/moneyfly/');
  }

  /// 测试缝：替换「分离式启动安装器」（返回是否成功启动）
  static Future<bool> Function(String exe, List<String> args)?
      debugStartDetached;

  /// Windows：静默安装（无向导、自动关占用进程、不重启系统；装完由安装器
  /// 自己把 App 拉起来 —— 见 scripts/windows_installer.iss 的 [Run]）。
  ///
  /// 参数含义（Inno Setup 官方开关）：
  ///   /SILENT            只有进度条，不弹向导（"热更新"的关键）
  ///   /SP-               连"即将安装"的确认框也跳过
  ///   /CLOSEAPPLICATIONS 自动结束占用待替换文件的进程（正在运行的旧版本）
  ///   /NORESTART         即使需要也不要重启系统
  ///   /SUPPRESSMSGBOXES  静默模式下不弹任何消息框
  Future<bool> installWindowsSilently(String path) async {
    final args = const [
      '/SILENT',
      '/SP-',
      '/CLOSEAPPLICATIONS',
      '/NORESTART',
      '/SUPPRESSMSGBOXES',
    ];
    final start = debugStartDetached;
    if (start != null) return start(path, args);
    try {
      await Process.start(path, args, mode: ProcessStartMode.detached);
      return true;
    } catch (e) {
      AppLog.error('silent install failed: $e');
      return false;
    }
  }

  /// 调起系统安装器（Windows 打开 exe；macOS 走 [installMacDmg] 就地替换）。
  /// **不退出进程** —— 退出由上层在断连后决定，避免装到一半内核还在跑。
  Future<bool> launchInstaller(String path) async {
    final override = debugLaunchInstallerOverride;
    if (override != null) return override(path);
    if (Platform.isMacOS) {
      // 旧实现这里是 `open <dmg>`：只是把安装包丢给 Finder，用户还得自己把
      // App 拖进「应用程序」—— 这不是「自动安装」，而且拖出来的 App 带着
      // 隔离属性时 Gatekeeper 会直接报「已损坏」。现在自己做完整流程。
      final r = await installMacDmg(path);
      return r == MacInstallResult.installed ||
          r == MacInstallResult.openedExternally;
    }
    if (Platform.isWindows) {
      try {
        return await launchUrl(Uri.file(path),
            mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// macOS 就地安装结果
  @visibleForTesting
  static Future<MacInstallResult> Function(String dmg)? debugInstallMacOverride;

  /// 测试缝：替换进程调用（真实路径要挂 DMG、复制几十 MB、替换 App）
  @visibleForTesting
  static Future<ProcessResult> Function(String exe, List<String> args)?
      debugRunProcess;

  /// 测试缝：替换「用系统默认程序打开某个文件」（测试环境里 launchUrl 永不返回）
  @visibleForTesting
  static Future<bool> Function(String path)? debugOpenFileOverride;

  /// 测试缝：覆盖「当前 App 包路径」（测试进程不在 .app 里，真实推断恒为 null）
  @visibleForTesting
  static String? debugAppBundlePath;

  /// 挂载 DMG → 复制出 .app（**不带隔离属性**）→ 替换当前 App → 重新启动。
  ///
  /// 为什么要自己做而不是 `open <dmg>`：
  ///  1. 真正的自动更新：用户点一次就完事，不需要手动拖进「应用程序」；
  ///  2. **隔离属性**：从 DMG 里拖出来的 App 可能带 `com.apple.quarantine`，
  ///     而我们的 App 是 ad-hoc 签名（无 TeamIdentifier），一旦被隔离，
  ///     Gatekeeper 只会报「已损坏，无法打开」—— 用 `ditto --noqtn` + 
  ///     `xattr -dr com.apple.quarantine` 从根上避免；
  ///  3. 挂载失败能区分出「安装包损坏」（半截下载）并让 UI 给出正确指引。
  Future<MacInstallResult> installMacDmg(String dmgPath) async {
    final override = debugInstallMacOverride;
    if (override != null) return override(dmgPath);
    if (!Platform.isMacOS) return MacInstallResult.failed;
    final run = debugRunProcess ??
        (String exe, List<String> args) => Process.run(exe, args);
    if (!File(dmgPath).existsSync()) return MacInstallResult.failed;

    final target = currentAppBundlePath();
    if (target == null) {
      // 不是从 .app 里跑（开发模式/命令行）：只能退回「打开安装包」让用户手动装
      await clearQuarantine(dmgPath);
      return await _openFile(dmgPath)
          ? MacInstallResult.openedExternally
          : MacInstallResult.failed;
    }

    final tmp = await Directory.systemTemp.createTemp('moneyfly_upd_');
    final mnt = Directory('${tmp.path}/mnt')..createSync(recursive: true);
    var mounted = false;
    Directory? staging;
    try {
      // 1) 挂载（不弹 Finder、只读）。
      const attachArgs = ['attach', '-nobrowse', '-readonly'];
      var attach = await run(
          'hdiutil', [...attachArgs, '-mountpoint', mnt.path, dmgPath]);
      var err = '${attach.stderr}';
      // 「资源忙」= 这张 DMG 已经挂载过（上一次尝试留下的卷）→ 先卸载再试一次，
      // 不要把这种情况误判成「安装包损坏」（用户会以为自己下载坏了）
      if (attach.exitCode != 0 &&
          (err.contains('忙') || err.contains('busy') || err.contains('already'))) {
        await run('hdiutil', ['detach', '/Volumes/MoneyFly', '-force']);
        attach = await run(
            'hdiutil', [...attachArgs, '-mountpoint', mnt.path, dmgPath]);
        err = '${attach.stderr}';
      }
      if (attach.exitCode != 0) {
        // 只有「映像本身读不出来」才算损坏（半截下载的典型症状）；
        // 其它错误（权限、被占用）归为 failed，提示语不同、处理方式也不同
        AppLog.error('更新包挂载失败: $err');
        return _looksLikeCorruptImage(err)
            ? MacInstallResult.damaged
            : MacInstallResult.failed;
      }
      mounted = true;

      // 2) 找挂载卷里的 .app
      final src = mnt
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.app'))
          .toList();
      if (src.isEmpty) return MacInstallResult.damaged;

      // 3) 复制到**同一个卷**的暂存目录（才能原子替换）
      final stagingPath = '$target.new';
      staging = Directory(stagingPath);
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      final copy = await run('ditto',
          ['--noqtn', '-rsrc', src.first.path, stagingPath]);
      if (copy.exitCode != 0) {
        AppLog.error('更新包复制失败: ${copy.stderr}');
        return MacInstallResult.failed;
      }
      // 双保险：清掉可能被继承的隔离属性（App 是 ad-hoc 签名，被隔离 = 报「已损坏」）
      await run('xattr', ['-dr', 'com.apple.quarantine', stagingPath]);

      // 4) 替换：旧 App 先改名让位，新 App 就位（运行中的进程不受影响）
      final backupPath = '$target.old-${DateTime.now().millisecondsSinceEpoch}';
      final oldDir = Directory(target);
      if (oldDir.existsSync()) oldDir.renameSync(backupPath);
      staging.renameSync(target);
      staging = null;
      mounted = false;
      await run('hdiutil', ['detach', mnt.path, '-force']);
      // 5) 清理备份（失败不影响结果）
      await run('rm', ['-rf', backupPath]);

      // 6) 起新版本。先把单实例锁放掉：新实例启动时会抢同一把排他锁，
      //    我们还持锁的话它会立刻自杀（用户看到「更新完什么都没发生」）。
      await SingleInstance.release();
      final open = await run('open', ['-n', target]);
      if (open.exitCode != 0) {
        AppLog.error('新版本启动失败: ${open.stderr}');
      }
      return MacInstallResult.installed;
    } catch (e) {
      AppLog.error('就地安装失败: $e');
      return MacInstallResult.failed;
    } finally {
      if (mounted) {
        try {
          await run('hdiutil', ['detach', mnt.path, '-force']);
        } catch (_) {}
      }
      try {
        if (staging != null && staging.existsSync()) {
          staging.deleteSync(recursive: true);
        }
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// hdiutil 的错误里含这些词 = 安装包本体坏了（不是权限/占用问题）
  static bool _looksLikeCorruptImage(String stderr) {
    final s = stderr.toLowerCase();
    const keys = [
      'not recognized', // hdiutil: attach failed - 无法识别映像
      '无法识别',
      'corrupt',
      'checksum',
      'damaged',
      'not a valid',
      'no mountable file systems',
    ];
    return keys.any(s.contains);
  }

  /// 用系统默认程序打开文件（可注入：测试环境里 url_launcher 永不返回）
  static Future<bool> _openFile(String path) async {
    final override = debugOpenFileOverride;
    if (override != null) return override(path);
    try {
      return await launchUrl(Uri.file(path),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// 当前正在运行的 App 包路径（`/Applications/MoneyFly.app`）；
  /// 不是从 .app 里跑（开发模式）则返回 null。
  @visibleForTesting
  static String? currentAppBundlePath() {
    if (debugAppBundlePath != null) return debugAppBundlePath;
    try {
      final exe = Platform.resolvedExecutable;
      final i = exe.indexOf('.app/Contents/MacOS/');
      if (i < 0) return null;
      return exe.substring(0, i + 4);
    } catch (_) {
      return null;
    }
  }

  /// macOS：清掉下载文件的隔离属性，否则 Gatekeeper 会拦下安装包
  /// （浏览器下载才有该属性，Dio 下载一般没有；这里兜底，幂等且失败不致命）
  @visibleForTesting
  static Future<void> clearQuarantine(String path) async {
    if (!Platform.isMacOS) return;
    try {
      await Process.run('xattr', ['-c', path]);
    } catch (_) {}
  }

  /// 测试缝：重置缓存与进度
  @visibleForTesting
  static void resetForTest() {
    _cacheInfo = null;
    _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);
    hasUpdate.value = false;
    downloadProgress.value = null;
    debugCheckOverride = null;
    debugDownloadOverride = null;
    debugLaunchInstallerOverride = null;
    debugCacheDir = null;
    debugStartDetached = null;
    debugCanInstallInApp = null;
    debugInstallMacOverride = null;
    debugRunProcess = null;
    debugOpenFileOverride = null;
    debugAppBundlePath = null;
    debugGhDio = null;
    _ghChannel = 0;
    debugPanelLatestOverride = null;
    _verifiedSha.clear();
  }
}
