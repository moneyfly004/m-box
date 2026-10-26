/// TUN 启动失败的判定与分类（纯 Dart，无 Flutter 依赖，可单测）。
///
/// 为什么需要它：sing-box 与 mihomo 共用 sing-tun，TUN 起不来时**不会让
/// Clash API 报错**（sing-box 通常直接 FATAL 退出，进程监控会兜底；但桌面
/// 以 root/提权方式重试的过程中仍可能出现「进程还活着、TUN 是死的」窗口）
/// → App 若只看 API 200，就会「显示已连接、零流量、零报错」（force 模式尤其
/// 致命）。所以必须读内核日志判定。
///
/// 但判定不能粗：旧实现是「行里同时含 `tun` 和 `error`/`failed`」，而内核
/// 日志里有一批**正常告警与转发期噪音**同样命中，会直接把一条本来好好的连接
/// 判死、还提示用户「请以管理员身份运行」：
///   - `[TUN] Auto detect interface for <名> failed, return '<invalid>' …`
///     （auto-detect-interface 在多虚拟网卡 / Hyper-V / 某些 VPN 环境下探不到
///      出口接口，属正常告警，TUN 本身是好的）
///   - `[TUN] default interface changed/lost by monitor …`（网卡切换监控，正常）
///   - `[TUN] Tun adapter listening at: …`、`[TUN] use tun name …`（成功日志）
///   - `error writing to TUN device` / `Failed to read packet from TUN device`
///     （数据面转发错误，连接期偶发，不代表 TUN 没起来）
///
/// 因此这里只认**真正的启动失败**串（见 [_fatalMarkers]），再按原因分类，
/// 让上层能给出可执行的提示（提权 / 网卡冲突 / 驱动被拦），而不是一句
/// 万能的「请以管理员身份运行」。
library;

/// TUN 启动失败的原因分类
enum TunStartFailure {
  /// 没有失败（含「只有告警」的情况）
  none,

  /// 权限不足：Windows 未以管理员运行 / macOS 未以 root 运行
  privilege,

  /// 虚拟网卡已存在或被占用（同名网卡残留、上次异常退出留下的适配器）
  adapterBusy,

  /// 虚拟网卡驱动 / DLL 无法加载（多被安全软件拦截）
  driver,

  /// 起来了但原因无法归类
  unknown,
}

/// 真正的「TUN 没起来」标记（sing-tun 的启动失败出口）。
/// 必须精确：多一个宽泛词就会把正常连接判死。
const _fatalMarkers = <String>[
  'start tun listening error',
  'start tun interface timeout',
  // sing-box 启动 inbound/tun 失败时的 FATAL 前缀（进程随后退出，双保险）
  'start service: start inbound/tun',
  'start inbound/tun',
];

/// 已核实的**正常** TUN 日志（从内核二进制里逐条挑出）。
/// 这些行含 tun + failed/error，但完全不代表 TUN 没起来 —— 弱判据里要排除它们，
/// 否则每台多网卡机器都会刷一条无意义的「疑似 TUN 异常」。
const _knownBenignMarkers = <String>[
  'auto detect interface', // auto-detect-interface 探不到出口接口（多网卡/Hyper-V/VPN）
  'default interface changed', // 网卡切换监控
  'default interface lost',
  'tun name failed', // 取设备名失败，会用回退名继续
  'unsupported tunname',
];

/// 权限类特征（Windows ERROR_ACCESS_DENIED / POSIX EPERM）
const _privilegeMarkers = <String>[
  'access is denied',
  'access denied',
  'permission denied',
  'operation not permitted',
  'requires elevation',
  'administrator',
  'run as root',
];

/// 网卡冲突特征（Windows ERROR_ALREADY_EXISTS：同名适配器已存在）
const _busyMarkers = <String>[
  'already exists',
  'already in use',
  'address already in use',
  'file exists',
  'device is in use',
  'in use',
];

/// 驱动/依赖加载失败特征
const _driverMarkers = <String>[
  'wintun',
  'unable to load library',
  'load library',
  'driver',
  '.dll',
  'not found',
];

/// 单行是否命中「真致命」标记。
///
/// 供内核日志**边收边判**用：日志缓冲区有容量上限（40 行）且级别可调成 debug，
/// 只在就绪时回头扫缓冲区会漏判 —— 启动瞬间打了几十条 debug 日志就把致命行挤
/// 出去了。收到即判定与缓冲区无关。
bool isFatalTunLine(String line) =>
    _fatalMarkers.any((m) => line.toLowerCase().contains(m));

/// TUN 是否真的启动失败、以及失败原因（纯函数）。
///
/// 只在 [lines] 里找到 [_fatalMarkers] 时才返回失败；分类取「最后一条致命行」
/// 及其之后的内容（内核通常把致命行与 OS 错误打在同一行或紧随其后）。
TunStartFailure detectTunStartFailure(Iterable<String> lines) {
  final all = [for (final l in lines) l.toLowerCase()];
  var lastFatal = -1;
  for (var i = 0; i < all.length; i++) {
    if (_fatalMarkers.any((m) => all[i].contains(m))) lastFatal = i;
  }
  if (lastFatal < 0) return TunStartFailure.none;

  // 致命行及其之后的若干行一起看：内核有时把 OS 错误另起一行
  final window = all.sublist(lastFatal, (lastFatal + 4).clamp(0, all.length));
  bool has(List<String> markers) =>
      window.any((l) => markers.any(l.contains));

  // 顺序即优先级：权限 → 驱动 → 冲突。
  // 「Access is denied」在驱动加载被打断时也会出现，但提权是用户真能立刻做的
  // 动作，所以优先给权限提示；纯驱动失败（无权限特征）才报被拦截。
  if (has(_privilegeMarkers)) return TunStartFailure.privilege;
  if (has(_driverMarkers)) return TunStartFailure.driver;
  if (has(_busyMarkers)) return TunStartFailure.adapterBusy;
  return TunStartFailure.unknown;
}

/// **弱判据**：日志里有「像 TUN 出错」的行，但不是已知的致命串、也不是已知的
/// 正常日志。
///
/// 存在意义：内核的失败文案无法穷举，[detectTunStartFailure] 只认两个已核实
/// 的致命串 —— 万一真失败换了文案，硬判据会漏判。此时不强判失败（避免重演
/// 「正常连接被判死」），而是让上层记一条可查的提示，把「静默假连接」降级成
/// 「日志里留痕」。所以这个函数**允许假阳性**：命中也只写日志，不中断连接。
bool looksLikeTunTrouble(Iterable<String> lines) {
  for (final l in lines) {
    final s = l.toLowerCase();
    if (!s.contains('tun')) continue;
    if (!(s.contains('error') || s.contains('failed') || s.contains('unable'))) {
      continue;
    }
    if (_knownBenignMarkers.any(s.contains)) continue; // 已核实的正常日志
    return true;
  }
  return false;
}

/// 该失败是否值得自动重试。
/// 权限类**不重试**：进程不可能在运行中获得管理员权限，重试只是把可执行的
/// 提示延后 8~30 秒（autoReconnect 开启且次数较大时更久），用户白等。
/// 其余（网卡残留、驱动被拦）可能是暂态（上一轮的内核还在拆适配器），值得重试。
bool isRetryableTunFailure(TunStartFailure failure) =>
    failure != TunStartFailure.none && failure != TunStartFailure.privilege;

/// TUN 启动失败（携带分类与内核尾部日志，供上层给出可执行提示 + 落盘取证）
class TunStartException implements Exception {
  TunStartException(this.failure, this.tail);

  final TunStartFailure failure;

  /// 内核日志尾部（排查用；UI 只显示按分类生成的短文案）
  final String tail;

  @override
  String toString() => 'TUN 启动失败（${failure.name}）：$tail';
}
