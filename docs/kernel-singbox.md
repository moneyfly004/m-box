# sing-box 内核接入说明

MBox 的内核是 **sing-box 1.14.x**（桌面端二进制 + Android AAR + iOS gomobile 框架），
功能面（智能/全局分流、TUN、DNS fake-ip、按应用分流、内核日志、内核管理、节点测速、
热切换）都建在它自己的配置形态与 Clash API 之上。

## 1. 配置形态

配置文件是 sing-box 的 JSON（`config.json`），由 `SingBoxConfigBuilder` 从「Clash 风格
的节点数据」生成：

| 概念 | sing-box 形态 |
|---|---|
| 本地入站 | `inbounds[{type:"mixed"}]` |
| TUN | `inbounds[{type:"tun"}]`（`address/auto_route/strict_route/stack/mtu`） |
| 节点 | `outbounds:`（逐协议映射，见下） |
| 分组 | 只有一个 `select` 选择器；全局模式用 `clash_mode:"Global"` 规则实现 |
| 内网分流 | `rule_set:["geosite-cn"]` / `["geoip-cn"]`（`.srs`） |
| DNS | `dns.servers[{type:"fakeip"}]` + `dns.rules` |
| 嗅探 | `route.rules[{action:"sniff"}]` |
| DNS 劫持 | `route.rules[{protocol:"dns",action:"hijack-dns"}]` |
| 控制面 | Clash API（`experimental.clash_api`） |

协议映射（`SingBoxConfigBuilder._toOutbound`）：`ss→shadowsocks`、`vmess`、
`vless`（含 `flow`/`reality`/`utls`）、`trojan`、`hysteria2`、`tuic`、`anytls`、
`socks`、`http`、`wireguard`；传输层支持 `ws`（含 `max-early-data`）、`grpc`、`http/h2`。

**不支持**（sing-box 没有对应协议，或只在 alpha 分支里）：`hysteria` v1、`ssr`、
`mieru`、`snell`、`juicity`、`ssh`。这类节点在生成配置时被跳过（否则整份配置会被
内核判 FATAL、连能用的节点一起起不来），`select` 组里也不会出现。

## 2. 控制面：Clash API（已实测）

| 端点 | sing-box 1.14.4 实测 |
|---|---|
| `GET /version` | 200（`{"version":"sing-box 1.14.4"}`）→ 就绪探测与内核版本显示 |
| `GET /configs` | 200（`mode` 字段可读） |
| `PATCH /configs {"mode":"Global"}` | 204，`Rule` ↔ `Global` 热切换不断网 |
| `PUT /proxies/select {"name":...}` | 204，节点热切换（两种模式共用同一选择器） |
| `GET /proxies/{tag}/delay` | 可用（节点真连接测速） |
| `GET /traffic` | 流式，实时速率 |

Dart 侧控制面（`proxy_core.dart`）因此只做两件事：模式值用 `Rule`/`Global`、
切节点固定打 `select`。

## 3. 分流数据

- `assets/rules/geosite-cn.srs` + `geoip-cn.srs`（SagerNet 官方 rule-set 分支，
  `tool/fetch_ruleset.sh` 下载；仓库不入库，CI 构建前拉取）
- `GeoAssets` / `GeoUpdateService`：原子替换、手动更新优先、缺失时降级全代理
- 桌面以**绝对路径**引用规则集；iOS 传空目录 → 用相对文件名（由扩展的工作目录解析）

## 4. 三端内核来源

| 平台 | 产物 | 获取方式 |
|---|---|---|
| macOS | `MBox.app/Contents/MacOS/sing-box` | `SagerNet/sing-box` 官方 `darwin-arm64/amd64` tar.gz（1.14.4） |
| Windows | `<安装目录>/sing-box.exe` | 官方 `windows-amd64` zip（1.14.4） |
| Android | `android/app/libs/libmbox.aar` | `moneyfly004/sing-box-lib` release 的 `libmoneyfly-1.14.4.aar`（Java 包 `top.moneyfly.libbox`，AAR 内 native 库叫 `libmoneyfly.so`）；`FORCE_BUILD=1` 可用 gomobile 从官方源码重编任意版本 |
| iOS | `ios/Libbox.xcframework` | `tool/fetch_singbox_ios.sh`（gomobile bind `./experimental/libbox`，Go 1.24+ 需先 `go get -tool golang.org/x/mobile/cmd/gobind`） |

内核管理页（`kernel_page.dart`）：显示当前版本、检查官方最新版、下载缓存、
激活（带备份回滚）、恢复内置。版本命令 `sing-box version`，下载源 `SagerNet/sing-box`，
官方只有一套构建 → 没有「标准版/兼容版」变体（`supportsVariant` 恒 false）。

## 5. 平台侧差异

**Android（`MBoxVpnService.kt`）**
- `VpnService.establish()` 不主动注入 fd：内核通过 `PlatformInterface.openTun(options)`
  回问，我们按 `TunOptions`（地址/路由/MTU/DNS）构建后把 fd 交回
- 按应用分流：设置翻译成 `OverrideOptions.includePackage/excludePackage`，
  并在 `openTun` 里用 `addAllowedApplication/addDisallowedApplication` 落地；
  系统拒绝时降级为「只排除自身」并写 `lastStartWarning`
- 内核日志：内核 `log.output` 写 `singbox.log`，`fetchKernelLogs()` 增量读取
  （走 `CommandClient` 的日志通道在 1.14 上会返回 `invalid argument`，已弃用）
- 启动失败分类（跨用户 / VPN 未授权 / 应用缺失）保持不变

**iOS（`PacketTunnel` 扩展）**
- 内核走 libbox，启动顺序固定为 6 段（每段都有日志，失败即止损）：
  1. `LibboxSetup`（`basePath` 取扩展容器根；命令服务优先 **TCP 127.0.0.1 随机端口**，
     失败才退回 unix socket —— unix 路径受 Darwin `sun_path` 104B 限制）
  2. `NewCommandServer`
  3. `server.start()`（命令服务监听）
  4. `startOrReloadService(config)`（**先起服务再连日志客户端**：反了会得到
     `get default log level: rpc error ... invalid argument`）
  5. 扩展内自查 `127.0.0.1:<apiPort>/version`（拿到任何 HTTP 响应即核心已起）
  6. 连 `CommandClient` 取日志；放行 TUN 数据后打一次真实 HTTPS 自测
     （验证「TUN + 路由 + 出站」整条链路在转发）
- TUN 是「socketpair 用户态桥 + `stack: gvisor`」（iOS 16.4+ 拿不到 utun fd）
- 防自环：`route.auto_detect_interface=false` + `route.default_interface=<物理网卡>`
- 规则集随 appex bundle 分发，扩展启动时复制进自己的工作目录
- ⚠️ **需要真机验证**：这套 fd 桥依赖 sing-tun 的 gvisor 栈处理非 utun fd；
  若真机起不来，先看 `TunnelDiag` 轨迹里 `openTun` / `startOrReloadService` 的返回

## 6. 测试

- `test/gen_singbox_test.dart`：配置生成（协议映射、模式、TUN、DNS、规则顺序、
  规则集路径）+ 真实内核 `sing-box check`
- `test/tun_config_test.dart`：TUN 段与局域网路由排除、fd 注入的 MTU、规则集缺失降级
- `test/kernel_speed_test_lab_test.dart`：起真实 sing-box（mixed 入站 + 用户名口令）
  做「TCP 测速假阳性 vs 内核测速如实失败」的对照实验
- CI 会下载真实的 `sing-box`（linux/darwin/windows）跑 `check` 与 Clash API 行为验证
