/// 节点测速方式（用户可在设置里切换；**默认内核测速**）。
///
/// 对标 Shadowrocket 的「Ping / Connect」两种测速：
///
/// - [kernel]（Connect / 内核测速，默认）：让**内核真的通过该节点发一次请求**
///   （`GET /proxies/{name}/delay`），密码/UUID/公钥/协议/回程全部
///   参与验证 —— 这才是「节点可用」。慢一点（每节点一次真实建连 + 一次
///   HTTP 往返），但不会给假阳性。
/// - [tcp]（Ping / TCP 测速）：只对 `服务器:端口` 做 TCP 握手计时。
///   快，但**只能证明端口开着**：凭据错误、协议不被内核支持、回程被墙、
///   甚至端口后面跑的根本不是代理服务（面板占位节点、被运营商劫持的
///   假 204），它一样显示「有延迟」。
///
/// 默认用 [kernel]：列表里显示「有延迟」的节点必须**真的能用** —— 用户看到
/// 数字就去连，TCP 口径的假阳性会直接变成「连不上」。想要更快更轻量的预筛
/// 时，用户可在设置里切到 [tcp]。
library;

enum SpeedTestMode {
  /// 内核测速（真连接）
  kernel,

  /// TCP 测速（仅端口连通）
  tcp,
}

/// 默认测速方式：**内核测速（真连接）**。
///
/// 为什么不是 TCP：本文件上一段说明了 TCP 口径的假阳性 —— 「8ms 超快节点」
/// 连上去却不通，这是用户最直接的痛点。默认必须是「测出来能用就真能用」。
///
/// 注意「老用户本地设置里没有这个 key / 存着旧默认值 tcp」的场景：读取时
/// **必须**宽容回落到这里，不能抛异常 —— 见 [parseSpeedTestMode] 与
/// `SettingsStore._defaults()`（默认值合并 + 宽容解析 + 旧默认值迁移三重保障）。
const SpeedTestMode defaultSpeedTestMode = SpeedTestMode.kernel;

/// 持久化/展示用的稳定字符串键（写进 SettingsStore 的 JSON）。
String speedTestModeKey(SpeedTestMode mode) =>
    mode == SpeedTestMode.tcp ? 'tcp' : 'kernel';

/// 宽容解析持久化值。
///
/// **任何**无法识别的输入（null / 缺 key / 空串 / 拼错 / 非字符串）都回落到
/// [defaultSpeedTestMode]（内核测速）。
///
/// 注意两个方向都必须**显式**识别：
/// - `tcp`/`ping`：用户主动选了「快但可能不准」，不能被默认值吃掉；
/// - `kernel`/`connect`：用户主动选了内核测速，同样不能被回落改掉。
SpeedTestMode parseSpeedTestMode(Object? raw) {
  final v = raw?.toString().trim().toLowerCase() ?? '';
  if (v == 'tcp' || v == 'ping') return SpeedTestMode.tcp;
  if (v == 'kernel' || v == 'connect') return SpeedTestMode.kernel;
  return defaultSpeedTestMode;
}
