/// 节点测速方式（用户可在设置里切换；默认 TCP 测速）。
///
/// 对标 Shadowrocket 的「Ping / Connect」两种测速：
///
/// - [kernel]（Connect / 内核测速）：让**内核真的通过该节点发一次请求**
///   （`GET /proxies/{name}/delay`），密码/UUID/公钥/协议/回程全部
///   参与验证 —— 这才是「节点可用」。慢一点（每节点一次真实建连 + 一次
///   HTTP 往返），但不会给假阳性。
/// - [tcp]（Ping / TCP 测速）：只对 `服务器:端口` 做 TCP 握手计时。
///   快，但**只能证明端口开着**：凭据错误、协议不被内核支持、回程被墙、
///   甚至端口后面跑的根本不是代理服务（面板占位节点、被运营商劫持的
///   假 204），它一样显示「有延迟」。
///
/// 默认用 [tcp]：快、轻量、不额外拉起内核；想要「真连接」判定可用性时，
/// 用户可在设置里切到 [kernel]。
library;

enum SpeedTestMode {
  /// 内核测速（真连接）
  kernel,

  /// TCP 测速（仅端口连通）
  tcp,
}

/// 默认测速方式：TCP 测速（仅端口连通）。
///
/// 注意「老用户本地设置里没有这个 key」的场景：读取时**必须**回落到这里，
/// 不能抛异常 —— 见 [parseSpeedTestMode] 与
/// `SettingsStore._defaults()`（默认值合并 + 宽容解析双重保障）。
const SpeedTestMode defaultSpeedTestMode = SpeedTestMode.tcp;

/// 持久化/展示用的稳定字符串键（写进 SettingsStore 的 JSON）。
String speedTestModeKey(SpeedTestMode mode) =>
    mode == SpeedTestMode.tcp ? 'tcp' : 'kernel';

/// 宽容解析持久化值。
///
/// **任何**无法识别的输入（null / 缺 key / 空串 / 拼错 / 非字符串）都回落到
/// [defaultSpeedTestMode]。
///
/// 注意：[kernel] 必须**显式**识别 —— 否则显式选了内核测速的用户会因为
/// 「解析不到」而回落成 TCP，等于他的选择被静默改掉。
SpeedTestMode parseSpeedTestMode(Object? raw) {
  final v = raw?.toString().trim().toLowerCase() ?? '';
  if (v == 'tcp' || v == 'ping') return SpeedTestMode.tcp;
  if (v == 'kernel' || v == 'connect') return SpeedTestMode.kernel;
  return defaultSpeedTestMode;
}
