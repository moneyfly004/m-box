import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../proxy/proxy_core.dart';
import 'app_log.dart';
import 'settings_store.dart';

/// 内核变体：官方对 amd64(x64) 提供两种构建 ——
/// - [standard] 标准版：按新指令集(v3/AVX2)编译，新 CPU 性能好；
/// - [compatible] 兼容版：兼容老 CPU(无 AVX2 的老电脑)，与 macOS x64 同策略。
/// 老 CPU 跑标准版会启动即崩溃(0xC0000005)，故桌面 amd64 默认 compatible，
/// 用户可在「内核管理」里手动切换。
enum KernelVariant { standard, compatible }

extension KernelVariantX on KernelVariant {
  String get key => this == KernelVariant.compatible ? 'compatible' : 'standard';

  String get label => this == KernelVariant.compatible ? '兼容版' : '标准版';
}

/// 应用内内核管理（sing-box）：显示当前内置内核版本、检测官方最新版本、
/// 桌面端下载官方预编译二进制并热替换。
///
/// 内核来源：SagerNet/sing-box 官方 GitHub Release（与 CI 构建下载同源）。
/// Android/iOS 内核以 gomobile 静态库编译进 App（libmbox.aar /
/// Libbox.xcframework），无法运行期替换 —— 页面提示随 App 更新。
class KernelManager {
  KernelManager._();
  static final KernelManager instance = KernelManager._();

  static String get _exeName =>
      Platform.isWindows ? 'sing-box.exe' : 'sing-box';

  /// 用户内核副本目录（应用支持目录/kernel，各平台均可写）。
  /// 切换/更新的内核放这里，**绝不动安装目录** —— 装到 Program Files 等
  /// 只读目录也能正常切换/更新内核。
  static Future<Directory?> userKernelDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/kernel');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// 用户「当前生效」内核副本路径（不存在返回 null）
  static Future<String?> userActivePath() async {
    try {
      final dir = await userKernelDir();
      if (dir == null) return null;
      final f = File('${dir.path}/$_exeName');
      return await f.exists() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  /// 是否已存在用户切换/更新的内核（有则可「恢复内置」）
  static Future<bool> hasUserKernel() async =>
      (await userActivePath()) != null;

  /// 生效内核查找优先级：测试注入(MBOX_SINGBOX) → 用户副本 → 安装内置
  static Future<String?> resolveKernelPath() async {
    final override = Platform.environment['MBOX_SINGBOX'];
    if (override != null && override.isNotEmpty && File(override).existsSync()) {
      return override;
    }
    final user = await userActivePath();
    if (user != null) return user;
    final exe = Platform.resolvedExecutable;
    final candidates = <String>[
      if (Platform.isMacOS) '${Directory(exe).parent.path}/$_exeName',
      '${Directory(exe).parent.path}/$_exeName',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 删除用户副本 → 回到安装包内置内核（无需下载）。返回是否成功清除。
  static Future<bool> restoreBuiltin() async {
    try {
      final dir = await userKernelDir();
      if (dir == null) return false;
      for (final name in [_exeName, '.$_exeName.bak']) {
        try {
          final f = File('${dir.path}/$name');
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      // 复查主副本确实已删除：Windows 上「运行中的 exe」删除会因文件锁失败,
      // 上面静默吞掉 —— 若不复查会出现「提示已恢复内置、实际用户副本还在」
      // 的假成功（下次连接仍用旧副本）。
      return !await File('${dir.path}/$_exeName').exists();
    } catch (_) {
      return false;
    }
  }

  /// 平台内置内核的变体（安装包随 CI 打包的构建）
  static Future<KernelVariant> builtinVariantForPlatform() async {
    if (Platform.isMacOS && (await KernelManager.instance._macArch()) != 'arm64') {
      return KernelVariant.compatible;
    }
    if (Platform.isWindows) {
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
      if (!arch.toUpperCase().contains('ARM64')) return KernelVariant.compatible;
    }
    return KernelVariant.standard;
  }

  static bool get isDesktop => !Platform.isAndroid && !Platform.isIOS;

  /// 归一化版本号（去掉 v 前缀）
  static String norm(String? v) {
    if (v == null) return '';
    var s = v.trim();
    if (s.startsWith('v')) s = s.substring(1);
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(s);
    if (m == null) return s;
    return '${m.group(1)}.${m.group(2)}.${m.group(3)}';
  }

  /// 比较版本，a > b 返回正数
  static int compare(String a, String b) {
    final pa = norm(a).split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = norm(b).split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x - y;
    }
    return 0;
  }

  KernelVariant _variant = KernelVariant.compatible;
  bool _variantLoaded = false;

  /// 当前偏好变体（默认 compatible，老 CPU 安全；设置可切换）
  Future<KernelVariant> currentVariant() async {
    if (!_variantLoaded) {
      try {
        final s = await SettingsStore.instance.load();
        final k = s['kernelVariant']?.toString();
        _variant = k == 'standard' ? KernelVariant.standard : KernelVariant.compatible;
      } catch (_) {}
      _variantLoaded = true;
    }
    return _variant;
  }

  Future<void> setVariant(KernelVariant v) async {
    _variant = v;
    try {
      await SettingsStore.instance.update((s) => s['kernelVariant'] = v.key);
    } catch (_) {}
  }

  /// sing-box 官方只发布一套构建（没有旧内核那种「兼容版/标准版」之分），
  /// 故桌面端也不再提供变体切换，UI 依据本值隐藏该选项。
  static Future<bool> get supportsVariant async => false;

  /// 探测当前内置内核版本：
  /// - 桌面：运行 `sing-box version` 解析首行
  /// - Android/iOS：MethodChannel 读 libbox 内核版本
  /// 失败返回 null（页面显示未知 + 提示）。
  Future<String?> detectCurrent() async {
    try {
      if (Platform.isAndroid) {
        const ch = MethodChannel('top.mbox/vpn_core');
        final v = await ch.invokeMethod<String>('kernelVersion');
        return norm(v);
      }
      final bin = await resolveKernelPath();
      if (bin == null) return null;
      final r = await Process.run(bin, ['version'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      if (r.exitCode != 0) return null;
      final out = '${r.stdout}${r.stderr}';
      final first = out.split('\n').firstWhere(
          (l) => l.toLowerCase().contains('sing-box'),
          orElse: () => '');
      final m = RegExp(r'v?(\d+\.\d+\.\d+)').firstMatch(first);
      return m?.group(1) ?? norm(first);
    } catch (e) {
      AppLog.error('detectCurrent failed: $e');
      return null;
    }
  }

  /// 官方最新稳定版（GitHub API releases/latest → tag_name）。
  /// 已连接时经隧道请求 —— GitHub 在直连网络环境常不可达。
  Future<String?> fetchLatest() async {
    try {
      final dio = await _dio(receiveTimeout: const Duration(seconds: 8));
      final r = await dio.get('https://api.github.com/repos/SagerNet/sing-box/releases/latest');
      if (r.statusCode == 200 && r.data is Map) {
        final tag = (r.data as Map)['tag_name']?.toString();
        return tag == null ? null : norm(tag);
      }
      return null;
    } catch (e) {
      AppLog.error('fetchLatest failed: $e');
      return null;
    }
  }

  /// 下载/检查更新用 Dio：**已连接时显式走本地混合代理（隧道）**。
  /// 内核托管在 GitHub，直连网络环境（国内）常不可达 —— 「先连 VPN 再更新
  /// 内核」是主路径，下载必须能走隧道；未连接时直连（可直达环境仍可用）。
  /// App 自身请求不走系统代理，必须像 GeoLookupService 一样显式 findProxy。
  Future<Dio> _dio({required Duration receiveTimeout}) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: receiveTimeout,
    ));
    if (ConnectionController.instance.status == ConnStatus.connected) {
      var port = 2080;
      try {
        final s = await SettingsStore.instance.load();
        port = (s['localPort'] as num?)?.toInt() ?? 2080;
      } catch (_) {}
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.connectionTimeout = const Duration(seconds: 15);
          c.findProxy = (_) => 'PROXY 127.0.0.1:$port';
          return c;
        },
      );
    }
    return dio;
  }

  /// 切换/更新内核（仅桌面端）。返回空串=成功；非空=错误消息。
  ///
  /// 两阶段：[downloadToCache]（连接中可下载，经隧道）→ [activateCached]
  /// （要求内核已停止）。此入口为兼容组合：下载后若内核在跑返回
  /// 'kernel_running'（UI 层 kernel_page 走两阶段 + 自动断开重连流程）。
  ///
  /// 写入位置为「用户副本目录」（userKernelDir，可写），**绝不修改安装目录**，
  /// 装到 Program Files 等只读目录也能切换/更新。
  /// 下载缓存：`cache/<variant>_<version>` —— 本地已有该 (变体,版本) 内核时
  /// 直接激活、不再下载；来回切换不重复下载。「恢复内置」= 删除用户副本。
  Future<String> updateTo(String version,
      {KernelVariant? variant, void Function(double progress)? onProgress}) async {
    final dl =
        await downloadToCache(version, variant: variant, onProgress: onProgress);
    if (dl.isNotEmpty) return dl;
    return activateCached(version, variant: variant);
  }

  File _cacheFileOf(Directory dir, KernelVariant v, String version) =>
      File('${dir.path}/cache/${v.key}_$version$_exeName');

  /// 阶段一：下载内核到本地缓存（不激活、**不要求断开连接**）。
  /// 返回空串=成功（含缓存命中）。
  ///
  /// 内核托管在 GitHub Release，直连网络环境（国内）常不可达 ——
  /// 「先连 VPN → 经隧道下载 → 断开瞬间替换 → 自动重连」是桌面端更新
  /// 内核的主路径。已连接时 [_dio] 显式走本地混合代理；未连接时直连
  /// 下载（可直达环境仍可用）。下载/解压/自检任何异常都转为错误消息
  /// 返回，绝不上抛 —— 否则 UI 的 _downloading 态会卡死在「下载中」。
  Future<String> downloadToCache(String version,
      {KernelVariant? variant, void Function(double progress)? onProgress}) async {
    if (!isDesktop) return 'not supported on this platform';
    final v = variant ?? await currentVariant();
    final asset = await _assetName(version, v);
    if (asset == null) return 'unsupported platform/arch';
    final dir = await userKernelDir();
    if (dir == null) return 'no writable kernel dir';
    final cacheFile = _cacheFileOf(dir, v, version);

    // 缓存命中 → 无需下载（切换回该 (变体,版本) 秒切）
    if (await cacheFile.exists() && await cacheFile.length() > 0) return '';

    final tmp = Directory.systemTemp.createTempSync('mf_kernel_update');
    try {
      final url =
          'https://github.com/SagerNet/sing-box/releases/download/v$version/$asset';
      final dio = await _dio(receiveTimeout: const Duration(minutes: 5));
      final archive = '${tmp.path}/$asset';
      await dio.download(url, archive, onReceiveProgress: (a, b) {
        if (b > 0) onProgress?.call(a / b);
      });

      final exePath = await _extract(archive, tmp.path);
      if (exePath == null) return 'extract failed: $asset';
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', exePath]);
      }
      // 新内核自检
      final check = await Process.run(exePath, ['version'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      if (check.exitCode != 0) return 'downloaded kernel failed self-check';

      // 写缓存（保留，切换回该 (变体,版本) 不再下载）
      try {
        await Directory('${dir.path}/cache').create(recursive: true);
        File(exePath).copySync(cacheFile.path);
        if (!Platform.isWindows) {
          await Process.run('chmod', ['+x', cacheFile.path]);
        }
      } catch (e) {
        return 'cache write failed: $e';
      }
      return '';
    } on DioException catch (e) {
      return 'download failed: ${e.message ?? e.type.name}';
    } catch (e) {
      return 'download failed: $e';
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 阶段二：把已缓存的 (变体,版本) 内核激活为「当前生效」。
  /// 要求内核未运行（连接/启动/断开过程中都不允许换二进制 ——
  /// Windows 上运行中的 exe 文件被锁，替换会失败或产生半新半旧状态）。
  Future<String> activateCached(String version, {KernelVariant? variant}) async {
    if (!isDesktop) return 'not supported on this platform';
    final st = ConnectionController.instance.status;
    if (st != ConnStatus.disconnected && st != ConnStatus.error) {
      return 'kernel_running';
    }
    final v = variant ?? await currentVariant();
    final dir = await userKernelDir();
    if (dir == null) return 'no writable kernel dir';
    final cacheFile = _cacheFileOf(dir, v, version);
    if (!await cacheFile.exists() || await cacheFile.length() == 0) {
      return 'no cached kernel for ${v.key} v$version';
    }
    return _activate(dir, cacheFile);
  }

  /// 把缓存内核激活为「当前生效」（userKernelDir/sing-box[.exe]），带备份回滚与自检
  Future<String> _activate(Directory dir, File cacheFile) async {
    final active = File('${dir.path}/$_exeName');
    final bak = File('${dir.path}/.$_exeName.bak');
    try {
      if (await active.exists()) {
        if (await bak.exists()) await bak.delete();
        await active.rename(bak.path);
      }
      await cacheFile.copy(active.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', active.path]);
      }
    } catch (e) {
      // 回滚
      try {
        if (!await active.exists() && await bak.exists()) {
          await bak.rename(active.path);
        }
      } catch (_) {}
      return 'activate failed: $e';
    }
    // 自检
    final verify = await Process.run(active.path, ['version'],
        environment: {'PATH': Platform.environment['PATH'] ?? ''});
    if (verify.exitCode != 0) {
      try {
        if (await active.exists()) await active.delete();
        if (await bak.exists()) await bak.rename(active.path);
      } catch (_) {}
      return 'kernel failed self-check, rolled back';
    }
    try {
      if (await bak.exists()) await bak.delete();
    } catch (_) {}
    return '';
  }

  /// sing-box 官方只有一套构建（无 compatible 变体），所以 [variant] 不再
  /// 影响资产名，仅为兼容既有 UI/设置项保留签名。
  Future<String?> _assetName(String version, KernelVariant variant) async {
    if (Platform.isMacOS) {
      final arch = await _macArch();
      return 'sing-box-$version-darwin-$arch.tar.gz';
    }
    if (Platform.isWindows) {
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
      final a = arch.toUpperCase().contains('ARM64') ? 'arm64' : 'amd64';
      return 'sing-box-$version-windows-$a.zip';
    }
    return null;
  }

  Future<String> _macArch() async {
    try {
      final r = await Process.run('uname', ['-m']);
      final out = (r.stdout as String).trim();
      return out.contains('arm') || out.contains('aarch64') ? 'arm64' : 'amd64';
    } catch (_) {
      return 'arm64';
    }
  }

  /// 解压并返回可执行文件路径：
  /// - macOS `.tar.gz` → tar -xzf 后定位 `sing-box`（官方包内为
  ///   `sing-box-<ver>-darwin-<arch>/sing-box`）
  /// - Windows `.zip` → Expand-Archive 后定位 `sing-box.exe`
  Future<String?> _extract(String archive, String dir) async {
    if (Platform.isMacOS) {
      final r = await Process.run('tar', ['-xzf', archive, '-C', dir]);
      if (r.exitCode != 0) return null;
      final found = Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) =>
              f.path.endsWith('/sing-box') ||
              f.path.endsWith('\\sing-box'))
          .toList();
      if (found.isEmpty) return null;
      final exe = found.first.path;
      final target = '$dir/sing-box';
      if (exe != target) File(exe).copySync(target);
      return target;
    }
    if (Platform.isWindows) {
      final dest = '$dir/unzipped';
      Directory(dest).createSync(recursive: true);
      final winZip = archive.replaceAll('/', r'\');
      final winDest = dest.replaceAll('/', r'\');
      final r = await Process.run('powershell', [
        '-NoProfile', '-Command',
        'Expand-Archive -Path "$winZip" -DestinationPath "$winDest" -Force',
      ]);
      if (r.exitCode != 0) return null;
      // 定位内核 exe（官方 zip 内含 sing-box-<ver>-windows-<arch>/sing-box.exe）
      final found = Directory(dest)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) =>
              f.path.toLowerCase().endsWith('sing-box.exe'))
          .toList();
      if (found.isEmpty) return null;
      final exe = found.first.path;
      // 拷到 dir 根，统一返回路径
      final target = '$dir/sing-box.exe';
      File(exe).copySync(target);
      return target;
    }
    return null;
  }
}

