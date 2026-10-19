import 'dart:math';

import '../models/models.dart';

/// mihomo (Clash.Meta) 配置生成器。
///
/// mihomo 原生读 Clash YAML，订阅解析出的节点 raw（Clash map）直接可用，
/// SSR/VMess/VLESS/Trojan/Hysteria2/TUIC/AnyTLS/WireGuard 等协议全部由内核原生支持。
///
/// 路由设计：
/// - 智能模式（rule）：本地/局域网直连 + 国内(GEOSITE/GEOIP cn)直连 + 其余走代理
/// - 全局模式（global）：mihomo 内核 mode=global 时全部流量走内置 GLOBAL 组，
///   由 Clash API PATCH /configs 热切换，不断网。
/// - 模式/节点热切换全部走 Clash API（external-controller），
///   切节点时 select 组管智能模式、GLOBAL 组管全局模式。
class MihomoConfigBuilder {
  /// UDP + TLS（QUIC/自定义 TLS）协议：证书校验放宽的适用类型
  static const _udpTlsTypes = {'hysteria', 'hysteria2', 'tuic'};

  MihomoConfigBuilder._();

  static String generateSecret() {
    final rng = Random.secure();
    return List.generate(
        16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 生成完整 mihomo 配置（Map 形式，由调用方序列化为 YAML 写入文件）。
  ///
  /// [nodes] 订阅解析出的节点（raw 为 Clash YAML 原始 map）
  /// [selectedTag] 当前选中节点的 name（select 组默认项）
  /// [smartMode] true=Rule 智能分流 / false=Global 全局代理
  /// [tunMode] 'auto'=TUN+系统代理 / 'force'=仅 TUN / 'off'=仅系统代理
  /// [geoReady] 离线 geo 数据(country.mmdb/geosite.dat)是否已就位；
  ///            缺失时智能模式降级为「全部走代理」，避免内核起不来
  static Map<String, dynamic> build({
    required List<ProxyNode> nodes,
    required String selectedTag,
    required bool smartMode,
    String dns = '223.5.5.5',
    String tunMode = 'off',
    String logLevel = 'warning',
    /// DNS 模式：auto / fake-ip / redir-host
    String dnsMode = 'auto',
    bool bypassLan = true,
    int localPort = 2080,
    int clashApiPort = 9090,
    bool geoReady = true,
    String? clashApiSecret,
    /// TUN 栈（Android 机型兼容性切换；桌面 TUN 场景也可用）
    String tunStack = 'gvisor',
    /// 「必须走代理」的域名后缀（用户自定义 + App 内置默认，见
    /// [defaultForceProxyDomains]）：生成 `DOMAIN-SUFFIX,xxx,select`，**排在
    /// 所有直连规则之前**，覆盖 GEOSITE/GEOIP 的国内判定。
    ///
    /// 为什么必须有：智能模式（rule）的判据是「国内直连、其余走代理」，而
    /// chatgpt.com / gemini.google.com / linkedin.com / tiktok.com 这类站点
    /// 经常出现两种误判 ——
    ///   ① 被国内 DNS 解析出「被污染但落在 CN 段」的 IP → GEOIP,CN 命中 → 直连 →
    ///      必然打不开（全局模式能开，因为全局不判 GEOIP）；
    ///   ② 少数字节系 CDN 域名（tiktokcdn/tiktokv 等）被 geolocation-cn 收录 →
    ///      GEOSITE,cn 命中 → 直连。
    /// 这两类只有「显式指定走代理」才稳，所以做成内置默认名单 + 用户可追加。
    List<String> forceProxyDomains = const [],

    /// 用户自定义直连名单，三类条目（命中 DIRECT，优先级最高）：
    /// - 域名后缀（如 example.com）→ DOMAIN-SUFFIX
    /// - `IP-CIDR:` 前缀 + IP 段（如 IP-CIDR:192.168.1.0/24）→ IP-CIDR
    /// - `DOMAIN:` 前缀 + 精确域名（如 DOMAIN:portal.example.com）→ DOMAIN
    List<String> bypassDomains = const [],
    /// 主 DNS 服务器列表（非空时替换单值 [dns]，dns.nameserver 写入列表）
    List<String> dnsNameservers = const [],
    /// 追加到 fake-ip-filter 的域名/通配（如 `*.lan`；仅 fake-ip 生效时写入）
    List<String> fakeIpFilterExtra = const [],
    /// UDP+TLS 协议（hysteria/hysteria2/tuic）是否放宽证书校验（默认 true）。
    /// 这些协议的链接普遍使用伪装 SNI + 不匹配证书，开启校验必然握手失败；
    /// 见下方写入 `skip-cert-verify` 处的实测说明。
    bool udpSkipCertVerify = true,
    /// TUN 是否由内核自己建接口/推路由（桌面 true；Android false —— 路由由
    /// 原生 VpnService 全量下发，非 root 不改路由表）。由调用方按平台传入，
    /// 生成器保持纯函数、便于测试。
    bool tunAutoRoute = false,
    /// TUN 的 fd 是否由**外部注入**（Android VpnService / iOS PacketTunnel 扩展）。
    ///
    /// iOS 专用：用 `.mrs` 规则集（`RULE-SET,cn`）替代 `GEOSITE,cn`。
    ///
    /// 为什么必须换：mihomo 加载 `GEOSITE,cn` 会用 succinct 匹配器把 11 万条域名
    /// 建成内存索引，**启动期一次申请约 74MB 堆**（本机实测：HeapAlloc 峰值 74MB、
    /// 进程 RSS 167MB、耗时 146ms）。iOS 的 PacketTunnel 扩展内存上限只有几十 MB
    /// —— 真机表现就是内核刚起 ~200ms 被系统直接杀掉，一行日志都没有（连
    /// stderr 都是空的），App 侧只能看到「内核启动超时」。
    ///
    /// `.mrs` 是 mihomo 自己的规则集格式（zstd + 可直接查表，无需建索引）：
    /// 同样 11 万条域名，实测堆 +2MB、启动 15ms、RSS 50MB（规则数 111021，与
    /// GEOSITE,cn 的 110984 条等价）。文件缺失时该规则不匹配 → 退化为全代理，
    /// 内核照常启动（已实测），不会把连接搞挂。
    bool useMrsRuleSet = false,

    /// iOS 上必须为 true：那边的 fd 是我们用 `socketpair` 做用户态桥造的
    /// （iOS 16.4+ 的 `NEPacketTunnelFlow` 不再暴露 utun fd，详见
    /// ios/PacketTunnel/PacketTunnelProvider.swift 的 PacketBridge 说明）。
    /// 而 mihomo 在 Darwin 上**默认 `recvmsgx: true`**，它会在建 TUN 时对 fd 做
    /// utun 专属的 `setsockopt(UTUN_OPT_MAX_PENDING_PACKETS)`，非 utun fd 会直接
    /// 失败 —— 实测（本地同版本内核复现）：
    ///   Start TUN listening error: configure tun interface:
    ///   SetsockoptInt UTUN_OPT_MAX_PENDING_PACKETS: operation not supported on socket
    /// 真机表现就是扩展日志停在「调用 MihomelibStart…」之后、内核永远起不来。
    /// 关掉它（`recvmsgx: false`）后本地端到端验证通过：灌进去的 DNS 查询被内核
    /// 劫持并原样回包。
    bool tunFdInjected = false,
  }) {
    final secret = clashApiSecret ?? generateSecret();
    final mode = smartMode ? 'rule' : 'global';
    final isTun = tunMode != 'off';
    // 端口健壮化：非法（<1024 / >65535 / 0）或两端口冲突时回退默认值。
    // 内核遇到非法端口只打 error 日志却**继续运行**、Clash API 仍返回 200，
    // App 因此误判「已连接」并把系统代理指向死端口 → 整机断网且无提示。
    final ports = _sanitizePorts(localPort, clashApiPort);
    // TUN 栈白名单：非法值会让内核 fatal 退出（Parse config error: invalid tun stack）
    final stack =
        const {'system', 'gvisor', 'mixed'}.contains(tunStack) ? tunStack : 'gvisor';
    // fake-ip 生效条件：显式选择，或 auto 且走 TUN（桌面 auto 保持传统解析）
    final useFakeIp =
        dnsMode == 'fake-ip' || (dnsMode != 'redir-host' && isTun);

    // 过滤掉面板伪节点（📢官网/⏰到期 等信息节点，server=baidu.com 等）
    final built = buildProxyMaps(nodes, udpSkipCertVerify: udpSkipCertVerify);
    final proxies = built.proxies;
    final names = built.names;

    // select 组默认选中项放列表首位 —— mihomo 的 select 组启动时选中
    // proxies 列表第一项（无 YAML 指定选中的字段），保证重启后线路不丢
    final defaultNode =
        names.contains(selectedTag) ? selectedTag : (names.isNotEmpty ? names.first : null);
    final selectMembers = <String>[
      ?defaultNode,
      for (final n in names)
        if (n != defaultNode) n,
      'DIRECT',
    ];
    if (selectMembers.isEmpty) {
      // 无任何可用节点：仍给一个可解析的组，内核可启动（连接层会拦空节点）
      selectMembers.add('DIRECT');
    }

    // 规则列表（mihomo 首条匹配即停）
    final rules = <String>[
      // 用户自定义「直连名单」：优先级最高，名单内条目不走代理。
      // 三类条目按前缀映射：IP-CIDR: → IP-CIDR 规则；DOMAIN: → DOMAIN
      // 规则（精确域名）；其余（域名后缀）→ DOMAIN-SUFFIX 规则。
      for (final d in bypassDomains) ..._bypassRules(d),
      // 回环地址永远直连（内核 API / 本机服务必须可达）
      'IP-CIDR,127.0.0.0/8,DIRECT',
      // 局域网按设置直连
      if (bypassLan) ...[
        'IP-CIDR,10.0.0.0/8,DIRECT',
        'IP-CIDR,172.16.0.0/12,DIRECT',
        'IP-CIDR,192.168.0.0/16,DIRECT',
      ],
      // 「必须走代理」名单（内置默认 + 用户追加）：必须在 GEOSITE/GEOIP 之前。
      // 原因：chatgpt/gemini/linkedin/tiktok 这类站点，国内 DNS 常返回"被污染但
      // 落在 CN 段"的 IP → GEOIP,CN 命中 → DIRECT → 智能模式必然打不开；少数
      // 字节系 CDN 域名还被 geolocation-cn 收录 → GEOSITE,cn 命中 → 同样直连。
      // 显式置顶可以把这两种误判一次性盖掉（用户仍可用「直连名单」强制直连）。
      for (final d in _normalizeDomains([
        ...defaultForceProxyDomains,
        ...forceProxyDomains,
      ]))
        'DOMAIN-SUFFIX,$d,select',
      // 智能模式：国内直连（离线 country.mmdb / geosite.dat / cn.mrs；缺失则降级全代理）
      // iOS 走 RULE-SET,cn（.mrs 规则集）而不是 GEOSITE,cn —— 见 useMrsRuleSet
      if (geoReady) ...[
        if (useMrsRuleSet) 'RULE-SET,cn,DIRECT' else 'GEOSITE,cn,DIRECT',
        'GEOIP,CN,DIRECT',
      ],
      // 其余走代理（select 组，App 通过 Clash API 热切换选中）
      'MATCH,select',
    ];

    // 主 DNS 列表：显式传入的非空列表优先；否则回退单值 dns（兼容旧配置）
    final nameservers =
        dnsNameservers.isNotEmpty ? dnsNameservers : <String>[dns];

    final cfg = <String, dynamic>{
      // ===== 元数据（ProxyCore 读取后剥离，不写入配置文件）=====
      '_tunMode': tunMode,
      '_localPort': ports.localPort,
      '_clashApiPort': ports.clashApiPort,
      '_clashApiSecret': secret,

      // ===== mihomo 基础 =====
      // 本机 mixed 入站（HTTP + SOCKS5 同一端口，系统代理指向它）
      'mixed-port': ports.localPort,
      // Clash API 管理通道（切模式/切节点/测速/流量统计全部走这里）
      'external-controller': '127.0.0.1:${ports.clashApiPort}',
      'secret': secret,
      // 智能 = rule；全局 = global（PATCH /configs 热切换）
      'mode': mode,
      'log-level': logLevel,
      'ipv6': false,
      'allow-lan': false,
      // 入站连接不查进程（省资源；find-process-mode 需管理员权限）
      'find-process-mode': 'off',
      // 统一延迟计算口径（测速 UI 与内核一致）
      'unified-delay': true,
      'tcp-concurrent': false,
      // 显式关闭 geo 数据自动更新/下载：geosite.dat/country.mmdb 由 App 内置
      // assets 提供并随版本更新，内核不得在启动时联网检查/下载（国内网络直连
      // GitHub 被墙会卡 90s 甚至启动失败）。文件缺失时（异常）规则已降级，
      // 内核不会走到下载路径。
      'geo-auto-update': false,

      // ===== 域名嗅探（sniffer）=====
      // 为什么要开：TUN 场景下内核拿到的是**IP 包**，若 DNS 返回了被污染、
      // 或恰好落在国内网段的 IP，`GEOIP,CN` 就会把 chatgpt.com / linkedin.com
      // 这类站点判成直连 → 打不开（智能模式的典型故障）。嗅探从 TLS/HTTP
      // 握手里取回真实域名，规则改按域名匹配，路由判断立刻正确。
      // parse-pure-ip：只对「纯 IP 目标」嗅探，域名连接不额外解析（省开销）。
      // 只写 sniffer 最早期的三件套（enable / parse-pure-ip / sniff）：
      // iOS 内置的是 mihomo 1.10.0（gomobile 静态库），新版本才有的字段
      // （skip-domain / force-domain 等）在那上面会让内核 parse 失败直接退出。
      'sniffer': {
        'enable': true,
        'parse-pure-ip': true,
        'sniff': {
          'HTTP': {'ports': [80, 8080, 8880]},
          'TLS': {'ports': [443, 8443]},
        },
      },

      // ===== DNS =====
      // 桌面（系统代理/无 TUN）：内核内部解析用于 GEOSITE/GEOIP 规则匹配；
      // 不 listen（避免与本地 53/1053 冲突），不启用 fake-ip。
      // Android(TUN)：enhanced-mode fake-ip，域名路由防泄漏。
      //
      // 注意：不配置 fallback 到 8.8.8.8/1.1.1.1 —— 国内网络直连被墙，
      // 依赖 fallback 的解析会超时（实测会让 ssr 等「本地解析型」链路
      // 的 delay/建连全部失败）；nameserver 用用户主 DNS 列表（默认阿里
      // 223.5.5.5 / 腾讯 119.29.29.29），规则走域名直传。传入 dnsNameservers
      // 时用列表，否则回退单值 dns（旧配置兼容）。
      //
      // DNS 模式（dnsMode）：
      //   auto      默认 —— TUN 用 fake-ip；桌面不写 enhanced-mode
      //             （mihomo 默认 redir-host 传统解析，行为与旧版一致）
      //   fake-ip   全端 fake-ip（域名映射 198.18.x.x，TUN/防泄漏场景推荐）
      //   redir-host 全端传统模式（域名真实解析后直连）
      'dns': {
        'enable': true,
        if (useFakeIp) ...{
          'enhanced-mode': 'fake-ip',
          'fake-ip-range': '198.18.0.1/16',
          'fake-ip-filter': [
            // 本地/内网域名不做 fake-ip
            '*.local',
            'localhost.ptlogin2.qq.com',
            // 用户自定义追加（保持顺序、去空白行）
            ...fakeIpFilterExtra.where((e) => e.trim().isNotEmpty),
          ],
        } else if (dnsMode == 'redir-host')
          'enhanced-mode': 'redir-host',
        'nameserver': nameservers,
      },

      // ===== 规则集（iOS：.mrs，避免 GEOSITE 的 74MB 建索引开销）=====
      if (useMrsRuleSet && geoReady)
        'rule-providers': {
          'cn': {
            'type': 'file',
            'behavior': 'domain',
            'format': 'mrs',
            // 相对路径由内核按 homeDir 解析（扩展启动时把 cn.mrs 放到自己的 homeDir）
            'path': 'cn.mrs',
          },
        },

      // ===== 节点 =====
      'proxies': proxies,

      // ===== 代理组 =====
      // select：智能模式路由终点（规则 MATCH,select）。含 DIRECT 备用。
      'proxy-groups': [
        {
          'name': 'select',
          'type': 'select',
          'proxies': selectMembers,
        },
        // GLOBAL 组由内核内置（全部节点 + DIRECT），无需在 YAML 声明；
        // 全局模式(mode=global)时流量自动走 GLOBAL，切节点用 PUT /proxies/GLOBAL
      ],

      // ===== 规则 =====
      'rules': rules,
    };

    // ===== TUN（仅 Android / 显式开启时）=====
    // Android：file-descriptor 由原生层注入（VpnService fd），路由与地址由
    // VpnService 全量下发 → 必须 auto-route:false（内核不改路由表，非 root 可用）。
    // 桌面：没有人注入 fd、也没有人下发路由，auto-route:false 等于内核完全不接管
    // 路由 → TUN 形同虚设（配 force 模式就是「显示已连接、零流量、零报错」）。
    // 桌面必须让内核自己建接口 + 推路由（需要管理员/root），故 auto-route:true。
    if (isTun) {
      cfg['tun'] = {
        'enable': true,
        'stack': stack,
        'auto-route': tunAutoRoute,
        'auto-detect-interface': true,
        'dns-hijack': ['any:53'],
        // fd 注入场景（iOS 的 socketpair 桥）：关掉 Darwin 专属的 recvmsgx。
        // 见 tunFdInjected 的说明 —— 开着它内核会做 utun 专属 setsockopt 而启动失败。
        if (tunFdInjected) 'recvmsgx': false,
        // MTU 与 PacketTunnel 扩展下发的网络参数（1500）对齐：不写的话内核按默认
        // 9000 生成/重组报文，超过隧道 MTU 的包会被丢弃（大流量场景表现怪异）
        if (tunFdInjected) 'mtu': 1500,
        // 局域网在**路由层**就排除，与下面 bypassLan 的直连规则保持同一语义。
        // 只在规则层直连（旧行为）时，局域网包仍要先被 TUN 抓进去再靠规则绕回，
        // 对 NAS / 网络打印机 / mDNS、SSDP 局域网发现、局域网联机这类场景会变慢
        // 甚至找不到设备。bypassLan=false（用户明确要局域网走代理）时不排除。
        if (bypassLan && tunAutoRoute)
          'route-exclude-address': const [
            '127.0.0.0/8', // 回环（内核 API / 本机服务必须直连可达）
            '10.0.0.0/8',
            '172.16.0.0/12',
            '192.168.0.0/16',
            '169.254.0.0/16', // link-local
            '224.0.0.0/4', // 组播（mDNS/SSDP）
          ],
      };
    }

    return cfg;
  }

  /// 节点列表 → mihomo `proxies` 数组（**生产配置与测速专用内核共用同一份**）。
  ///
  /// 之所以抽成独立方法：测速专用内核（[buildProbe]）必须与真实连接使用
  /// **完全相同的节点序列化**，否则会出现「测速通过但连不上」（或反之）——
  /// 那就又变回了一种更隐蔽的假阳性。
  ///
  /// 返回的 `names` 为**过滤后**（server/port 有效）的 tag 列表，保持原顺序、
  /// 不去重（调用方依赖它与旧行为逐字节一致）；`proxies` 已按 tag 去重
  /// （同名节点 mihomo 会静默覆盖，App 侧依赖 tag 唯一做测速/切换）。
  static ({List<Map<String, dynamic>> proxies, List<String> names})
      buildProxyMaps(List<ProxyNode> nodes,
          {bool udpSkipCertVerify = true}) {
    // 过滤掉面板伪节点（📢官网/⏰到期 等信息节点，server=baidu.com 等）
    final validNodes =
        nodes.where((n) => n.server.isNotEmpty && n.port > 0).toList();
    // 去重（同名节点 mihomo 会静默覆盖，App 侧依赖 tag 唯一做测速/切换）
    final seen = <String>{};
    final proxies = <Map<String, dynamic>>[];
    for (final n in validNodes) {
      if (!seen.add(n.tag)) continue;
      // raw 以订阅解析为准；关键字段缺失（如测试构造/解析遗漏）时用
      // ProxyNode 字段兜底，保证内核能加载
      // （mihomo 对缺必填字段的节点直接报错：missing type / unset fields）
      final m = Map<String, dynamic>.from(n.raw);
      m.putIfAbsent('name', () => n.tag);
      m.putIfAbsent('type', () => n.type);
      m.putIfAbsent('server', () => n.server);
      m.putIfAbsent('port', () => n.port);
      m.putIfAbsent('uuid', () => n.uuid ?? '');
      m.putIfAbsent('password', () => n.password ?? '');
      m.putIfAbsent('cipher', () => n.cipher ?? '');
      final sni = n.sni;
      if (sni != null && sni.isNotEmpty) {
        m.putIfAbsent('servername', () => sni);
      }
      // 开启节点 UDP relay：不写则 mihomo 默认 udp=false，select/GLOBAL 组
      // 转发 UDP 时报「select UDP is not supported」，QUIC/HTTP3、游戏、
      // hysteria2/tuic 等 UDP 流量全部 fallback 到 DIRECT（走本地直连 →
      // 要么泄漏真实 IP、要么直接不通）。订阅节点已显式声明 udp 时尊重原值。
      m.putIfAbsent('udp', () => true);
      // 节点显式声明了 TLS（如 vless+tls），raw 缺失时补上，避免裸连 443
      if (n.tls == true && m['tls'] == null) {
        m['tls'] = true;
      }
      // base64/链接解析出的节点 raw 不是 Clash map 形态：把 network/ws
      // 路径/Host/flow 等转成 mihomo 认识的字段，否则 WS/TLS 节点会被按
      // 裸 TCP 直连处理（流量不通或 SNI 缺失）
      final network = n.network;
      if (network != null && network.isNotEmpty && m['network'] == null) {
        m['network'] = network;
        if (network == 'ws' && n.wsPath != null && n.wsPath!.isNotEmpty) {
          final wsOpts = <String, dynamic>{'path': n.wsPath};
          if (n.host != null && n.host!.isNotEmpty) {
            wsOpts['headers'] = {'Host': n.host};
          }
          m['ws-opts'] = wsOpts;
        }
      }
      if (n.flow != null && n.flow!.isNotEmpty && m['flow'] == null) {
        m['flow'] = n.flow;
      }
      // UDP + TLS 协议（hysteria / hysteria2 / tuic）的证书校验放宽。
      //
      // 实测（mihomo v1.19.30 + 本地内核实测某机场 17 个 hy2 节点）：
      // 链接里写 `insecure=0`（要求校验证书）时 **17/17 全部握手失败**，
      // 同一批节点改成不校验则 16/17 成功。原因是这类节点用「伪装 SNI」
      // （如 sni=api.push.apple.com），服务端证书根本不可能匹配该域名 ——
      // 只要校验就必然失败，而面板导出的链接又几乎都留着 insecure=0。
      // 结果是：节点能解析、能被内核加载，但一测速/一连接就失败，
      // 用户看到的是「这些节点测不了速」。
      //
      // 这里对这三种协议默认放宽（可在设置里关掉）；链接显式要求不校验时
      // 同样成立，节点自己写了 skip-cert-verify 则尊重订阅原值。
      if (udpSkipCertVerify && _udpTlsTypes.contains(n.type)) {
        m.putIfAbsent('skip-cert-verify', () => true);
      }
      proxies.add(m);
    }
    return (
      proxies: proxies,
      names: [for (final n in validNodes) n.tag],
    );
  }

  /// 测速专用内核的最小配置（**不带任何入站监听、不建 TUN、不碰系统代理**）。
  ///
  /// 为什么需要它：内核测速（`/proxies/{name}/delay`）要求有一个**运行中**
  /// 的内核。用户点「测速」时通常还没连接（正在挑节点），于是：
  /// - 桌面端：临时起一个只做延迟探测的内核实例（本方法生成的配置），测完即收；
  /// - 移动端：内核跑在系统隧道进程里，App 起不了第二个实例 → 提示先连接。
  ///
  /// 与生产配置的**有意差异**（每一处都是为了让临时实例与真实连接零冲突）：
  /// - 不写 `mixed-port` / `port` / `socks-port`：没有入站监听，不可能占用
  ///   用户的 2080，也不可能被误当成系统代理目标；
  /// - 没有 `tun` 段：不会创建虚拟网卡、不动路由表（无需管理员权限）；
  /// - `rules: [MATCH,DIRECT]` 且不引用 GEOSITE/GEOIP：无需 geo 数据文件，
  ///   内核绝不会在启动时联网下载 geodata；
  /// - `proxies` 与真实连接完全一致（同一份 [buildProxyMaps]），保证
  ///   「测速通过 ⇔ 真连接可用」。
  /// 内置「必须走代理」域名后缀。
  ///
  /// 覆盖国内网络下**必须**走代理的常见站点，避免智能模式把它们判成直连：
  ///   · AI：ChatGPT / OpenAI、Gemini / Google AI Studio、Claude / Anthropic、
  ///     Copilot、Perplexity、Grok；
  ///   · 社交/内容：LinkedIn、TikTok、X/Twitter、Facebook/Instagram、Reddit、
  ///     Telegram、Discord、YouTube（含 googlevideo CDN，避免部分 CDN 域名走直连）；
  ///   · 流媒体：Netflix、Disney+、Spotify。
  ///
  /// 只放「后缀」，命中即走代理；用户可在设置里追加自己的域名。
  /// 注意：不要放 google.com 这种过宽的后缀 —— 国内可直连的 Google 静态资源
  /// （gstatic 等）走代理反而更慢，宽泛的域名交给规则里的 MATCH 兜底即可。
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

  /// 域名清单规整：去空白、去协议/路径、小写、去重（保持顺序）
  static List<String> _normalizeDomains(Iterable<String> raw) {
    final out = <String>[];
    for (final v in raw) {
      var d = v.trim().toLowerCase();
      if (d.isEmpty) continue;
      if (d.contains('://')) d = d.split('://').last;
      if (d.contains('/')) d = d.split('/').first;
      if (d.startsWith('*.')) d = d.substring(2);
      d = d.replaceAll(RegExp(r'^\\.+'), '');
      if (d.isEmpty || out.contains(d)) continue;
      out.add(d);
    }
    return out;
  }

  static Map<String, dynamic> buildProbe({
    required List<ProxyNode> nodes,
    required int controllerPort,
    String? clashApiSecret,
    String dns = '223.5.5.5',
    List<String> dnsNameservers = const [],
    String logLevel = 'warning',
    bool udpSkipCertVerify = true,
    /// 只测这些 tag（null = 全部）。节点很多时把探测内核缩到最小内存占用。
    Set<String>? onlyTags,
  }) {
    final secret = clashApiSecret ?? generateSecret();
    final pool = onlyTags == null
        ? nodes
        : nodes.where((n) => onlyTags.contains(n.tag)).toList();
    final proxies = buildProxyMaps(pool, udpSkipCertVerify: udpSkipCertVerify).proxies;
    final nameservers =
        dnsNameservers.isNotEmpty ? dnsNameservers : <String>[dns];
    return <String, dynamic>{
      '_clashApiPort': controllerPort,
      '_clashApiSecret': secret,
      'external-controller': '127.0.0.1:$controllerPort',
      'secret': secret,
      'mode': 'rule',
      'log-level': logLevel,
      'ipv6': false,
      'allow-lan': false,
      'find-process-mode': 'off',
      // 与生产同一口径：否则探测内核算出的数字与连接后显示的延迟对不上
      'unified-delay': true,
      'tcp-concurrent': false,
      'geo-auto-update': false,
      // 探测地址是域名时内核要自己解析；不配 fallback（国内直连被墙）
      'dns': {
        'enable': true,
        'nameserver': nameservers,
      },
      'proxies': proxies,
      // 无节点时也给一条可解析的规则，内核照常起来（延迟测试会全部失败，
      // 调用方按失败如实展示）
      'rules': const ['MATCH,DIRECT'],
    };
  }

  /// 端口健壮化：返回合法的 (localPort, clashApiPort)。
  /// - 越界（<1024 / >65535，含 0 与负数）→ 回退该端口默认值
  /// - 两者相等（内核会 bind 冲突）→ clashApiPort 让位到另一个默认端口
  static ({int localPort, int clashApiPort}) _sanitizePorts(
      int localPort, int clashApiPort) {
    int fix(int v, int fallback) => (v >= 1024 && v <= 65535) ? v : fallback;
    final lp = fix(localPort, 2080);
    var ap = fix(clashApiPort, 9090);
    if (ap == lp) ap = lp == 9090 ? 9091 : 9090;
    return (localPort: lp, clashApiPort: ap);
  }

  /// 把一条直连名单条目转换为 DIRECT 规则（0 或 1 条）。
  ///
  /// - `IP-CIDR:` 前缀 → `IP-CIDR,<段>,DIRECT`
  /// - `DOMAIN:` 前缀 → `DOMAIN,<精确域名>,DIRECT`
  /// - 其它（域名后缀，旧格式不变）→ `DOMAIN-SUFFIX,<x>,DIRECT`
  ///
  /// 前缀大小写不敏感（存储/展示统一大写规范形）；值为空时返回空列表
  /// （不产出垃圾规则）。段内多余空白被裁剪。
  static List<String> _bypassRules(String entry) {
    final e = entry.trim();
    if (e.isEmpty) return const [];
    final lower = e.toLowerCase();
    if (lower.startsWith('ip-cidr:')) {
      final cidr = e.substring('IP-CIDR:'.length).trim();
      return cidr.isEmpty ? const [] : ['IP-CIDR,$cidr,DIRECT'];
    }
    if (lower.startsWith('domain:')) {
      final domain = e.substring('DOMAIN:'.length).trim();
      return domain.isEmpty ? const [] : ['DOMAIN,$domain,DIRECT'];
    }
    return ['DOMAIN-SUFFIX,$e,DIRECT'];
  }

  /// 序列化为 YAML 字符串（mihomo 兼容子集）。
  ///
  /// 实现要点：
  /// - Map 顶层键为 `key: value`，嵌套 map/list 逐层缩进；
  /// - proxies/proxy-groups 等对象列表用 flow 风格 `- {k: v}` 紧凑输出；
  /// - 标量按 YAML 规则加引号（含特殊字符 / 数字外观 / 布尔外观等），
  ///   避免节点名里的 `: # , { }` 等破坏结构。
  static String encode(Map<String, dynamic> cfg) {
    final buf = StringBuffer();
    // 过滤 `_` 前缀的 app 元数据键（_localPort/_clashApiPort/_clashApiSecret/
    // _tunMode），防御性兜底：任何调用方直接 encode 都不会把它们写进 YAML
    // （ProxyCore 启动前仍会 remove 并读取这些值）
    final filtered = Map<String, dynamic>.fromEntries(
        cfg.entries.where((e) => !e.key.startsWith('_')));
    _writeYaml(buf, filtered, 0);
    return buf.toString();
  }

  static void _writeYaml(StringBuffer buf, dynamic value, int indent) {
    final prefix = '  ' * indent;
    if (value is Map) {
      for (final e in value.entries) {
        final k = e.key.toString();
        final v = e.value;
        if (v is Map || v is List) {
          buf.writeln('$prefix$k:');
          _writeYaml(buf, v, indent + 1);
        } else {
          buf.writeln('$prefix$k: ${_scalarToYaml(v)}');
        }
      }
    } else if (value is List) {
      for (final item in value) {
        if (item is Map) {
          // 紧凑 flow 风格（proxies 大量节点时体积小、易读）
          buf.writeln('$prefix- ${_flowMap(item)}');
        } else if (item is List) {
          buf.writeln('$prefix-');
          _writeYaml(buf, item, indent + 1);
        } else {
          buf.writeln('$prefix- ${_scalarToYaml(item)}');
        }
      }
    }
  }

  /// 标量值 → YAML（字符串按需加引号，数字/布尔原样）
  static String _scalarToYaml(dynamic v) {
    if (v == null) return 'null';
    if (v is bool) return v ? 'true' : 'false';
    if (v is num) return '$v';
    final s = v.toString();
    if (s.isEmpty) return '""';
    // YAML 特殊起始字符 / 结构字符 / 注释符 / 数字或布尔外观 → 必须引号
    const specialStart = '*&!%@`|>-#?{}[],';
    final looksLikeNumber = num.tryParse(s) != null;
    final looksLikeBool = s == 'true' || s == 'false' || s == 'yes' ||
        s == 'no' || s == 'null' || s == 'on' || s == 'off';
    if (specialStart.contains(s[0]) ||
        s.contains(':') ||
        s.contains('#') ||
        s.contains('"') ||
        s.contains("'") ||
        s.contains('\n') ||
        s.contains('{') ||
        s.contains('}') ||
        s.contains('[') ||
        s.contains(']') ||
        s.contains(',') ||
        s.startsWith(' ') ||
        s.endsWith(' ') ||
        s.endsWith(':') ||
        looksLikeNumber ||
        looksLikeBool) {
      return '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    }
    return s;
  }

  /// Map → flow 风格 {key: val, key: val}（用于 proxies 列表里的节点定义）
  static String _flowMap(Map m) {
    final parts = <String>[];
    for (final e in m.entries) {
      final k = e.key.toString();
      final v = e.value;
      if (v is Map) {
        parts.add('$k: ${_flowMap(v)}');
      } else if (v is List) {
        parts.add('$k: [${v.map(_scalarToYaml).join(', ')}]');
      } else {
        parts.add('$k: ${_scalarToYaml(v)}');
      }
    }
    return '{${parts.join(', ')}}';
  }
}
