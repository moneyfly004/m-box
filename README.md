# MBox

基于 **sing-box** 内核的全平台代理客户端：macOS / Windows / Android / iOS，
一套 Dart 代码 + 三端各自的 sing-box 接入方式。

- 内核：**sing-box 1.14.4**（Android 内核库 1.14.4，见下）
  - 桌面（macOS / Windows）：官方 `SagerNet/sing-box` 预编译二进制，随安装包内置，
    可在「设置 → 内核管理」里检测更新 / 热替换 / 回滚
  - Android：`android/app/libs/libmbox.aar`（sing-box 官方核心经 gomobile bind，
    Java 包名 `top.moneyfly.libbox`，来自 `moneyfly004/sing-box-lib` 的 release）
  - iOS：`Libbox.xcframework`（gomobile 静态框架），链进 `PacketTunnel` 扩展
- 分流：sing-box **binary rule-set（`.srs`）**，`geosite-cn.srs` + `geoip-cn.srs`，
  随包内置、设置页可更新
- 控制面：全部走内核自带 **Clash API**（`127.0.0.1:9090`）：模式热切换
  （`Rule`/`Global`）、节点热切换（`select` 选择器）、实时流量、节点延迟测试
- 应用标识：`top.mbox.app`（Android `applicationId` / macOS bundle id /
  iOS bundle id 与扩展 `top.mbox.app.tunnel` / App Group `group.top.mbox.app`）

> 只有三处「历史名字」是有意保留的：内核 AAR 的 Java 包名 `top.moneyfly.libbox`
> （在预编译产物里写死，改了就用不了官方预编译库）、GitHub 仓库路径
> `moneyfly004/sing-box-lib` 与 `moneyfly004/m-box`，以及后端面板下发的下载配置
> 字段名（仍是 `moneyfly_*`；App 先查 `mbox_*`，查不到再回退旧字段名）。

## 构建

```bash
flutter pub get

# 1) 分流规则集（assets/rules/*.srs，仓库不入库）
bash tool/fetch_ruleset.sh

# 2) 桌面内核（macOS 开发机）
bash tool/fetch_singbox.sh 1.14.4      # 放进 app bundle / build/singbox

# 3) Android 内核 AAR（下载的是 libmoneyfly-<ver>.aar，落盘为 libmbox.aar）
bash tool/build_singbox_aar.sh 1.14.4  # FORCE_BUILD=1 可本地 gomobile 编译

# 4) iOS 内核框架（约 100MB，仓库不入库）
bash tool/fetch_singbox_ios.sh 1.14.4
ruby tool/ios_setup_tunnel_target.rb   # 重建 PacketTunnel target（幂等）

flutter build macos --release
flutter build windows --release
flutter build apk --release --split-per-abi
flutter build ios --release
```

图标与 App 内 logo 出自同一份画稿（白底 + 品牌色标记）：

```bash
python3 tool/gen_brand_assets.py        # 画稿 → design/mbox-logo.png
python3 tool/gen_app_icons_white.py     # 画稿 → 各平台图标 + assets/mbox-logo.png + 托盘
```

## 关键目录

| 文件 | 作用 |
|---|---|
| `lib/core/proxy/singbox_config.dart` | 配置生成器（Clash 风格节点 → sing-box JSON），含协议映射、TUN、DNS/fake-ip、规则与规则集、Clash API |
| `lib/core/proxy/proxy_core_cli.dart` | 桌面：`sing-box run -c config.json -D <workDir>` 子进程 + Clash API 控制面 |
| `lib/core/proxy/proxy_core_embedded.dart` | Android/iOS：MethodChannel → 原生 libbox |
| `lib/core/services/kernel_manager.dart` | 内核版本检测 / 官方更新 / 热替换 / 回滚 |
| `lib/core/proxy/geo_assets.dart` + `geo_update_service.dart` | `.srs` 规则集落盘与手动更新 |
| `android/.../vpn/MBoxVpnService.kt` | Android `VpnService` + libbox（`PlatformInterface` / `CommandServer`） |
| `ios/PacketTunnel/LibboxEngine.swift` | iOS 内核启动（6 段式：Setup → CommandServer → Start → API 自查 → 日志通道）+ 平台接口 |
| `tool/fetch_singbox.sh` / `build_singbox_aar.sh` / `fetch_singbox_ios.sh` / `fetch_ruleset.sh` | 内核与规则集获取 |

内核接入细节见 [`docs/kernel-singbox.md`](docs/kernel-singbox.md)。
