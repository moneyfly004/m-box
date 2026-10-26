// GitHub 国内镜像兜底的回归测试。
//
// 背景（2026-09-23）：App 的「检查更新」直连 api.github.com、下载直连 github.com，
// 国内网络下常超时/被阻断 → 用户看到「检查更新失败」，永远停在旧版本。
// 现在改为「直连优先、镜像兜底」，并记住成功通道供后续下载/校验和/外呼复用。
//
// 用假 HttpClientAdapter 覆盖，测试内不联网、不写系统目录。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/api/gh_mirror.dart';
import 'package:moneyfly/core/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假 GitHub：直连域名一律连接层失败，镜像域名按 sha 返回正常响应（可配置）。
class _MirrorAdapter implements HttpClientAdapter {
  _MirrorAdapter({this.mirrorWorks = true, this.assetBytes = const []});

  final bool mirrorWorks;
  final List<int> assetBytes;

  /// 记录所有请求地址（断言尝试顺序用）
  final List<String> calls = [];

  bool _isDirect(String u) =>
      u.startsWith('https://api.github.com/') ||
      u.startsWith('https://github.com/');

  String _releaseJson() => '''
{
  "tag_name": "v9.9.9",
  "assets": [
    {"name": "MBox-setup-9.9.9.exe",
     "browser_download_url": "https://github.com/moneyfly004/moneyfly/releases/download/v9.9.9/MBox-setup-9.9.9.exe",
     "size": ${assetBytes.length}},
    {"name": "SHA256SUMS-windows.txt",
     "browser_download_url": "https://github.com/moneyfly004/moneyfly/releases/download/v9.9.9/SHA256SUMS-windows.txt",
     "size": 120}
  ]
}
''';

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final url = options.uri.toString();
    calls.add(url);

    if (_isDirect(url)) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
        error: 'connection timed out',
        message: 'connection timed out',
      );
    }
    if (!mirrorWorks) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: 'mirror down',
        message: 'mirror down',
      );
    }
    if (url.contains('SHA256SUMS')) {
      final sums = '${UpdateService.sha256HexForTest(assetBytes)}  MBox-setup-9.9.9.exe\n';
      return ResponseBody.fromString(sums, 200, headers: {
        Headers.contentTypeHeader: ['text/plain'],
      });
    }
    if (url.contains('/releases/latest')) {
      return ResponseBody.fromString(_releaseJson(), 200, headers: {
        Headers.contentTypeHeader: ['application/json'],
      });
    }
    // 安装包本体
    return ResponseBody.fromBytes(assetBytes, 200, headers: {
      Headers.contentTypeHeader: ['application/octet-stream'],
      Headers.contentLengthHeader: ['${assetBytes.length}'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.resetForTest();
    tmp = await Directory.systemTemp.createTemp('mf_mirror_test');
    UpdateService.debugCacheDir = () async => tmp;
    // 固定成 windows 平台：资产前缀与 SHA256SUMS 文件名都稳定（CI 跑在 ubuntu 上，
    // 默认 targetPlatform 为 android，这里不依赖宿主平台）
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    UpdateInfo.currentVersion = '1.0.0';
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    UpdateService.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('GhMirror 候选', () {
    test('直连在前，其后是各镜像；空地址返回空列表', () {
      final list = GhMirror.candidates('https://api.github.com/x');
      expect(list.first, 'https://api.github.com/x');
      expect(list.length, GhMirror.prefixes.length + 1);
      expect(list[1], '${GhMirror.prefixes.first}https://api.github.com/x');
      expect(GhMirror.candidates(''), isEmpty);
    });

    test('已是镜像地址不再叠加前缀（避免镜像的镜像）', () {
      final mirrored = '${GhMirror.prefixes.first}https://github.com/a/b';
      expect(GhMirror.isMirrored(mirrored), isTrue);
      expect(GhMirror.candidates(mirrored), [mirrored]);
    });

    test('at：越界不抛异常，永远返回可用地址', () {
      const url = 'https://github.com/a/b';
      expect(GhMirror.at(url, 0), url);
      expect(GhMirror.at(url, -5), url);
      expect(GhMirror.at(url, 999), '${GhMirror.prefixes.last}$url');
    });
  });

  group('检查更新：直连不通自动走镜像', () {
    test('直连超时 → 镜像命中 → 仍能检出新版本', () async {
      final adapter = _MirrorAdapter();
      UpdateService.debugGhDio =
          Dio()..httpClientAdapter = adapter;

      final info = await UpdateService.instance.check();

      expect(info, isNotNull, reason: '直连失败时必须靠镜像拿到版本，否则用户以为没有更新');
      expect(info!.latestVersion, '9.9.9');
      expect(info.isNewer, isTrue);
      expect(UpdateService.hasUpdate.value, isTrue);
      expect(UpdateService.usingGhMirror, isTrue, reason: '应记住已切到镜像通道');

      // 顺序：先试直连（失败），再试镜像（成功）
      expect(adapter.calls.first, startsWith('https://api.github.com/'));
      expect(adapter.calls[1], startsWith('https://ghfast.top/https://api.github.com/'));
    });

    test('校验和也走同一镜像通道（不再各自试错一轮）', () async {
      final bytes = List<int>.generate(64, (i) => i);
      final adapter = _MirrorAdapter(assetBytes: bytes);
      UpdateService.debugGhDio = Dio()..httpClientAdapter = adapter;

      final info = await UpdateService.instance.check();
      expect(info!.sha256, UpdateService.sha256HexForTest(bytes),
          reason: '校验值必须与安装包取自同一通道，否则下载完校验必然失败');
      expect(adapter.calls.any((u) => u.startsWith('https://ghfast.top/') && u.contains('SHA256SUMS')),
          isTrue);
    });

    test('直连与所有镜像都不可用 → 返回 null 且不崩', () async {
      final adapter = _MirrorAdapter(mirrorWorks: false);
      UpdateService.debugGhDio = Dio()..httpClientAdapter = adapter;
      // 面板兜底也声明为不可用（这条用例只验 GitHub 侧全挂不崩；面板兜底另有用例覆盖）
      UpdateService.debugPanelLatestOverride = (_) async => null;

      final info = await UpdateService.instance.check();

      expect(info, isNull);
      expect(UpdateService.hasUpdate.value, isFalse);
      expect(adapter.calls.length, greaterThan(1), reason: '应把所有候选都试过才放弃');
    });
  });

  group('下载安装包：直连不通自动走镜像', () {
    test('直连失败 → 镜像下载成功且 sha256 校验通过', () async {
      final bytes = List<int>.generate(256, (i) => i % 251);
      final adapter = _MirrorAdapter(assetBytes: bytes);
      UpdateService.debugGhDio = Dio()..httpClientAdapter = adapter;

      final info = await UpdateService.instance.check();
      expect(info, isNotNull);

      final path = await UpdateService.instance.downloadInstaller(info: info);
      expect(path, isNotNull, reason: '直连不通时下载也必须能走镜像完成');
      expect(File(path!).lengthSync(), bytes.length);
      expect(await UpdateService.instance.verifyInstaller(path, info), isTrue);

      // 安装包请求只应打到镜像，不再浪费一次直连超时
      final assetCalls = adapter.calls
          .where((u) => u.contains('MBox-setup-9.9.9.exe'))
          .toList();
      expect(assetCalls, isNotEmpty);
      expect(assetCalls.every((u) => u.startsWith('https://ghfast.top/')), isTrue,
          reason: '已知直连不通后应直接用镜像，逐次重试直连会让用户多等一个超时');
    });

    test('镜像下载的包内容损坏（sha256 不符）→ 丢弃且不返回路径', () async {
      final bytes = List<int>.generate(128, (i) => i);
      final adapter = _MirrorAdapter(assetBytes: bytes);
      UpdateService.debugGhDio = Dio()..httpClientAdapter = adapter;

      final info = await UpdateService.instance.check();
      // 篡改期望哈希：模拟下到坏包 / 被中间人替换
      final tampered = UpdateInfo(
        latestVersion: info!.latestVersion,
        downloadUrl: info.downloadUrl,
        assetName: info.assetName,
        sizeBytes: info.sizeBytes,
        sha256: 'f' * 64,
      );
      final path = await UpdateService.instance.downloadInstaller(info: tampered);
      expect(path, isNull);
      expect(Directory('${tmp.path}/update').existsSync(), isTrue);
      final leftovers = Directory('${tmp.path}/update')
          .listSync()
          .whereType<File>()
          .where((f) => f.lengthSync() > 0)
          .toList();
      expect(leftovers, isEmpty, reason: '校验不过的包必须删掉，不能留在缓存里被当"已下好"');
    });
  });

  group('打开下载页外呼', () {
    test('未切换通道时原样返回（不改变既有行为）', () {
      expect(UpdateService.mirroredUrl('https://github.com/a/b'),
          'https://github.com/a/b');
    });

    test('已切镜像时换成镜像地址（移动端点「去下载」才打得开）', () async {
      final adapter = _MirrorAdapter();
      UpdateService.debugGhDio = Dio()..httpClientAdapter = adapter;
      await UpdateService.instance.check();
      expect(UpdateService.usingGhMirror, isTrue);

      expect(UpdateService.mirroredUrl('https://github.com/a/b'),
          '${GhMirror.prefixes.first}https://github.com/a/b');
    });
  });
  group('面板兜底：GitHub 不通时问自己的服务器', () {
    test('GitHub 全挂 → 用面板返回的版本/包名/体积/sha256', () async {
      // GitHub 侧全挂（国内真实场景）
      UpdateService.debugGhDio = Dio()
        ..httpClientAdapter = _MirrorAdapter(mirrorWorks: false);
      final panelKey = <String>[];
      UpdateService.debugPanelLatestOverride = (key) async {
        panelKey.add(key);
        return {
          'version': '2.2.20',
          'asset_name': 'MBox-setup-2.2.20.exe',
          'size_bytes': 27262976,
          'sha256': 'a' * 64,
          'download_url':
              'https://github.com/moneyfly004/moneyfly/releases/download/v2.2.20/MBox-setup-2.2.20.exe',
        };
      };

      final info = await UpdateService.instance.check();

      expect(info, isNotNull, reason: 'GitHub 不通时必须靠面板拿到更新信息');
      expect(info!.latestVersion, '2.2.20');
      expect(info.assetName, 'MBox-setup-2.2.20.exe');
      expect(info.sha256, 'a' * 64, reason: 'sha256 由自己的服务器给出，校验不降级');
      expect(info.sizeBytes, 27262976);
      expect(info.sizeText, '26 MB');
      expect(info.isNewer, isTrue);
      expect(UpdateService.hasUpdate.value, isTrue);
      expect(panelKey, ['moneyfly_windows_url'], reason: 'Windows 应问 Windows 入口');
    });

    test('面板兜底拿到的包也能下载并按 sha256 校验', () async {
      final bytes = List<int>.generate(96, (i) => i * 3 % 251);
      final adapter = _MirrorAdapter(assetBytes: bytes, mirrorWorks: true);
      UpdateService.debugGhDio = Dio()..httpClientAdapter = adapter;
      UpdateService.debugPanelLatestOverride = (_) async => {
            'version': '2.2.20',
            'asset_name': 'MBox-setup-2.2.20.exe',
            'size_bytes': bytes.length,
            'sha256': UpdateService.sha256HexForTest(bytes),
            'download_url':
                'https://github.com/moneyfly004/moneyfly/releases/download/v2.2.20/MBox-setup-2.2.20.exe',
          };

      final info = await UpdateService.instance.check();
      final path = await UpdateService.instance.downloadInstaller(info: info);

      expect(path, isNotNull);
      expect(await UpdateService.instance.verifyInstaller(path!, info), isTrue);
    });

    test('面板也失败 → 返回 null（不误报「已是最新」）', () async {
      UpdateService.debugGhDio = Dio()
        ..httpClientAdapter = _MirrorAdapter(mirrorWorks: false);
      UpdateService.debugPanelLatestOverride = (_) async => null;

      expect(await UpdateService.instance.check(), isNull);
      expect(UpdateService.hasUpdate.value, isFalse);
    });

    test('面板数据缺版本或下载地址 → 视为失败，不构造半个 UpdateInfo', () async {
      UpdateService.debugGhDio = Dio()
        ..httpClientAdapter = _MirrorAdapter(mirrorWorks: false);
      for (final bad in <Map<String, dynamic>>[
        {'version': '', 'asset_name': 'a.exe', 'download_url': 'https://x/y.exe'},
        {'version': '2.2.20', 'asset_name': '', 'download_url': 'https://x/y.exe'},
        {'version': '2.2.20', 'asset_name': 'a.exe', 'download_url': ''},
      ]) {
        UpdateService.resetForTest();
        UpdateService.debugCacheDir = () async => tmp;
        UpdateService.debugGhDio = Dio()
          ..httpClientAdapter = _MirrorAdapter(mirrorWorks: false);
        UpdateService.debugPanelLatestOverride = (_) async => bad;
        expect(await UpdateService.instance.check(), isNull,
            reason: '残缺面板数据必须当作失败: $bad');
      }
    });

    test('已是最新版本时不误报红点', () async {
      UpdateInfo.currentVersion = '2.2.20';
      UpdateService.debugGhDio = Dio()
        ..httpClientAdapter = _MirrorAdapter(mirrorWorks: false);
      UpdateService.debugPanelLatestOverride = (_) async => {
            'version': '2.2.20',
            'asset_name': 'MBox-setup-2.2.20.exe',
            'download_url': 'https://github.com/x/y/MBox-setup-2.2.20.exe',
          };
      final info = await UpdateService.instance.check();
      expect(info, isNotNull);
      expect(info!.isNewer, isFalse);
      expect(UpdateService.hasUpdate.value, isFalse);
    });
    test('平台→面板入口映射：Android 走 android 入口，iOS 不兜底', () async {
      final keys = <String>[];
      void armStub() {
        UpdateService.debugGhDio = Dio()
          ..httpClientAdapter = _MirrorAdapter(mirrorWorks: false);
        UpdateService.debugPanelLatestOverride = (k) async {
          keys.add(k);
          return null;
        };
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      armStub();
      await UpdateService.instance.check();
      expect(keys, ['moneyfly_android_url']);

      // iOS 只做 IPA 侧载提示，面板没有对应入口 → 不应发出兜底请求
      keys.clear();
      UpdateService.resetForTest();
      UpdateService.debugCacheDir = () async => tmp;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      armStub();
      await UpdateService.instance.check();
      expect(keys, isEmpty, reason: 'iOS 不该去打一个不存在的面板入口');
    });
  });
}
