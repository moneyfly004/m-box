// 发布前机械防线：仓库里**不允许出现真实节点信息**。
//
// 背景（为什么必须有这道防线）：
//   moneyfly004/m-box 是**公开仓库**。`test/subscription_b64_test.dart` 与
//   `test/ss_parse_test.dart` 曾经直接内嵌真实机场订阅的原文（真实公网 IP:端口、
//   hy2 UUID 密码、vless REALITY 公钥/short-id、真实节点域名、ss 密码）。
//   `test/` 不会被打进安装包，所以客户产物没受影响；但**公开仓库本身**就是泄露
//   ——任何人对着一份泄露的订阅就能把节点跑满 / 被封，等于把客户的线路公开。
//   另外历史里还误提交过 iOS 构建产物（Payload/Runner.app/…），同一个坑。
//
// 这道防线做四件事（全部只看仓库当前内容，不联网、不读安装包）：
//   1) 节点链接（vless/vmess/trojan/hysteria2/anytls/tuic/ss/ssr/socks/wireguard）
//      的**主机名/IP 必须是文档占位值**（example.com、RFC 5737、私网段、假 IP）；
//   2) 任何"公网 IP:端口"组合都必须是已知的文档/保留地址；
//   3) REALITY 公钥（pbk=/public-key:）必须是显式登记过的假公钥；
//   4) 本次事件的确切泄露值进入**硬黑名单**——再次出现直接失败。
//   另有第 5 项：会打进包里的路径（lib/ assets/ android/ ios/ macos/ windows/）
//   不得出现「内测 / 公测 / 体验节点 / 测试账号」这类对内标记。
//
// 约束：测试用例里的**中文标签**（如「测试节点」当作节点名断言）不算泄露
//   ——它只是个字符串常量，不对应任何真实线路，且 test/ 不进包。所以第 5 项
//   只对**会进包的路径**生效，避免为了好看乱删测试语义。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// 本次事件中确认泄露的确切值（掩码见报告；此处按需完整比对，因为
/// "文件里再出现这一串"本身就是失败条件）。新增泄露事件时往这里加。
const _incidentBlocklist = <String>[
  '152.69.220.212', // hy2 真实节点 IP
  '203.10.96.138', // vless reality 真实节点 IP
  '203.27.106.148', // hysteria2 真实节点 IP
  '192.187.115.34', // ss 真实节点 IP
  'b07db61f-a207-4508-97f5-68182991c2d6', // hy2 真实密码（= UUID）
  'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0', // reality 真实公钥
  'yydjc.top', // 真实节点域名后缀
  'yyloutLineVpnServerfree32', // ss 真实密码
  'fd26d49a', // reality 真实 short-id
];

/// 防线自身的文件必然要写出黑名单字面量（否则无法比对），因此只对它们跳过
/// 「硬黑名单」这一项；节点链接 / 公网 IP:端口 / REALITY 公钥 / 对内标记
/// 四项**照查**，所以把真实节点藏进防线文件里照样会被抓出来。
const _guardFiles = <String>{
  'test/no_test_node_data_test.dart',
  'tool/scan_release_artifacts.py', // 产物防线：扫真实安装包，同一份黑名单
};

/// 允许出现的 REALITY 公钥：只登记**明确是假的**（一次性生成、不对应任何
/// 真实节点；内核会校验 X25519 合法性，所以不能随便写占位文本）。
const _allowedRealityPbk = <String>[
  'EXAMPLE_pbk_0000000000000000000000000000',
  'HQ_-6oB8xn2u6GDOAerqTuysOQFAvpA1FpiXG5H-ySI',
];

/// 节点链接（含简写 hy2://）——只取 `//` 或 `@` 之后的主机部分。
final _nodeUri = RegExp(
  r'\b(?:vless|vmess|trojan|hysteria2|hysteria|hy2|anytls|tuic|ssr|ss|socks5|socks|wireguard)://'
  r'(?:[^\s/?#@]*@)?([A-Za-z0-9.\-]+)',
);

/// 任何"IP:端口"（用于兜底捕获非链接形态，如 YAML 里的 server: ... port: ...）
final _ipPort = RegExp(r'\b((?:\d{1,3}\.){3}\d{1,3}):(\d{2,5})\b');

/// REALITY 公钥出现处（链接 query 与 Clash map 两种写法都要覆盖）
final _pbk = RegExp(r'(?:pbk=|public-key:\s*|"public-key":\s*")([A-Za-z0-9_\-]{20,})');

/// 长 base64 段（订阅整份常常是「base64 包一层」，直接扫原文会漏）
final _b64Run = RegExp(r'[A-Za-z0-9+/_\-]{64,}={0,2}');

/// 「会进包」的路径里不允许出现的对内标记
const _internalMarkers = <String>['内测', '公测', '体验节点', '测试账号', '测试订阅'];

/// 文档/保留地址：这些 IP 出现多少次都不算泄露
final _allowedIpPrefixes = <String>[
  // 私网 / 回环 / 链路本地 / CGNAT / fake-ip / 组播
  '10.', '127.', '192.168.', '172.16.', '172.17.', '172.18.', '172.19.',
  '172.2', '172.30.', '172.31.', '169.254.', '100.6', '198.18.', '198.19.',
  '0.0.0.0', '224.', '239.', '255.255.',
  // RFC 5737 文档段
  '192.0.2.', '198.51.100.', '203.0.113.',
  // 公开 DNS / 已知占位 IP（业务默认值，不是节点）
  '223.5.5.5', '223.6.6.6', '119.29.29.29', '114.114.114.114',
  '208.67.222.222', '208.67.220.220', '8.8.8.8', '8.8.4.4', '1.1.1.1',
  '9.9.9.9', '1.2.3.', '5.6.7.', '1.1.1.2', '2.2.2.1', '198.51.100.',
];

/// 允许出现的域名后缀（文档域）
final _allowedDomainSuffixes = <String>[
  'example.com', 'example.org', 'example.net', 'example', 'invalid', 'test',
  'localhost', 'local', 'lan', 'apple.com', 'gstatic.com', 'github.com',
  'githubusercontent.com', 'moneyfly.top', 'dpdns.org', 'fastora.top',
  'ghfast.top', 'gh-proxy.com', 'llkk.cc', 'ddlc.top', 'pub.dev', 'dart.dev',
  'flutter.dev', 'w3.org', 'apache.org', 'opensource.org', 'creativecommons.org',
  'stackoverflow.com', 'cloudflare.com', 'google.com', 'microsoft.com',
];

/// 目录/后缀：逐字节扫这些位置（会进包 + 会进公开仓库的源码）
const _scanRoots = <String>[
  'lib', 'test', 'tool', 'scripts', '.github', 'assets',
  'android/mihomo-core', 'ios/PacketTunnel',
];
const _scanFiles = <String>[
  'pubspec.yaml', 'README.md', 'analysis_options.yaml', 'dart_test.yaml',
];
const _skipDirs = <String>{
  '.git', '.dart_tool', 'build', 'dist', 'Pods', 'ephemeral', 'node_modules',
  'mihomo-bin', '.idea', 'Runner.xcodeproj', 'xcuserdata', '.symlinks',
  'Mihomelib.xcframework', '__pycache__',
};
const _skipExts = <String>[
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.icns', '.pdf', '.zip',
  '.apk', '.ipa', '.dmg', '.exe', '.so', '.dylib', '.dll', '.a', '.jar', '.aar',
  '.ttf', '.otf', '.woff', '.woff2', '.zst',
];

/// 会进安装包的路径（用于「对内标记」检查）
const _shippedPrefixes = <String>[
  'lib/', 'assets/', 'android/', 'ios/', 'macos/', 'windows/',
];

String _mask(String s) {
  if (s.length <= 10) return s;
  return '${s.substring(0, 6)}***${s.substring(s.length - 3)}';
}

bool _ipAllowed(String ip) => _allowedIpPrefixes.any(ip.startsWith);

bool _hostAllowed(String host) {
  final h = host.toLowerCase();
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h)) return _ipAllowed(h);
  // 不含点的裸串（h / host / base64 / uuid 这类文档占位）直接放行
  if (!h.contains('.')) return true;
  return _allowedDomainSuffixes.any((s) => h == s || h.endsWith('.$s'));
}

/// 把 Windows 的反斜杠路径统一成 '/'。
///
/// 这道防线要在 Windows runner 上也有效（CI 的「校验 (Windows, 真实内核)」
/// 作业）：不归一化时 `test\no_test_node_data_test.dart` 匹配不上排除名单里的
/// `test/no_test_node_data_test.dart`，防线文件自身写的黑名单字面量会被自己
/// 判成命中直接失败（实测踩过）；`_skipDirs` 的 `/build/` 同理匹配不上，
/// 连构建产物都会被扫进来。所以所有路径比较前先归一化。
String _posix(String p) => p.replaceAll(r'\', '/');

void main() {
  test('仓库内不得含真实节点信息 / 对内标记（发布前机械防线）', () {
    final root = Directory.current;
    final files = <File>[];

    for (final f in _scanFiles) {
      final file = File('${root.path}/$f');
      if (file.existsSync()) files.add(file);
    }
    for (final rel in _scanRoots) {
      final dir = Directory('${root.path}/$rel');
      if (!dir.existsSync()) continue;
      dir.listSync(recursive: true).whereType<File>().forEach((f) {
        final p = f.path;
        if (_skipDirs.any((d) => _posix(p).contains('/$d/'))) return;
        if (_skipExts.any((e) => p.toLowerCase().endsWith(e))) return;
        try {
          if (f.lengthSync() > 64 * 1024 * 1024) return;
        } on FileSystemException {
          return;
        }
        files.add(f);
      });
    }

    // 已声明的 asset 必须都被扫到（防止有人把节点文件加进 pubspec 却绕过扫描）
    final declared = _declaredAssets(root);
    for (final rel in declared) {
      final file = File('${root.path}/$rel');
      if (file.existsSync() &&
          !files.any((f) => _posix(f.path).endsWith(rel))) {
        files.add(file);
      }
    }

    expect(files, isNotEmpty, reason: '扫描集合为空，防线自身失效');

    final problems = <String>[];
    for (final file in files) {
      final rel = _posix(file.path.substring(root.path.length + 1));
      final shipped = _shippedPrefixes.any(rel.startsWith);
      // 防线文件自身必然写着黑名单字面量，只对它跳过黑名单这一项
      final isGuardFile = _guardFiles.contains(rel);
      final bytes = file.readAsBytesSync();
      // latin1：字节与字符一一对应，ASCII 特征（链接/IP）不失真
      final latin = latin1.decode(bytes, allowInvalid: true);
      final lines = latin.split('\n');

      for (var i = 0; i < lines.length; i++) {
        _checkText(
          text: lines[i],
          where: '$rel:${i + 1}',
          isGuardFile: isGuardFile,
          problems: problems,
        );
      }

      // 整份订阅常被 base64 包一层：解出来再扫一遍，否则把节点 base64 一下就绕过
      for (final m in _b64Run.allMatches(latin)) {
        final decoded = _tryDecodeB64(m.group(0)!);
        if (decoded == null) continue;
        _checkText(
          text: decoded,
          where: '$rel@b64[${m.start}]',
          isGuardFile: isGuardFile,
          problems: problems,
        );
      }

      if (shipped) {
        // 中文标记可能是 UTF-8 或 UTF-16LE（Dart AOT 里是 UTF-16）
        final utf8Text = utf8.decode(bytes, allowMalformed: true);
        final utf16Text = _decodeUtf16Le(bytes);
        for (final marker in _internalMarkers) {
          if (utf8Text.contains(marker) || utf16Text.contains(marker)) {
            problems.add('[$rel] 会进包的路径出现对内标记「$marker」');
          }
        }
      }
    }

    final unique = problems.toSet().toList()..sort();
    expect(
      unique,
      isEmpty,
      reason: '发现 ${unique.length} 处疑似真实节点信息 / 对内标记。\n'
          '处理方式：把真实主机、凭据、REALITY 公钥换成文档占位值'
          '（example.com、RFC 5737 198.51.100.0/24、一次性生成的假公钥），'
          '而不是把这条规则删掉。\n'
          '${unique.take(40).join('\n')}'
          '${unique.length > 40 ? '\n... 其余 ${unique.length - 40} 处' : ''}',
    );
  });

  // CI 的 Windows 作业实测失败过：路径不归一化时，防线文件自身写的黑名单
  // 字面量会被自己判成命中（`test\no_...` 匹配不上 `test/no_...`），
  // 且 `_skipDirs` 的 `/build/` 跳不过去。这条用例把归一化行为钉住。
  test('路径归一化：Windows 反斜杠路径同样能匹配排除名单与打包目录判定', () {
    expect(_posix(r'test\no_test_node_data_test.dart'),
        'test/no_test_node_data_test.dart');
    expect(_guardFiles.contains(_posix(r'test\no_test_node_data_test.dart')),
        isTrue);
    expect(_posix(r'lib\core\services\x.dart').startsWith('lib/'), isTrue);
    expect(_posix(r'D:\a\moneyfly\moneyfly\build\app\x.dll')
        .contains('/build/'), isTrue);
  });
}

/// 单段文本的四项检查（原文与 base64 解出的内容共用同一套规则）
void _checkText({
  required String text,
  required String where,
  required bool isGuardFile,
  required List<String> problems,

}) {
  for (final needle in _incidentBlocklist) {
    if (!isGuardFile && text.contains(needle)) {
      problems.add('[$where] 命中本次事件硬黑名单：${_mask(needle)}');
    }
  }

  for (final m in _nodeUri.allMatches(text)) {
    final host = m.group(1)!;
    if (!_hostAllowed(host)) {
      problems.add('[$where] 节点链接指向非文档主机：${_mask(host)}');
    }
  }

  for (final m in _ipPort.allMatches(text)) {
    final ip = m.group(1)!;
    if (!_ipAllowed(ip)) {
      problems.add('[$where] 出现公网 IP:端口（疑似真实节点）：${_mask(ip)}');
    }
  }

  for (final m in _pbk.allMatches(text)) {
    final key = m.group(1)!;
    if (!_allowedRealityPbk.contains(key)) {
      problems.add('[$where] REALITY 公钥未登记为假值：${_mask(key)}');
    }
  }
}

/// base64 / base64url 解一层；不像文本就返回 null（避免二进制噪声误报）
String? _tryDecodeB64(String run) {
  try {
    final padded = run.padRight((run.length + 3) & ~3, '=');
    final bytes = base64.decode(padded.replaceAll('-', '+').replaceAll('_', '/'));
    if (bytes.length < 16) return null;
    final printable = bytes
        .take(400)
        .where((b) => (b >= 32 && b < 127) || b == 10 || b == 13 || b == 9)
        .length;
    if (printable / (bytes.length < 400 ? bytes.length : 400) < 0.85) {
      return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  } on FormatException {
    return null;
  }
}

/// 读出 pubspec.yaml 里 `flutter: assets:` 声明的资源（目录会展开）
List<String> _declaredAssets(Directory root) {
  final pubspec = File('${root.path}/pubspec.yaml');
  if (!pubspec.existsSync()) return const [];
  final doc = loadYaml(pubspec.readAsStringSync());
  final flutter = doc is Map ? doc['flutter'] : null;
  final assets = flutter is Map ? flutter['assets'] : null;
  if (assets is! List) return const [];

  final out = <String>[];
  for (final entry in assets) {
    if (entry is! String) continue;
    final path = '${root.path}/$entry';
    final dir = Directory(path);
    if (dir.existsSync()) {
      dir.listSync(recursive: true).whereType<File>().forEach(
            (f) => out.add(f.path.substring(root.path.length + 1)),
          );
    } else {
      out.add(entry);
    }
  }
  return out;
}

String _decodeUtf16Le(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}
