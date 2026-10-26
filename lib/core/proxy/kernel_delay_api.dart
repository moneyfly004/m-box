/// 内核（sing-box / Clash 兼容 API）延迟测试 API 的**纯函数**部分。
///
/// 抽出来的原因：同一套 `/proxies/{name}/delay` 调用在三个地方各写了一遍
/// （桌面 CLI 内核、移动端嵌入式内核、测速专用内核），三份实现里最容易写错的
/// 两点恰恰是纯逻辑、可以单测的：
///
/// 1. **节点名必须 URL 编码**。节点 tag 里普遍带 emoji、空格、`/`、中文
///    （真实订阅里就有「🇭🇰 香港 01 | 倍率:1.0」）。不编码时 `/` 会被当成
///    路径分隔符（`/proxies/A/B/delay` → 内核 404），`#`/`?`/空格会被当成
///    fragment/query 分隔（内核收到截断的名字 → `proxy not found`），
///    表现是「这些节点永远测不出延迟」，而用户只会以为节点挂了。
///    `Uri.encodeComponent` 把 `/` 编成 `%2F`、空格编成 `%20`、emoji 编成
///    4 组 `%XX`，是唯一正确做法。
///
/// 2. **响应解析的口径**：只有 `200 + {'delay': <num>}` 才算成功；
///    `408`（内核自己的超时）/`400`（节点不存在）/`504`（目标不可达）
///    都是失败，必须返回 -1，绝不能编一个数字出来 —— 假延迟会让用户
///    把不可用节点选成「最优线路」。
library;

/// 内核延迟测试**兜底**探测地址（调用方未传 url 时使用）。
///
/// 刻意与 `SettingsStore.defaultTestUrl` 保持一致（**HTTPS**），而不是
/// `tool/verify_sub.dart` 里那个明文 http 版：
/// - 明文 204 会被运营商/中间设备直接应答，内核自己都会警告
///   `failed to get the second response from http://...` 并建议改用 HTTPS；
/// - 更关键的是，内核测速的**目的**是证明「节点真的能把流量送出去」。
///   https 要求 TLS 握手端到端穿过隧道，比明文 204 强得多 —— 明文下
///   路径上的劫持者可以凭空回一个 204，又把假阳性带回来。
///
/// 所以这里不用 http（尽管本任务描述里提到过它）：那正是项目 2.1.x 已经
/// 显式迁移掉的旧默认值，见 `SettingsStore.legacyHttpTestUrl`。
const String defaultKernelDelayUrl = 'https://www.gstatic.com/generate_204';

/// 构造内核 delay 接口路径（含节点名 URL 编码）。
///
/// `Uri.encodeComponent` 会编码 `/`、空格、`#`、`?`、`%`、emoji 与中文，
/// 但保留 `-_.!~*'()`（RFC 3986 unreserved），与内核的 router 兼容。
String kernelDelayPath(String tag) =>
    '/proxies/${Uri.encodeComponent(tag)}/delay';

/// 解析 `/proxies/{name}/delay` 的响应。
///
/// 返回延迟毫秒数；任何不满足「HTTP 200 + delay 为数字」的情况都返回 -1
/// （失败/超时/节点不存在）。**绝不返回 0**：0ms 会被 `mfLatencyUsable`
/// 判为不可信（0 通常来自被劫持的明文探测），也可能被误当成「极快」。
int parseKernelDelayResponse(int? statusCode, Object? data) {
  if (statusCode != 200) return -1;
  if (data is! Map) return -1;
  final d = data['delay'];
  if (d is! num) return -1;
  final ms = d.toInt();
  // 内核偶发返回 0/负数（配置异常），按失败处理，不给假数字
  return ms > 0 ? ms : -1;
}

/// 从内核错误响应里提取人类可读的原因（`{"message":"..."}`）。
///
/// 内核失败时返回的是 `400 {"message":"An error occurred in the delay test"}`
/// 或 `408`，把 message 带进日志能让「为什么全失败」可诊断
/// （例如 `proxy not found` = 节点名编码/组名写错，而不是节点挂了）。
String? kernelDelayErrorMessage(int? statusCode, Object? data) {
  if (data is Map) {
    final m = data['message']?.toString().trim();
    if (m != null && m.isNotEmpty) return m;
  }
  return statusCode == 200 ? null : 'HTTP $statusCode';
}
