# m-box

MoneyFly 系列的新分支：**内核从 mihomo(Clash.Meta) 全量切换回 sing-box**，其余功能与 2.2.33 保持一致。

- 代码基线：`moneyfly` v2.2.33（`26cb24b chore(release): v2.2.33`）
- 内核：**sing-box 1.14.x**
  - 桌面（macOS / Windows）：官方 `SagerNet/sing-box` 预编译二进制，随安装包内置，可在「设置 → 内核管理」里检测更新 / 热替换 / 回滚
  - Android：`libmoneyfly.aar`（sing-box 官方核心经 gomobile bind，Java 包名 `top.moneyfly.libbox`），来自 `moneyfly004/sing-box-lib` 的 release
  - iOS：`Libbox.xcframework`（gomobile 静态框架），链进 `PacketTunnel` 扩展
- 分流：sing-box **binary rule-set（`.srs`）**，`geosite-cn.srs` + `geoip-cn.srs`，随包内置、设置页可更新
- 控制面：仍然全部走内核自带 **Clash API**（`127.0.0.1:9090`）：模式热切换（`Rule`/`Global`）、节点热切换（`select` 选择器）、实时流量、节点延迟测试

> 应用标识（bundle id / package name / 可执行名）沿用 `top.moneyfly.app` 与 `MoneyFly`，以便与已发布版本的数据、签名、CI 路径兼容；仓库与产品线名称为 **m-box**。

## 构建

```bash
flutter pub get

# 1) 分流规则集（assets/rules/*.srs，仓库不入库）
bash tool/fetch_ruleset.sh

# 2) 桌面内核（macOS 开发机）
bash tool/fetch_singbox.sh 1.14.4      # 放进 app bundle / build/singbox

# 3) Android 内核 AAR
bash tool/build_singbox_aar.sh 1.14.0  # 下载预编译；FORCE_BUILD=1 可本地 gomobile 编译

# 4) iOS 内核框架（约 100MB，仓库不入库）
bash tool/fetch_singbox_ios.sh 1.14.4
ruby tool/ios_setup_tunnel_target.rb   # 重建 PacketTunnel target（幂等）

flutter build macos --release
flutter build windows --release
flutter build apk --release
flutter build ios --release
```

## 内核相关目录

| 文件 | 作用 |
|---|---|
| `lib/core/proxy/singbox_config.dart` | 配置生成器（Clash map → sing-box JSON），含协议映射、TUN、DNS/fake-ip、规则与规则集、Clash API |
| `lib/core/proxy/proxy_core_cli.dart` | 桌面：`sing-box run -c config.json -D <workDir>` 子进程 + Clash API 控制面 |
| `lib/core/proxy/proxy_core_embedded.dart` | Android/iOS：MethodChannel → 原生 libbox |
| `lib/core/services/kernel_manager.dart` | 内核版本检测 / 官方更新 / 热替换 / 回滚 |
| `lib/core/proxy/geo_assets.dart` + `geo_update_service.dart` | `.srs` 规则集落盘与手动更新 |
| `android/.../vpn/MoneyFlyVpnService.kt` | Android `VpnService` + libbox（`PlatformInterface` / `CommandServer`） |
| `ios/PacketTunnel/LibboxEngine.swift` | iOS `PlatformInterface` + `CommandServer` + 日志订阅 |
| `tool/fetch_singbox.sh` / `build_singbox_aar.sh` / `fetch_singbox_ios.sh` / `fetch_ruleset.sh` | 内核与规则集获取 |

详细迁移说明见 [`docs/kernel-singbox.md`](docs/kernel-singbox.md)。
