import 'dart:convert';
import 'dart:math';

import '../models/models.dart';

/// sing-box 配置生成器（目标内核：sing-box 1.14.x）。
///
/// 与 v2.x 旧内核版的**功能对齐**：同样的入参、同样的路由语义、同样走 Clash API
/// 做模式/节点热切换，只是产物从 Clash YAML 变成 sing-box JSON。
///
/// 与旧内核的路线差异（都是 sing-box 的硬约束，不是取舍）：
/// - 没有内置 GEOSITE/GEOIP 规则：sing-box 1.12 起移除 legacy geo 字段，
///   国内分流改用 **binary rule-set（.srs）**（SagerNet/sing-geosite、
///   SagerNet/sing-geoip 的 geosite-cn / geoip-cn）；
/// - 没有内置 GLOBAL 组：全局模式用 `clash_mode: "Global"` 规则 + [select]
///   选择器实现，切节点仍是 PUT /proxies/select；
/// - 入站 UDP：mixed 入站走 SOCKS5 UDP ASSOCIATE，无需额外开关；
/// - hysteria v1 不被 sing-box 支持（只有 hysteria2），此类节点会被跳过。
class SingBoxConfigBuilder {
  SingBoxConfigBuilder._();

  /// UDP + TLS（QUIC/自定义 TLS）协议：证书校验放宽的适用类型
  static const _udpTlsTypes = {'hysteria', 'hysteria2', 'tuic'};

  /// sing-box 不支持 / 暂不映射的 Clash 协议（生成时跳过并计数）
  static const _unsupportedTypes = {
    'hysteria', // sing-box 只有 hysteria2
    // sing-box 1.6 起删除 ssr 出站：留着会让内核 FATAL 拒绝**整份配置**
    // （initialize outbound[N]: ShadowsocksR is deprecated and removed）
    'ssr',
    'shadowsocksr',
    'mieru',
    'snell',
    'juicity',
    'ssh', // 需要 private_key 配置，订阅里极少见
  };

  static String generateSecret() {
    final rng = Random.secure();
    return List.generate(
        16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 生成完整 sing-box 配置（Map 形式，由调用方 jsonEncode 后写入文件）。
  ///
  /// 入参与 [SingBoxConfigBuilder.build] 完全一致（便于两端共用调用方代码），
  /// 仅新增 [ruleSetDir]：`.srs` 规则集所在的**绝对路径**目录。
  static Map<String, dynamic> build({
    required List<ProxyNode> nodes,
    required String selectedTag,
    required bool smartMode,
    String dns = '223.5.5.5',
    String tunMode = 'off',
    String logLevel = 'warning',
    String dnsMode = 'auto',
    bool bypassLan = true,
    int localPort = 2080,
    int clashApiPort = 9090,
    bool geoReady = true,
    String? clashApiSecret,
    String tunStack = 'gvisor',
    List<String> forceProxyDomains = const [],
    List<String> bypassDomains = const [],
    List<String> dnsNameservers = const [],
    List<String> fakeIpFilterExtra = const [],
    bool udpSkipCertVerify = true,
    bool tunAutoRoute = false,
    bool tunFdInjected = false,
    // 兼容旧调用方：sing-box 一律用 .srs 规则集，此开关不再影响产物
    bool useMrsRuleSet = false,
    String? ruleSetDir,
  }) {
    final secret = clashApiSecret ?? generateSecret();
    final isTun = tunMode != 'off';
    final ports = _sanitizePorts(localPort, clashApiPort);
    final stack =
        const {'system', 'gvisor', 'mixed'}.contains(tunStack) ? tunStack : 'gvisor';
    // fake-ip 生效条件与旧版一致：显式选择，或 auto 且走 TUN
    final useFakeIp =
        dnsMode == 'fake-ip' || (dnsMode != 'redir-host' && isTun);

    final built =
        buildOutbounds(nodes, udpSkipCertVerify: udpSkipCertVerify);
    final nodeOutbounds = built.outbounds;
    final names = built.names;
    final defaultNode = names.contains(selectedTag)
        ? selectedTag
        : (names.isNotEmpty ? names.first : null);

    // ===== 出站 =====
    final selector = <String, dynamic>{
      'type': 'selector',
      'tag': 'select',
      // select 组默认选中项放首位：重启后线路不丢
      'outbounds': [
        ...names.where((n) => n != defaultNode),
        'direct',
      ],
    };
    if (defaultNode != null) {
      (selector['outbounds'] as List).insert(0, defaultNode);
      selector['default'] = defaultNode;
    }
    final outbounds = <Map<String, dynamic>>[
      selector,
      ...nodeOutbounds,
    ];

    // ===== DNS =====
    final nsList = dnsNameservers.isNotEmpty ? dnsNameservers : <String>[dns];
    final servers = <Map<String, dynamic>>[];
    final tags = <String>[];
    var idx = 0;
    for (final raw in nsList) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      final tag = idx == 0 ? 'dns-main' : 'dns-$idx';
      servers.add(_dnsServer(s, tag));
      tags.add(tag);
      idx++;
    }
    if (tags.isEmpty) {
      servers.add(_dnsServer('223.5.5.5', 'dns-main'));
      tags.add('dns-main');
    }
    // 本地兜底解析器：处理 hosts/内网域名，且 fake-ip 过滤的域名走它
    servers.add({'type': 'local', 'tag': 'dns-local'});
    if (useFakeIp) {
      servers.add({
        'type': 'fakeip',
        'tag': 'dns-fakeip',
        'inet4_range': '198.18.0.0/15',
      });
    }

    final dnsRules = <Map<String, dynamic>>[
      // 内网/本地点名一律真实解析，绝不进 fake-ip
      {
        'domain_suffix': [
          'lan', 'local', 'localhost', 'localdomain', 'home.arpa',
          ...fakeIpFilterExtra.where((e) => e.trim().isNotEmpty),
        ],
        'server': 'dns-local',
      },
      {
        'domain': ['localhost.ptlogin2.qq.com'],
        'server': 'dns-local',
      },
      if (useFakeIp)
        {
          'query_type': ['A', 'AAAA'],
          'server': 'dns-fakeip',
        },
    ];

    // ===== 规则集（.srs，随包分发/用户更新）=====
    // ruleSetDir 为空串 = 用相对文件名（iOS 扩展的工作目录即内核 homeDir）
    final useGeo = geoReady && ruleSetDir != null;
    final ruleSets = <Map<String, dynamic>>[
      if (useGeo) ...[
        {
          'type': 'local',
          'tag': 'geosite-cn',
          'format': 'binary',
          'path': _ruleSetPath(ruleSetDir, 'geosite-cn.srs'),
        },
        {
          'type': 'local',
          'tag': 'geoip-cn',
          'format': 'binary',
          'path': _ruleSetPath(ruleSetDir, 'geoip-cn.srs'),
        },
      ],
    ];

    // ===== 路由规则 =====
    final loopback = <String>['127.0.0.0/8'];
    final lanCidrs = <String>[
      ...loopback,
      if (bypassLan) ...['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
    ];
    final proxyDomains = _normalizeDomains([
      ...defaultForceProxyDomains,
      ...forceProxyDomains,
    ]);

    final rules = <Map<String, dynamic>>[
      // 嗅探：TUN 场景下只拿到 IP 包，必须从 TLS/HTTP 握手取真实域名，
      // 否则 chatgpt/linkedin 这类被污染 IP 会被 geoip-cn 判成直连
      {'action': 'sniff'},
      // 内核 DNS 劫持：TUN 里 53 端口流量直接交给内置 DNS（fake-ip 生效）
      {'protocol': 'dns', 'action': 'hijack-dns'},

      // ---- 全局模式：本地/局域网直连，其余全部走代理 ----
      {
        'clash_mode': 'Global',
        'ip_cidr': lanCidrs,
        'outbound': 'direct',
      },
      {'clash_mode': 'Global', 'outbound': 'select'},

      // ---- 智能模式（Rule）----
      // 用户自定义直连名单（最高优先级）
      ..._bypassRules(bypassDomains),
      // 回环 + 局域网直连
      {
        'clash_mode': 'Rule',
        'ip_cidr': lanCidrs,
        'outbound': 'direct',
      },
      // 「必须走代理」名单：排在规则集之前，盖掉被污染 IP / 被误收录的 CDN
      if (proxyDomains.isNotEmpty)
        {
          'clash_mode': 'Rule',
          'domain_suffix': proxyDomains,
          'outbound': 'select',
        },
      // 国内直连（离线 .srs 规则集；缺失时降级全代理，内核照常启动）
      if (useGeo) ...[
        {
          'clash_mode': 'Rule',
          'rule_set': ['geosite-cn'],
          'outbound': 'direct',
        },
        {
          'clash_mode': 'Rule',
          'rule_set': ['geoip-cn'],
          'outbound': 'direct',
        },
      ],
    ];

    final cfg = <String, dynamic>{
      // ===== 元数据（ProxyCore 读取后剥离，不写入配置文件）=====
      '_tunMode': tunMode,
      '_localPort': ports.localPort,
      '_clashApiPort': ports.clashApiPort,
      '_clashApiSecret': secret,

      'log': {
        'level': _logLevel(logLevel),
        'timestamp': true,
      },

      'dns': {
        'servers': servers,
        'rules': dnsRules,
        'final': tags.first,
        // sing-box 1.12+：DNS 解析策略（默认 prefer_ipv4，与 ipv6:false 一致）
        'strategy': 'prefer_ipv4',
      },

      // ===== 入站 =====
      'inbounds': [
        // 本机 mixed（HTTP+SOCKS5 同端口）——系统代理指向它
        if (tunMode != 'force')
          {
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': '127.0.0.1',
            'listen_port': ports.localPort,
          },
        // TUN 虚拟网卡
        if (isTun) _tunInbound(
          stack: stack,
          autoRoute: tunAutoRoute,
          bypassLan: bypassLan,
          fdInjected: tunFdInjected,
        ),
      ],

      'outbounds': outbounds,
      if (built.endpoints.isNotEmpty) 'endpoints': built.endpoints,

      'route': {
        'rules': rules,
        if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
        'final': 'select',
        // 出站域名解析走内置 DNS（否则 sing-box 1.12+ 启动报错）
        'default_domain_resolver': {'server': tags.first},
        // 桌面：内核自己选出口网卡并随网络切换自动更新（TUN auto_route 必备）
        if (isTun && tunAutoRoute) 'auto_detect_interface': true,
      },

      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:${ports.clashApiPort}',
          'secret': secret,
          // 与旧版一致：Rule/Global 两态，PATCH /configs 热切换
          'default_mode': smartMode ? 'Rule' : 'Global',
        },
        // 不要把连接/规则状态写盘：移动端扩展容器空间有限，且每次连接
        // 都是新配置，缓存无意义
        'cache_file': {'enabled': false},
      },
    };
    return cfg;
  }

  /// TUN 入站。fd 注入场景（Android VpnService / iOS PacketTunnel）由原生层
  /// 通过 libbox 的 PlatformInterface 打开 TUN 并把 fd 交给内核，这里的字段
  /// 只作为地址/MTU/栈的声明；桌面场景（CLI）则是内核自己建接口推路由。
  static Map<String, dynamic> _tunInbound({
    required String stack,
    required bool autoRoute,
    required bool bypassLan,
    required bool fdInjected,
  }) {
    return {
      'type': 'tun',
      'tag': 'tun-in',
      // sing-box 1.12+：旧 inet4_address(字符串) 已移除，必须是 address 数组
      'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
      'mtu': fdInjected ? 1500 : 9000,
      'auto_route': autoRoute,
      'strict_route': false,
      'stack': stack,
      // 局域网在路由层排除（桌面 auto_route 时才有意义）：
      // NAS / 网络打印机 / mDNS / 局域网联机不必绕进 TUN
      if (bypassLan && autoRoute)
        'route_exclude_address': const [
          '127.0.0.0/8',
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '169.254.0.0/16',
          '224.0.0.0/4',
        ],
    };
  }

  /// 规则集路径：目录为空 → 相对文件名（由内核 homeDir/-D 解析）
  static String _ruleSetPath(String? dir, String file) =>
      (dir == null || dir.isEmpty || dir == '.') ? file : '$dir/$file';

  /// 是否为 IP 字面量（不是域名）
  static bool _isIpLiteral(String host) {
    if (host.contains(':')) return true; // IPv6
    final parts = host.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  static Map<String, dynamic> _dnsServer(String spec, String tag) {
    // 支持 "223.5.5.5"、"223.5.5.5:53"、"tls://1.1.1.1"、"https://dns.alidns.com/dns-query"
    var s = spec;
    var type = 'udp';
    if (s.startsWith('tls://')) {
      type = 'tls';
      s = s.substring(6);
    } else if (s.startsWith('https://') || s.startsWith('h3://')) {
      type = s.startsWith('h3://') ? 'h3' : 'https';
      final rest = spec.split('://').last;
      final host = rest.split('/').first;
      final path = rest.contains('/') ? '/${rest.split('/').skip(1).join('/')}' : '';
      return {
        'type': type,
        'tag': tag,
        'server': host,
        if (path.isNotEmpty && path != '/') 'path': path,
        // sing-box 1.12+：server 是域名时必须指定解析器（否则内核 FATAL
        // "missing domain resolver for domain server address"）
        if (!_isIpLiteral(host.split(':').first)) 'domain_resolver': 'dns-local',
      };
    } else if (s.startsWith('quic://')) {
      type = 'quic';
      s = s.substring(7);
    }
    var server = s;
    var port = 0;
    final ci = s.lastIndexOf(':');
    if (ci > 0 && !s.substring(ci + 1).contains('.')) {
      final p = int.tryParse(s.substring(ci + 1));
      if (p != null) {
        port = p;
        server = s.substring(0, ci);
      }
    }
    return {
      'type': type,
      'tag': tag,
      'server': server,
      if (port > 0) 'server_port': port,
      if (!_isIpLiteral(server)) 'domain_resolver': 'dns-local',
    };
  }

  static String _logLevel(String level) => switch (level.toLowerCase()) {
        'debug' => 'debug',
        'info' => 'info',
        'error' => 'error',
        'warning' || 'warn' => 'warn',
        'trace' => 'trace',
        _ => 'warn',
      };

  /// 节点列表 → sing-box `outbounds`（生产配置与测速内核共用）。
  ///
  /// 返回的 `names` 为通过过滤的 tag 列表（保持原顺序）；`outbounds` 已按 tag
  /// 去重。不支持/无法映射的协议节点会被跳过（计数见 [skippedTypes]）。
  static ({List<Map<String, dynamic>> outbounds, List<String> names,
      List<Map<String, dynamic>> endpoints}) buildOutbounds(
    List<ProxyNode> nodes, {
    bool udpSkipCertVerify = true,
    Set<String>? skippedTypes,
  }) {
    final validNodes =
        nodes.where((n) => n.server.isNotEmpty && n.port > 0).toList();
    final seen = <String>{};
    final outbounds = <Map<String, dynamic>>[];
    final endpoints = <Map<String, dynamic>>[];
    final names = <String>[];
    for (final n in validNodes) {
      final ob = _toOutbound(n, udpSkipCertVerify: udpSkipCertVerify);
      if (ob == null) {
        skippedTypes?.add(n.type);
        continue;
      }
      final tag = ob['tag'] as String;
      if (!seen.add(tag)) continue;
      // sing-box 1.11+：wireguard 是 endpoint（顶层 endpoints），
      // 作为 outbound 写会 FATAL -> 分开放
      if (ob['type'] == 'wireguard') {
        endpoints.add(ob);
      } else {
        outbounds.add(ob);
      }
      names.add(n.tag);
    }
    outbounds.add({'type': 'direct', 'tag': 'direct'});
    outbounds.add({'type': 'block', 'tag': 'block'});
    return (outbounds: outbounds, names: names, endpoints: endpoints);
  }

  /// Clash 节点 → sing-box outbound。返回 null 表示该协议不被支持。
  static Map<String, dynamic>? _toOutbound(
    ProxyNode n, {
    bool udpSkipCertVerify = true,
  }) {
    final raw = n.raw;
    final type = switch (n.type) {
      'shadowsocks' => 'shadowsocks',
      'ss' => 'shadowsocks',
      'ssr' || 'shadowsocksr' => 'shadowsocksr',
      'vmess' => 'vmess',
      'vless' => 'vless',
      'trojan' => 'trojan',
      'hysteria2' || 'hy2' => 'hysteria2',
      'tuic' => 'tuic',
      'anytls' => 'anytls',
      'socks5' || 'socks' => 'socks',
      'http' => 'http',
      'wireguard' => 'wireguard',
      _ => n.type,
    };
    if (_unsupportedTypes.contains(n.type) || _unsupportedTypes.contains(type)) {
      return null;
    }

    final base = <String, dynamic>{
      'type': type,
      'tag': n.tag,
      'server': n.server,
      'server_port': n.port,
    };
    final insecure = raw['skip-cert-verify'] == true;
    final sni = n.sni ?? raw['servername']?.toString();
    final alpn = _strList(raw['alpn']);
    final fingerprint = raw['client-fingerprint']?.toString();

    Map<String, dynamic> tls({bool withReality = false}) {
      final t = <String, dynamic>{
        'enabled': n.tls != false,
        if (sni != null && sni.isNotEmpty) 'server_name': sni,
        'insecure': insecure,
        if (alpn.isNotEmpty) 'alpn': alpn,
        if (fingerprint != null && fingerprint.isNotEmpty)
          'utls': {'enabled': true, 'fingerprint': fingerprint},
      };
      if (withReality) {
        final ro = raw['reality-opts'];
        if (ro is Map) {
          t['reality'] = {
            'enabled': true,
            'public_key': ro['public-key']?.toString() ?? '',
            'short_id': ro['short-id']?.toString() ?? '',
          };
        }
      }
      return t;
    }

    switch (type) {
      case 'vless':
        base['uuid'] = n.uuid ?? raw['uuid']?.toString() ?? '';
        final flow = n.flow ?? raw['flow']?.toString();
        if (flow != null && flow.isNotEmpty) base['flow'] = flow;
        final ro = raw['reality-opts'];
        final hasTls = n.tls == true || ro is Map || (sni != null && sni.isNotEmpty);
        if (hasTls) base['tls'] = tls(withReality: ro is Map);
        _applyTransport(base, n);
      case 'vmess':
        base['uuid'] = n.uuid ?? raw['uuid']?.toString() ?? '';
        final sec = n.cipher ?? raw['cipher']?.toString();
        base['security'] = (sec != null && sec.isNotEmpty && sec != 'auto')
            ? sec
            : 'auto';
        final alterId = raw['alterId'] ?? raw['alter-id'];
        if (alterId is num && alterId > 0) base['alter_id'] = alterId.toInt();
        if (n.tls == true) base['tls'] = tls();
        _applyTransport(base, n);
      case 'trojan':
        base['password'] = n.password ?? raw['password']?.toString() ?? '';
        base['tls'] = tls();
        _applyTransport(base, n);
      case 'shadowsocks':
        base['method'] = n.cipher ?? raw['cipher']?.toString() ?? 'aes-128-gcm';
        base['password'] = n.password ?? raw['password']?.toString() ?? '';
        base['udp_over_tcp'] = raw['udp-over-tcp'] == true;
        // plugin: obfs-local（http 混淆）/ v2ray-plugin
        final plugin = raw['plugin']?.toString();
        final pluginOpts = raw['plugin-opts'];
        if (plugin != null && plugin.isNotEmpty) {
          base['plugin'] = plugin;
          if (pluginOpts is Map) {
            base['plugin_opts'] = _pluginOpts(plugin, pluginOpts);
          }
        }
      case 'shadowsocksr':
        base['method'] = n.cipher ?? raw['cipher']?.toString() ?? 'aes-128-cfb';
        base['password'] = n.password ?? raw['password']?.toString() ?? '';
        base['obfs'] = raw['obfs']?.toString() ?? 'plain';
        base['obfs_param'] = raw['obfs-param']?.toString() ?? raw['obfs_param']?.toString() ?? '';
        base['protocol'] = raw['protocol']?.toString() ?? 'origin';
        base['protocol_param'] =
            raw['protocol-param']?.toString() ?? raw['protocol_param']?.toString() ?? '';
      case 'hysteria2':
        base['password'] = n.password ?? raw['password']?.toString() ?? raw['auth']?.toString() ?? '';
        final t = tls();
        // 这些协议的证书普遍是伪装 SNI，强制校验必然握手失败 —— 与旧版
        // 版同一策略：UDP+TLS 协议默认放宽（设置可关）
        if (udpSkipCertVerify && _udpTlsTypes.contains(n.type)) {
          t['insecure'] = true;
        }
        base['tls'] = t;
        final obfs = raw['obfs']?.toString();
        if (obfs != null && obfs.isNotEmpty) {
          base['obfs'] = {
            'type': obfs,
            'password': raw['obfs-password']?.toString() ?? '',
          };
        }
        final up = raw['up'] ?? raw['up-mbps'];
        final down = raw['down'] ?? raw['down-mbps'];
        if (up is num && up > 0) base['up_mbps'] = up.toInt();
        if (down is num && down > 0) base['down_mbps'] = down.toInt();
      case 'tuic':
        base['uuid'] = n.uuid ?? raw['uuid']?.toString() ?? '';
        base['password'] = n.password ?? raw['password']?.toString() ?? '';
        base['congestion_control'] =
            raw['congestion-controller']?.toString() ?? raw['congestion_control']?.toString() ?? 'cubic';
        final relay = raw['udp-relay-mode']?.toString() ?? raw['udp_relay_mode']?.toString();
        if (relay != null && relay.isNotEmpty) base['udp_relay_mode'] = relay;
        final t = tls();
        if (udpSkipCertVerify && _udpTlsTypes.contains(n.type)) {
          t['insecure'] = true;
        }
        base['tls'] = t;
      case 'anytls':
        base['password'] = n.password ?? raw['password']?.toString() ?? '';
        base['tls'] = tls();
        final idle = raw['idle-session-check-interval'];
        if (idle is num && idle > 0) {
          base['idle_session_check_interval'] = '${idle}s';
        }
      case 'socks':
        base['version'] = '5';
        if ((n.password ?? '').isNotEmpty) {
          base['username'] = raw['username']?.toString() ?? '';
          base['password'] = n.password!;
        }
      case 'http':
        if ((n.password ?? '').isNotEmpty) {
          base['username'] = raw['username']?.toString() ?? '';
          base['password'] = n.password!;
        }
        if (n.tls == true) base['tls'] = tls();
      case 'wireguard':
        // sing-box 1.11+ 把 wireguard 改成 **endpoint**（顶层 endpoints），
        // 字段是 address / private_key / peers[{address, port, public_key}]；
        // 写成普通 outbound 会 FATAL（unknown field "server"），整份配置作废。
        base.remove('server');
        base.remove('server_port');
        final priv = raw['private-key']?.toString() ??
            raw['private_key']?.toString() ??
            '';
        final peerKey = raw['public-key']?.toString() ??
            raw['public_key']?.toString() ??
            '';
        // 缺私钥/对端公钥的节点无法工作，直接跳过（避免生成无效 endpoint）
        if (priv.isEmpty || peerKey.isEmpty) return null;
        base['private_key'] = priv;
        base['peers'] = [
          {
            'address': n.server,
            'port': n.port,
            'public_key': peerKey,
            if ((raw['pre-shared-key']?.toString() ?? '').isNotEmpty)
              'pre_shared_key': raw['pre-shared-key']?.toString(),
            'allowed_ips': ['0.0.0.0/0', '::/0'],
          }
        ];
        // 订阅解析器把本地地址放在 raw['ip']（wireguard:// 的 ip= 参数）
        final addr = _strList(
            raw['local-address'] ?? raw['local_address'] ?? raw['address'] ?? raw['ip']);
        base['address'] = addr.isEmpty ? ['172.16.0.2/32'] : addr;
      default:
        return null;
    }
    return base;
  }

  /// Clash 传输层（ws/grpc/http）→ sing-box transport
  static void _applyTransport(Map<String, dynamic> base, ProxyNode n) {
    final network = n.network ?? n.raw['network']?.toString() ?? 'tcp';
    final raw = n.raw;
    switch (network) {
      case 'ws':
        final wsOpts = raw['ws-opts'];
        final path = n.wsPath ??
            (wsOpts is Map ? wsOpts['path']?.toString() : null) ??
            '/';
        final headers = <String, String>{};
        if (wsOpts is Map && wsOpts['headers'] is Map) {
          (wsOpts['headers'] as Map).forEach((k, v) {
            headers[k.toString()] = v.toString();
          });
        } else if (n.host != null && n.host!.isNotEmpty) {
          headers['Host'] = n.host!;
        }
        final maxEarly = wsOpts is Map ? wsOpts['max-early-data'] : null;
        final earlyHeader =
            wsOpts is Map ? wsOpts['early-data-header-name'] : null;
        base['transport'] = {
          'type': 'ws',
          'path': path,
          if (headers.isNotEmpty) 'headers': headers,
          if (maxEarly is num && maxEarly > 0)
            'max_early_data': maxEarly.toInt(),
          if (earlyHeader != null)
            'early_data_header_name': earlyHeader.toString(),
        };
      case 'grpc':
        final gOpts = raw['grpc-opts'];
        final svc = (gOpts is Map ? gOpts['grpc-service-name']?.toString() : null) ??
            n.wsPath ??
            '';
        base['transport'] = {
          'type': 'grpc',
          if (svc.isNotEmpty) 'service_name': svc,
        };
      case 'http' || 'h2':
        final hOpts = raw['http-opts'];
        final hosts = <String>[];
        if (hOpts is Map && hOpts['headers'] is Map) {
          final h = (hOpts['headers'] as Map)['Host'];
          if (h is List) {
            hosts.addAll(h.map((e) => e.toString()));
          } else if (h != null) {
            hosts.add(h.toString());
          }
        }
        if (hosts.isEmpty && n.host != null && n.host!.isNotEmpty) {
          hosts.add(n.host!);
        }
        final path = (hOpts is Map ? hOpts['path'] : null);
        base['transport'] = {
          'type': 'http',
          if (hosts.isNotEmpty) 'host': hosts,
          if (path is List && path.isNotEmpty)
            'path': path.first.toString()
          else if (path != null)
            'path': path.toString()
          else
            'path': n.wsPath ?? '/',
        };
      default:
        // tcp：sing-box 默认就是裸 TCP，无需 transport
        break;
    }
  }

  static String _pluginOpts(String plugin, Map opts) {
    final parts = <String>[];
    switch (plugin) {
      case 'obfs':
      case 'obfs-local':
        parts.add('obfs=${opts['mode'] ?? 'http'}');
        final host = opts['host']?.toString();
        if (host != null && host.isNotEmpty) parts.add('obfs-host=$host');
      case 'v2ray-plugin':
        parts.add('mode=${opts['mode'] ?? 'websocket'}');
        final host = opts['host']?.toString();
        if (host != null && host.isNotEmpty) parts.add('host=$host');
        final path = opts['path']?.toString();
        if (path != null && path.isNotEmpty) parts.add('path=$path');
        if (opts['tls'] == true) parts.add('tls');
      default:
        opts.forEach((k, v) => parts.add('$k=$v'));
    }
    return parts.join(';');
  }

  static List<String> _strList(dynamic v) {
    if (v is List) return [for (final e in v) e.toString()];
    if (v is String && v.isNotEmpty) return [v];
    return const [];
  }

  /// 测速专用内核的最小配置（**不带任何入站监听、不建 TUN、不碰系统代理**）。
  ///
  /// 与生产配置的差异（逐条都有理由）：
  /// - 没有 `inbounds`：不占用户端口、不会被误当系统代理目标；
  /// - 没有 `tun`：不建虚拟网卡、不动路由表（无需管理员权限）；
  /// - 不引用规则集：无需 .srs 文件，内核启动零网络；
  /// - `outbounds` 与真实连接完全一致（同一份 [buildOutbounds]），
  ///   保证「测速通过 ⇔ 真连接可用」。
  static Map<String, dynamic> buildProbe({
    required List<ProxyNode> nodes,
    required int controllerPort,
    String? clashApiSecret,
    String dns = '223.5.5.5',
    List<String> dnsNameservers = const [],
    String logLevel = 'warning',
    bool udpSkipCertVerify = true,
    Set<String>? onlyTags,
  }) {
    final secret = clashApiSecret ?? generateSecret();
    final pool =
        onlyTags == null ? nodes : nodes.where((n) => onlyTags.contains(n.tag)).toList();
    final built = buildOutbounds(pool, udpSkipCertVerify: udpSkipCertVerify);
    final nsList = dnsNameservers.isNotEmpty ? dnsNameservers : <String>[dns];
    final servers = <Map<String, dynamic>>[];
    final tags = <String>[];
    var idx = 0;
    for (final raw in nsList) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      final tag = idx == 0 ? 'dns-main' : 'dns-$idx';
      servers.add(_dnsServer(s, tag));
      tags.add(tag);
      idx++;
    }
    if (tags.isEmpty) {
      servers.add(_dnsServer('223.5.5.5', 'dns-main'));
      tags.add('dns-main');
    }
    servers.add({'type': 'local', 'tag': 'dns-local'});
    return <String, dynamic>{
      '_clashApiPort': controllerPort,
      '_clashApiSecret': secret,
      'log': {'level': _logLevel(logLevel), 'timestamp': true},
      'dns': {
        'servers': servers,
        'final': tags.first,
        'strategy': 'prefer_ipv4',
      },
      'outbounds': [
        {
          'type': 'selector',
          'tag': 'select',
          'outbounds': [...built.names, 'direct'],
          if (built.names.isNotEmpty) 'default': built.names.first,
        },
        ...built.outbounds,
      ],
      if (built.endpoints.isNotEmpty) 'endpoints': built.endpoints,
      'route': {
        'rules': <Map<String, dynamic>>[
          {'action': 'sniff'},
          // 无规则集：没有国内直连判定，探测流量一律走 select
          {'outbound': 'select'},
        ],
        'final': 'select',
        'default_domain_resolver': {'server': tags.first},
      },
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:$controllerPort',
          'secret': secret,
          'default_mode': 'Rule',
        },
        'cache_file': {'enabled': false},
      },
    };
  }

  /// 端口健壮化：越界回退默认值；两端口冲突时让 API 端口让位。
  static ({int localPort, int clashApiPort}) _sanitizePorts(
      int localPort, int clashApiPort) {
    int fix(int v, int fallback) => (v >= 1024 && v <= 65535) ? v : fallback;
    final lp = fix(localPort, 2080);
    var ap = fix(clashApiPort, 9090);
    if (ap == lp) ap = lp == 9090 ? 9091 : 9090;
    return (localPort: lp, clashApiPort: ap);
  }

  static List<Map<String, dynamic>> _bypassRules(List<String> entries) {
    final rules = <Map<String, dynamic>>[];
    for (final e in entries) {
      final v = e.trim();
      if (v.isEmpty) continue;
      final lower = v.toLowerCase();
      if (lower.startsWith('ip-cidr:')) {
        final cidr = v.substring('IP-CIDR:'.length).trim();
        if (cidr.isNotEmpty) {
          rules.add({
            'clash_mode': 'Rule',
            'ip_cidr': [cidr],
            'outbound': 'direct',
          });
        }
      } else if (lower.startsWith('domain:')) {
        final d = v.substring('DOMAIN:'.length).trim();
        if (d.isNotEmpty) {
          rules.add({
            'clash_mode': 'Rule',
            'domain': [d],
            'outbound': 'direct',
          });
        }
      } else {
        rules.add({
          'clash_mode': 'Rule',
          'domain_suffix': [v],
          'outbound': 'direct',
        });
      }
    }
    return rules;
  }

  /// 域名清单规整：去空白、去协议/路径、小写、去重（保持顺序）
  static List<String> _normalizeDomains(Iterable<String> raw) {
    final out = <String>[];
    for (final v in raw) {
      var d = v.trim().toLowerCase();
      if (d.isEmpty) continue;
      if (d.contains('://')) d = d.split('://').last;
      if (d.contains('/')) d = d.split('/').first;
      if (d.startsWith('*.')) d = d.substring(2);
      d = d.replaceAll(RegExp(r'^\.+'), '');
      if (d.isEmpty || out.contains(d)) continue;
      out.add(d);
    }
    return out;
  }

  /// 内置「必须走代理」域名后缀
  static const List<String> defaultForceProxyDomains = [
    // AI
    'openai.com',
    'chatgpt.com',
    'chat.com',
    'oaistatic.com',
    'oaiusercontent.com',
    'anthropic.com',
    'claude.ai',
    'gemini.google.com',
    'aistudio.google.com',
    'generativelanguage.googleapis.com',
    'copilot.microsoft.com',
    'perplexity.ai',
    'grok.com',
    'x.ai',
    // 社交 / 内容
    'linkedin.com',
    'licdn.com',
    'tiktok.com',
    'tiktokv.com',
    'tiktokcdn.com',
    'tiktokcdn-us.com',
    'byteoversea.com',
    'ibytedtos.com',
    'musical.ly',
    'x.com',
    'twitter.com',
    'twimg.com',
    'facebook.com',
    'fbcdn.net',
    'instagram.com',
    'cdninstagram.com',
    'reddit.com',
    'redd.it',
    'redditmedia.com',
    'redditstatic.com',
    'telegram.org',
    't.me',
    'telegram.me',
    'telesco.pe',
    'discord.com',
    'discordapp.com',
    'discord.gg',
    'youtube.com',
    'youtu.be',
    'ytimg.com',
    'googlevideo.com',
    'ggpht.com',
    // 流媒体
    'netflix.com',
    'nflxvideo.net',
    'nflximg.net',
    'disneyplus.com',
    'spotify.com',
  ];

  /// 序列化为 JSON 字符串（写入 config.json 用；剥离 `_` 开头的元数据键）
  static String encode(Map<String, dynamic> cfg) {
    final filtered = Map<String, dynamic>.fromEntries(
        cfg.entries.where((e) => !e.key.startsWith('_')));
    return const JsonEncoder.withIndent('  ').convert(filtered);
  }
}
