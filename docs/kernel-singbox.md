# 内核迁移：mihomo → sing-box

基线 v2.2.33 的内核是 mihomo（Clash.Meta），本分支整体切回 **sing-box 1.14.x**，
功能面对齐（智能/全局分流、TUN、DNS/fake-ip、按应用分流、内核日志、内核管理、
节点测速、热切换），只换了内核与其配置形态。

## 1. 配置形态：Clash YAML → sing-box JSON

| 概念 | mihomo | sing-box |
|---|---|---|
| 配置文件 | `config.yaml` | `config.json` |
| 本地入站 | `mixed-port` | `inbounds[{type:"mixed"}]` |
| TUN | `tun:` 段（`enable/stack/auto-route/dns-hijack`） | `inbounds[{type:"tun"}]`（`address/auto_route/strict_route/stack/mtu`） |
| 节点 | `proxies:`（Clash map 直接可用） | `outbounds:`（逐协议映射，见下） |
| 分组 | `proxy-groups` + 内置 `GLOBAL` | 只有一个 `select` 选择器；全局模式用 `clash_mode:"Global"` 规则实现 |
| 内网分流 | `GEOSITE,cn` / `GEOIP,CN` | `rule_set:["geosite-cn"]` / `["geoip-cn"]`（`.srs`） |
| DNS | `dns.enhanced-mode: fake-ip` + `fake-ip-filter` | `dns.servers[{type:"fakeip"}]` + `dns.rules` |
| 嗅探 | `sniffer:` | `route.rules[{action:"sniff"}]` |
| DNS 劫持 | `tun.dns-hijack` | `route.rules[{protocol:"dns",action:"hijack-dns"}]` |
| 控制面 | Clash API（`external-controller`） | Clash API（`experimental.clash_api`），端口/密钥/语义一致 |

协议映射（`SingBoxConfigBuilder._toOutbound`）：`ss→shadowsocks`、`ssr→shadowsocksr`、
`vmess`、`vless`（含 `flow`/`reality`/`utls`）、`trojan`、`hysteria2`、`tuic`、`anytls`、
`socks`、`http`、`wireguard`；传输层支持 `ws`（含 `max-early-data`）、`grpc`、`http/h2`。

**不支持**：`hysteria` v1（sing-box 只有 hysteria2）、`mieru`、`snell`、`juicity`。
这类节点在生成配置时被跳过（不会导致内核启动失败），`select` 组里也不出现。

## 2. 控制面：Clash API 兼容性（已实测）

| 端点 | sing-box 1.14.4 实测 |
|---|---|
| `GET /version` | 200（`{"version":"sing-box 1.14.4"}`）→ 就绪探测与内核版本显示 |
| `GET /configs` | 200（`mode` 字段可读） |
| `PATCH /configs {"mode":"Global"}` | 204，`Rule` ↔ `Global` 热切换不断网 |
| `PUT /proxies/select {"name":...}` | 204，节点热切换（两种模式共用同一选择器） |
| `GET /proxies/{tag}/delay` | 可用（节点真连接测速） |
| `GET /traffic` | 流式，实时速率 |

因此 Dart 侧控制面（`proxy_core.dart`）基本零改动，只把「模式值大小写」改成
`Rule`/`Global`、切节点固定打 `select`。

## 3. 分流数据

- 旧的 `geosite.dat` + `country.mmdb` + iOS 专用 `cn.mrs` 全部弃用
- 新的 `assets/rules/geosite-cn.srs` + `geoip-cn.srs`（SagerNet 官方 rule-set 分支）
- `GeoAssets` / `GeoUpdateService` 只改了文件名与下载源；落盘策略、原子替换、
  手动更新优先级、缺失时降级全代理的逻辑不变
- 桌面以**绝对路径**引用规则集；iOS 传空目录 → 用相对文件名（由扩展的工作目录解析）

## 4. 三端内核来源

| 平台 | 产物 | 获取方式 |
|---|---|---|
| macOS | `MoneyFly.app/Contents/MacOS/sing-box` | `SagerNet/sing-box` 官方 `darwin-arm64/amd64` tar.gz |
| Windows | `<安装目录>/sing-box.exe` | 官方 `windows-amd64` zip |
| Android | `android/app/libs/libmoneyfly.aar` | `moneyfly004/sing-box-lib` release（`libmoneyfly-1.14.0.aar`，Java 包 `top.moneyfly.libbox`）；`FORCE_BUILD=1` 可用 gomobile 从官方源码重编 |
| iOS | `ios/Libbox.xcframework` | `tool/fetch_singbox_ios.sh`（gomobile bind `./experimental/libbox`，Go 1.24+ 需先 `go get -tool golang.org/x/mobile/cmd/gobind`） |

内核管理页（`kernel_page.dart`）行为不变：显示当前版本、检查官方最新版、
下载缓存、激活（带备份回滚）、恢复内置。差异：
- 版本命令 `sing-box version`，GitHub 源换成 `SagerNet/sing-box`
- 官方只有一套构建 → 取消「标准版/兼容版」变体开关（`supportsVariant` 恒 false）
- 下载包是 `tar.gz`/`zip`，解压后定位 `sing-box(.exe)`

## 5. 平台侧差异

**Android（`MoneyFlyVpnService.kt`）**
- `VpnService.establish()` 的 fd 不再主动注入，而是内核通过
  `PlatformInterface.openTun(options)` 回问，我们按 `TunOptions`
  （地址/路由/MTU/DNS）构建后把 fd 交回
- 按应用分流：设置翻译成 `OverrideOptions.includePackage/excludePackage`，
  并在 `openTun` 里用 `addAllowedApplication/addDisallowedApplication` 落地；
  系统拒绝时降级为「只排除自身」并写 `lastStartWarning`
- 内核日志：`LibboxNewCommandClient` + `CommandLog` 采集到环形缓冲，
  `fetchKernelLogs()` 增量返回
- 启动失败分类（跨用户 / VPN 未授权 / 应用缺失）保持不变

**iOS（`PacketTunnel` 扩展）**
- 内核换 libbox：`LibboxSetup` → `LibboxNewCommandServer` →
  `startOrReloadService(config)`；停止走 `closeService/close`
- TUN 仍是「socketpair 用户态桥 + `stack: gvisor`」（iOS 16.4+ 拿不到 utun fd）
- 防自环：配置里写 `route.auto_detect_interface=false` +
  `route.default_interface=<物理网卡>`（替代 mihomo 的 `interface-name`）
- 规则集随 appex bundle 分发，扩展启动时复制进自己的工作目录
- ⚠️ **需要真机验证**：这套 fd 桥在 mihomo 上已验证可用，sing-box 侧
  依赖 sing-tun 的 gvisor 栈处理非 utun fd；若真机起不来，先看
  `TunnelDiag` 轨迹里 `openTun` / `startOrReloadService` 的返回

## 6. 测试

- `test/gen_singbox_test.dart`：配置生成（协议映射、模式、TUN、DNS、规则顺序、
  规则集路径）+ 真实内核 `sing-box check`
- `test/tun_config_test.dart`：TUN 段与局域网路由排除、fd 注入的 MTU、规则集缺失降级
- 其余用例（分流语义、订阅解析、内核层集成）按 sing-box 结构断言
- CI 里会下载真实的 `sing-box`（linux/darwin/windows）跑 `check` 与 Clash API 行为验证
