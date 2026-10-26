# 分应用代理（按 App 分流）设计方案

> 目标读者：后续实现者（人或 AI）。本文是**设计**，不是实现说明；标了 ✅ 的是现状，
> 标了 ❗ 的是缺口，标了 🔧 的是本文给出的改法。

## 0. 一句话结论

Android 上的分应用代理**已经有了**（设置 → 代理与分流 → 应用代理，三种模式 + 应用列表 +
搜索 + 重连生效），并且实测**真的生效**。但它是一个「最小可用」实现：没有图标、
只能列出有桌面图标的 App、已选应用不置顶、系统应用无法折叠、改完不知道有没有生效、
卸载过的包会让整份过滤规则只应用一半。本文给出把它补成「和主流客户端一个水平」的设计。

---

## 1. 现状（实测，2026-09-20，vivo V2072A / Android 13）

### 1.1 已经能跑通的链路

| 环节 | 实现位置 | 实测结果 |
|---|---|---|
| 设置项 | `lib/core/services/settings_store.dart`：`accessControlMode`（all/selected/denied）、`accessControlApps`（package 数组） | ✅ 默认 `all` |
| UI | `lib/pages/settings/access_page.dart`（393 行） | ✅ 三种模式、搜索、已选计数、模式说明、读取失败可重试 |
| 入口 | `settings_page.dart`：`📱 应用代理`（仅 Android 显示），值显示当前模式 | ✅ |
| 应用列表 | `MainActivity.kt#getInstalledApps()`：`queryIntentActivities(ACTION_MAIN + CATEGORY_LAUNCHER)`，返回 `{package,label}` 按 label 排序 | ✅ 只含「有桌面图标」的 App |
| 生效 | `MBoxVpnService.kt#applyAccessControl()`：`addAllowedApplication` / `addDisallowedApplication`；**始终排除自身** | ✅ |

### 1.2 本机实测证据（同一台手机、同一版 App 2.2.11）

- **`排除以下应用` + 1 个包**：内核日志满是各 App 进隧道的记录（`[TCP] 172.19.0.1:… using DIRECT`、
  `[DNS] hijack udp:172.19.0.2:53 from 172.19.0.1`）。
- **`仅以下应用走代理` + 只勾一个空闲 App**：`/proc/net/dev` 里 `tun0` 连续 10 秒 **RX/TX 增量 = 0 字节**。
- 结论：过滤是**操作系统级真实生效**的（VpnService 的 allowed/disallowed），不是 UI 摆设。

### 1.3 缺口（这就是「感觉缺了分应用代理」的来源）

| # | 缺口 | 影响 | 证据/位置 |
|---|---|---|---|
| G1 | ❗ **没有任何图标** | 100+ 个 App 只有名字，扫起来极慢；主流客户端都有图标 | `access_page.dart#_listArea` 只有 `Text(label)` + `Text(pkg)` |
| G2 | ❗ **只列出有桌面图标的 App** | 想代理/排除某些系统组件、无图标 App 时**根本选不到** | `getInstalledApps()` 用 LAUNCHER 查询 |
| G3 | ❗ **已选应用不置顶** | 已选 5 个散落在几百行里，改配置要翻半天 | 列表只按 label 排序 |
| G4 | ❗ **无法折叠系统应用** | vivo 机器上系统应用占绝大多数，有效信息被淹没 | 无过滤开关 |
| G5 | ❗ **自身出现在列表里** | 勾了也不生效（Kotlin 侧强制排除），用户会以为坏了 | `MBox ｜ top.mbox.app` 实测在列表第 3 项 |
| G6 | ❗ **卸载过的包会让规则只应用一半，`denied` 模式下还会漏掉「排除自身」** | `forEach { addAllowedApplication/addDisallowedApplication }` 抛 `NameNotFoundException` 后被外层 `catch` 吞掉，**循环中断**：前面的包加进去了、后面的没加。更严重的是 `denied` 分支里 `addDisallowedApplication(packageName)`（排除自身）写在循环**之后** → 异常时它同样被跳过 → **本进程流量进入隧道 → 自代理循环（连上也打不开网页）**，正是该函数注释里警告的那个后果。证据等级：**读代码得出**，未在真机复现（复现需要卸载一个已勾选的应用，会动到你的数据） | `MBoxVpnService.kt#applyAccessControl`：try/catch 包住整个 `when`，自身排除在循环之后 |
| G7 | ❗ **改完不知道有没有生效** | 保存即写盘，但要重连才生效；界面上只有一句「更改已保存 · 重连或下次连接后生效」，连接中也没有主动提示，用户改完就走 → 以为没生效 | `access_page.dart` 顶部提示 + AppBar 的「重连生效」按钮 |
| G8 | ❗ **没有批量操作/预设** | 「把银行类 App 都排除」只能一个个点 | 无全选/反选/预设 |
| G9 | ❗ **没有已卸载包的清理入口** | 存了但已卸载的 package 永远留在 `accessControlApps` 里（计数虚高、触发 G6） | 无 UI |
| G10 | ❗ 桌面端（macOS/Windows）**完全没有**分应用能力 | 用户在桌面端找不到这个功能，会以为功能缺失 | 该页仅 Android 显示；桌面需要 WFP / NetworkExtension 过滤，属于另一个量级的工作 |
| G11 | ❗ 无「按 App 指定线路/节点」能力 | 高级用户想「微信走香港、浏览器走美国」做不到 | 见 §5.2 的架构说明 |

---

## 2. 实测基线（做设计前先量过的事实）

| 项 | 数值 | 来源 |
|---|---|---|
| 应用列表返回项数（launcher 查询） | 本机 ~60 个（列表可见 8 行/屏，需滚动） | UI dump |
| 单次 `getInstalledApps` 耗时 | 未测（预期 <100ms） | — |
| 模式切换生效时延 | 需重连，实测重连 ≈6s（含测速） | App 运行日志 21:12:31→21:12:32 |
| `tun0` 过滤效果 | selected(空闲 App) → 10s 0 字节；denied → 每秒多条隧道日志 | `/proc/net/dev`、内核日志 |

---

## 3. 设计目标与非目标

**目标**
1. 让「选 App」这件事在 200+ 应用规模下也能 10 秒内完成：图标 + 搜索 + 已选置顶 + 系统应用折叠。
2. 让「是否已生效」永远可见：状态徽标 + 一键生效，不用用户猜。
3. 让过滤结果与 UI 永远一致：写进 VpnService 之前先过滤无效包，并把**实际生效**的清单回报给 UI。
4. 保持零权限门槛的默认体验（不因为要列全量应用而强制额外权限）。

**非目标（本期不做，写清原因）**
- 桌面端（macOS/Windows）的分应用：需要 WFP 过滤器 / NetworkExtension，工作量和风险都是另一个量级（见 §5.4）。
- 按 App 指定代理节点的完整路由（见 §5.2 的可行性与代价）。
- 分应用 + 分流规则的组合策略编排（本期只做 include/exclude 二分）。

---

## 4. 数据模型

```jsonc
// settings_store.dart（沿用现有 key，新增 3 个，全部有默认值 → 老用户无感升级）
{
  "accessControlMode": "all",        // all | selected | denied   （已有）
  "accessControlApps": ["pkg.a"],    // package 数组             （已有）
  "accessControlShowAll": false,     // 新增：是否列出系统/无图标应用
  "accessControlHideIcons": false,   // 新增：低端机可关图标（省内存）
  "accessControlAutoApply": false,   // 新增：改动后自动重连生效（默认关，见 §6.3）
  "accessControlKnown": {            // 新增：package → {label, versionCode}
    "pkg.a": {"label": "微信", "versionCode": 1234}
  }
}
```

- `accessControlKnown` 的用途：① 已卸载的包仍能显示中文名（而不是裸包名）；② 图标缓存键；
  ③ 让 UI 明确标出「已卸载」并给一键清理。
- 不引入「policy 枚举」的复杂模型：本期仍是 include/exclude 二分（`mode` 决定方向）。

---

## 5. 关键设计决策

### 5.1 应用枚举：默认零权限，全量列表要显式开启

Android 11+ 的包可见性限制决定了：**要列全量应用必须声明 `QUERY_ALL_PACKAGES`**（或用
`<queries>` 白名单）。所以：

- **默认**（`accessControlShowAll=false`）：继续用 `queryIntentActivities(LAUNCHER)`，
  零权限、列表干净，覆盖 95% 的使用场景。
- **开启**（`accessControlShowAll=true`）：Manifest 里加 `QUERY_ALL_PACKAGES`，改用
  `packageManager.getInstalledApplications(MATCH_UNINSTALLED_PACKAGES)`，并默认
  **把系统应用折叠成一组**（`applicationInfo.flags & FLAG_SYSTEM`）。
- ⚠️ **上架 Google Play 的注意**：`QUERY_ALL_PACKAGES` 需要在 Play 控制台填写用途声明；
  VPN 类应用的「分应用代理（split tunneling）」是官方认可的合规用途之一，但必须如实申报。
  当前分发方式是 GitHub Release + APK，不受此限。

### 5.2 「按 App 指定线路/节点」为什么本期不做

用户直觉是「微信走香港、浏览器走美国」。我们的架构里：

```
App → VpnService(TUN) → 内核(sing-box) → 规则匹配 → 出站
```

- VpnService 只能做**「这个 App 进不进隧道」**这一件事，做不到「进隧道后走哪个出口」；
- 进了隧道的 App 共享同一条 tun，内核只能按 **IP/域名/进程** 分流。理论上可用
  `PROCESS-NAME,<包名>,<策略组>` 规则做「按 App 定线路」，但：
  - 需要内核能拿到 socket→UID→包名 的反查（Android 上依赖 `/proc/net` 抓取，UDP 常常匹配不到）；
  - 一旦匹配失败，流量会落到默认策略（可能是直连）→ **静默泄漏**，比做不到更糟；
  - 需要真机大规模验证（不同 Android 版本 / vivo 这类魔改 ROM 的 `/proc` 可见性不同）。
- **结论**：先不做；如果要做，必须先在真机上验证 `PROCESS-NAME` 命中率与失败兜底，
  并且只作为「高级选项」提供，默认关闭。

### 5.3 图标：按需加载 + 可关 + 落盘缓存

- 通道：`getAppIcon(package)` → 返回 `Uint8List`（PNG，48dp：`Drawable` → `Bitmap` →
  `compress(PNG)`）。**不要**一次性返回整表图标（60~200 个图标走 MethodChannel 会卡首屏）。
- Dart 侧：`_iconCache: Map<String, Uint8List>`（LRU，上限 200 项）+ 磁盘缓存
  （`<cacheDir>/appicons/<pkg>-<versionCode>.png`，卸载/升级自动失效）。
- 兜底：拿不到图标时画一个「首字母圆形占位」（不要留空白，否则列表会跳）。
- 低端机：`accessControlHideIcons=true` 时整列不请求图标，行高更紧凑。

### 5.4 桌面端：明确「不支持」而不是假装支持

- 现状：`应用代理` 行仅 Android 显示 ✓（这是对的）。
- 增强：在 macOS/Windows 的设置页加一行**只读说明**：「分应用代理仅 Android 支持；
  桌面端可改用『直连名单』按域名分流」。避免用户以为功能缺失。
- 真要做的两种路线（备查，不在本期）：
  - Windows：`WFP` 过滤器（按 UID/进程）或 `WinDivert`，需要签名驱动/管理员权限；
  - macOS：`NEFilterDataProvider`（系统扩展，需要开发者证书 + 用户授权）。

---

## 6. 交互与界面设计

### 6.1 页面结构（自上而下）

```
┌ AppBar：应用代理                        [已生效 ✓ / 待重连 ⟳ 一键生效]
├ 说明一行（跟随模式变化）
├ 三态分段：全部走代理 | 仅以下应用走代理 | 排除以下应用
├ 状态条：已选 3 个 · ✅ 已生效  ← 新增：真实生效状态（不再是固定文案）
├ 搜索框
├ 快捷操作条（新增）：[已选置顶] [全选] [清空] [仅系统应用]
├ 应用列表
│   ├ 分组标题「已选 (3)」            ← 新增：已选置顶
│   ├ [图标] 名称    包名           [✓]
│   └ 分组标题「全部应用 (57)」→「系统应用 (23)」可折叠  ← 新增
└ 底部（可选）：已卸载 (2) → 一键清理   ← 新增
```

### 6.2 一行应用的视觉

| 元素 | 规格 |
|---|---|
| 图标 | 36×36，圆角 9；缺图标 → 品牌色首字母圆形 |
| 名称 | 13.5，`MBColors.txt`，单行省略 |
| 包名 | 9.5，`MBColors.txt3`，单行省略（保留：排障时有用） |
| 勾选框 | 用 `MBChip`/`CheckboxListTile`，**整行可点**（命中区 ≥48） |
| 已卸载标记 | 名称后追一个灰色「已卸载」小标签 |
| 系统应用标记 | 折叠分组内不额外标记（分组标题已说明） |

### 6.3 生效策略（G7 的解法）

1. **状态条如实反映**：`待重连`（有未生效改动）/ `已生效`（VpnService 回报的清单与设置一致）/ `未连接`。
   - 实现：新增通道 `getAppliedAccessControl()` → VpnService 把**上次真正写进 Builder** 的
     `(mode, packages)` 缓存下来并回报；Dart 侧与设置比对即可判定，**不猜**。
2. **一键生效**：状态条右侧的按钮 → 断连 + 重连（复用现有 `_reconnect()`），并把
   「重连会换 IP、会短暂断网」写在确认弹窗里。
3. **自动生效（可选，默认关）**：`accessControlAutoApply=true` 时，改动后 1.5s 防抖自动重连。
   默认关的理由：重连会换出口 IP（对正在下载/登录的用户是破坏性的），必须用户显式选择。

### 6.4 默认预设（G8 的解法）

内置两个一键预设（只改 `selected`/`denied` 的选择集，不猜包名）：
- 「排除支付/银行类」：按 label 关键词（银行/支付/支付宝/微信支付/UnionPay/Alipay…）+ 已知包名列表匹配，
  **弹确认框列出将被排除的 App**，用户确认后才写。
- 「只代理浏览器/流媒体」：同理。

> 设计原则：预设必须**展示它将选中的清单**再执行，绝不静默改配置。

---

## 7. Kotlin 侧改造清单

| # | 改动 | 说明 |
|---|---|---|
| K1 | `getInstalledApps(includeAll: Boolean)` | `includeAll=false` 走 LAUNCHER 查询（现状）；`true` 走 `getInstalledApplications(MATCH_UNINSTALLED_PACKAGES)` 并带上 `isSystem` 标记 |
| K2 | `getAppIcon(package): ByteArray?` | PNG 48dp；异常返回 null（Dart 侧画占位） |
| K3 | `getAppliedAccessControl(): Map` | 返回 `{mode, packages[]}`（上次真正应用的），供 UI 判定「已生效」 |
| K4 | **`applyAccessControl` 先过滤再添加**（修 G6） | 先把 `apps` 里不存在的包剔除（`getPackageInfo(pkg, 0)` 逐个校验），再 `forEach`；单个包异常**不中断**其余包。缓存 `applied` 供 K3 回报 |
| K5 | **自身从列表剔除**（修 G5） | `getInstalledApps` 里 `filter { it.package != packageName }`（Kotlin 侧过滤，Dart 侧不用管） |
| K6 | 允许「系统应用」出现在列表 | `isSystem` 字段随列表返回，UI 决定折叠 |

> K4 的关键点：把 try/catch 从「包住整个 when」改成「包住单个 add 调用」，
> 并在添加前校验存在性 —— 否则一个卸载过的包会让过滤规则只应用一半（静默错误）。

---

## 8. Dart 侧改造清单

| # | 改动 | 文件 |
|---|---|---|
| D1 | 列表模型升级：`{package,label,isSystem,installed}`；已选置顶 + 系统应用分组折叠 | `access_page.dart` |
| D2 | 图标：懒加载 + LRU(200) + 磁盘缓存 + 首字母占位 + `accessControlHideIcons` | `access_page.dart` + 新增 `lib/core/services/app_icon_cache.dart` |
| D3 | 状态条：`未连接 / 待重连 / 已生效`（依赖 K3） | `access_page.dart` |
| D4 | 快捷操作：全选 / 清空 / 只看已选 / 反选 | 同上 |
| D5 | 已卸载包分组 + 一键清理 | 同上 |
| D6 | 预设（排除支付类 / 只代理浏览器） | 同上 + `lib/core/services/app_presets.dart` |
| D7 | 「显示全部应用」开关（触发 K1 的 includeAll） | `settings_page.dart` 或页面内 |
| D8 | 桌面端只读说明行 | `settings_page.dart` |
| D9 | 新增 l10n key（zh/en 各一份，共约 14 个） | `lib/l10n/app_strings.dart` |

---

## 9. 边界与风险

| 风险 | 处置 |
|---|---|
| 卸载应用后 `addAllowedApplication` 抛异常 | K4：先校验存在性 + 单个 try/catch |
| 用户把所有应用都排除/一个都不选 | UI 明确提示「等于没有 App 走代理」；`selected` 且空集时状态条标红警告 |
| 工作资料（工作空间）里的应用枚举不到 | 文档说明；不做（需要 DevicePolicyManager 权限） |
| 双开/分身应用（vivo 有） | 分身应用是独立 UID，包名可能带后缀 → 若枚举到就正常显示，枚举不到归入「未覆盖」说明 |
| 系统在后台杀掉 VpnService | 已有 `onRevoke`/重连逻辑；本次新增「已生效」状态能立刻暴露「VPN 掉了」 |
| 图标内存（200 项 × 48dp PNG） | LRU + 可关开关；实测单图标 ~3KB → 200 项约 600KB，可接受 |
| 反复改动触发频繁重连 | 自动生效做成默认关 + 1.5s 防抖 |

---

## 10. 验收标准与测试计划

**功能验收（真机，Android 13 / vivo V2072A 已实测基线）**
1. `selected` 模式选 1 个空闲 App → 重连后 `tun0` 10 秒增量 = 0 字节（现有基线）；
   切换为 `denied` → 同一时段内核日志出现隧道流量。
2. 被勾选 App 打开后能正常联网，未勾选 App 直连（出口 IP 与代理无关）。
3. 卸载一个已勾选的 App → 重连后**其余勾选项仍全部生效**（K4 回归点，现状会失败）。
4. 状态条：改动后显示「待重连」，重连后显示「已生效」；断开时显示「未连接」。
5. 200 个应用规模下：列表滚动不掉帧（图标懒加载）、搜索 200ms 内有结果、已选 3 个置顶可见。

**自动化测试（Dart 侧，不依赖真机）**
- `test/access_control_page_test.dart`（新增）：
  - 模式切换写入 `accessControlMode`；勾选写入 `accessControlApps`（含顺序稳定）
  - 已选置顶；搜索过滤 label 与 package；系统应用折叠/展开
  - 已卸载包出现在「已卸载」分组且可一键清理
  - `selected` + 空集 → 显示警告文案
  - 状态条三态：mock `getAppliedAccessControl` 返回值分别断言「未连接/待重连/已生效」
  - 图标：mock `getAppIcon` 返回 null → 显示首字母占位（不空白、不抛异常）
- `test/access_control_presets_test.dart`（新增）：预设只改选择集、不猜包名、执行前有确认清单
- Kotlin 侧 `applyAccessControl` 的包过滤逻辑：抽成纯函数 `filterExisting(packages, exists: (String)->Boolean)`
  以便在 Dart 测试里用等价逻辑做契约测试（Kotlin 单测基础设施未接入，本期先用 Dart 契约测试 + 真机验收 3）

**回归**：`page_overflow_test.dart`（380×620 / 420×780 零渲染异常）需覆盖新列表行与状态条。

---

## 11. 实施顺序（建议 3 个 PR）

| PR | 内容 | 价值 |
|---|---|---|
| PR1 | K4/K5 + D3（先修「规则只应用一半」和「自身出现在列表」+ 已生效状态） | 修正确性 bug，用户立刻可感知 |
| PR2 | 图标（K2 + D2/ D1 分组置顶）+ 系统应用折叠（K1/K6 + D7） | 可用性提升最大的一块 |
| PR3 | 预设（D6）、已卸载清理（D5）、自动生效选项（D3 的可选开关）、桌面端说明（D8） | 体验收尾 |

> 版本节奏：PR1 建议随下一个补丁版（2.2.12）发出；PR2/PR3 可合并成 2.3.0。
