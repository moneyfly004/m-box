import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/proxy/proxy_core_cli.dart';
import '../../core/services/app_log.dart';
import '../../core/services/settings_store.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// 日志中心：两个 Tab
/// - 内核日志（实时）：sing-box 引擎输出 —— 引擎级排障（连不上/打不开网页）
/// - 运行日志：App 自身记录 —— 应用流程排障（没自动连/订阅没更新等）
class LogCenterPage extends StatelessWidget {
  const LogCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              onPressed: () => Navigator.pop(context)),
          title: Text(AppStrings.t('log_center_title')),
          bottom: TabBar(
            indicatorColor: MBColors.brand,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: MBColors.brand,
            unselectedLabelColor: MBColors.txt3,
            labelStyle: const TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 13.5),
            tabs: [
              Tab(text: AppStrings.t('settings_kernel_log')),
              Tab(text: AppStrings.t('settings_log')),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _KernelLogTab(),
            _AppLogTab(),
          ],
        ),
      ),
    );
  }
}

/// 清空日志的确认弹窗 —— **两个 Tab 共用同一份实现**。
///
/// 旧实现里 App 日志 tab 有确认框，内核日志 tab 却是
/// `onPressed: () => setState(_lines.clear)`：一次误点就把内核现场日志清光，
/// 而那正是客服排障最需要的东西（且页面每 1.2s 只增量拉取，清掉就再也回不来）。
Future<bool> _confirmClearLog(BuildContext context, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: MBColors.card2,
      title:
          Text(AppStrings.t('clear_log'), style: const TextStyle(fontSize: 15)),
      content: Text(message, style: TextStyle(fontSize: 13, color: MBColors.txt2)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppStrings.t('cancel_text'))),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(AppStrings.t('clear_log'),
              style: TextStyle(color: MBColors.red)),
        ),
      ],
    ),
  );
  return ok == true;
}

// ================= 内核日志（实时）Tab =================

class _KernelLogTab extends StatefulWidget {
  const _KernelLogTab();

  @override
  State<_KernelLogTab> createState() => _KernelLogTabState();
}

class _KernelLogTabState extends State<_KernelLogTab>
    with AutomaticKeepAliveClientMixin {
  final List<String> _lines = [];
  static const _maxLines = 600;

  StreamSubscription<String>? _streamSub;
  Timer? _pollTimer;
  String _level = 'warning';

  static const _levels = ['debug', 'info', 'warning', 'error', 'silent'];

  // Android 轮询状态：_pollBusy 防止上一轮（含 drain 续读）未结束时定时器重入；
  // _cursorReset 仅首次进入页面时为 true，让第一轮请求原生侧回放「最近行」建立
  // 基线（后续增量）。因 Tab 走 keep-alive，状态不销毁，重置只发生在首次打开。
  bool _pollBusy = false;
  bool _cursorReset = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    SettingsStore.instance.load().then((s) {
      if (!mounted) return;
      final lv = s['kernelLogLevel']?.toString() ?? 'warning';
      setState(() => _level = _levels.contains(lv) ? lv : 'warning');
    });
    if (Platform.isAndroid || Platform.isIOS) {
      // 原生侧自上次读取位置起只回传增量行，且返回内容经 hasMore 分片追平，
      // 因此轮询间隔可放宽到 1200ms 而不丢日志。
      // iOS 同样走这条路：内核日志由 PacketTunnel 扩展抽到 App Group 的
      // kernel.log，原生侧同一套增量语义（原先 iOS 落到桌面 CLI 分支 →
      // 这个页面在 iOS 上永远是空的，出问题时看不到任何内核输出）。
      _pollTimer = Timer.periodic(
          const Duration(milliseconds: 1200), (_) => _pollAndroid());
    } else {
      _lines.addAll(ProxyCoreCli.logTailSnapshot());
      _trim();
      _streamSub = ProxyCoreCli.kernelLogStream.stream.listen(_append);
    }
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Android 轮询：拉「增量」日志。
  ///
  /// 原生侧只回传自上次读取以来新增的完整行（首次/重进页面先回放最近若干行基线），
  /// 并用 hasMore 告知本批是否截断 —— 截断时立即续读（每轮最多 8 片）尽量追平；
  /// 整帧累计的所有增量行在末尾合并成一次 setState 追加，避免逐行刷新越拉越卡。
  Future<void> _pollAndroid() async {
    if (_pollBusy) return;
    _pollBusy = true;
    try {
      const ch = MethodChannel('top.mbox/vpn_core');
      final merged = <String>[];
      for (var round = 0; round < 8; round++) {
        final res = await ch.invokeMethod<Map<dynamic, dynamic>>(
          'fetchKernelLogs',
          <String, dynamic>{'incremental': true, 'reset': _cursorReset},
        );
        _cursorReset = false;
        if (res == null) break;
        final log = res['log'];
        if (log is String && log.isNotEmpty) {
          for (final l in log.split('\n')) {
            if (l.trim().isNotEmpty) merged.add(l);
          }
        }
        if (res['hasMore'] != true) break;
      }
      if (merged.isNotEmpty) _appendLines(merged);
    } catch (_) {
      // 通道暂不可用等偶发错误：静默跳过，等下一个轮询周期重试
    } finally {
      _pollBusy = false;
    }
  }

  /// 一批行（可能跨多个 drain 轮次合并）一次性追加并 setState，同时保留行数上限
  void _appendLines(List<String> lines) {
    if (!mounted || lines.isEmpty) return;
    setState(() {
      _lines.addAll(lines);
      _trim();
    });
  }

  /// 内核日志行按级别着色:debug=灰蓝 info=正文 warning=琥珀 error=红
  Color _lineColor(String line) {
    final l = line.toLowerCase();
    if (l.contains('level=error') || l.contains('panic') ||
        l.contains('fatal') || l.contains('exception')) {
      return const Color(0xFFFF6B6B);
    }
    if (l.contains('level=warning') || l.contains('warn')) {
      return const Color(0xFFE0A93C);
    }
    if (l.contains('level=debug')) {
      return const Color(0xFF8FB4E8);
    }
    return MBColors.txt2;
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      _trim();
    });
  }

  void _trim() {
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
  }

  Future<void> _setLevel(String lv) async {
    setState(() => _level = lv);
    final conn = ConnectionController.instance;
    final wasConnected = conn.status == ConnStatus.connected;
    final live = await conn.setKernelLogLevel(lv);
    if (!mounted) return;
    // 已连接但未能热更（Android：embed 模式禁 PATCH）→ 明确告知需重连，
    // 否则用户会以为「切了级别却没日志」是内核出问题。
    if (wasConnected && !live) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.t('log_level_need_reconnect'),
            style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  /// 清空内核日志：与 App 日志 tab 一样**先确认**再清
  Future<void> _clear() async {
    final ok = await _confirmClearLog(
        context, AppStrings.t('kernel_log_clear_confirm'));
    if (!ok || !mounted) return;
    setState(_lines.clear);
  }

  /// 等级筛选 chip：整块 40 高命中区 + InkWell 按压反馈
  /// （旧实现是 GestureDetector + ~23px 的 Container：没有按压反馈、命中区偏小）
  Widget _levelChip(String lv) {
    final active = _level == lv;
    final radius = BorderRadius.circular(8);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: active ? MBColors.brandGradient : null,
            color: active ? null : MBColors.card,
            borderRadius: radius,
            border: Border.all(
                color: active ? Colors.transparent : MBColors.line),
          ),
          child: InkWell(
            onTap: () => _setLevel(lv),
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Center(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Text(
                    lv.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: active ? Colors.white : MBColors.txt2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        // 工具栏：级别切换 + 连接状态 + 复制/清空
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 4),
          child: Row(
            children: [
              Text(AppStrings.t('kernel_log_level'),
                  style: TextStyle(fontSize: 11, color: MBColors.txt3)),
              const SizedBox(width: 8),
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final lv in _levels) _levelChip(lv),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 连接状态随控制器刷新（旧实现直接读单例快照，连上/断开后
              // 这里的小圆点和「未连接」文案不会更新）
              ListenableBuilder(
                listenable: ConnectionController.instance,
                builder: (context, _) {
                  final running = ConnectionController.instance.status ==
                      ConnStatus.connected;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: running ? MBColors.green : MBColors.txt3,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(running ? '' : AppStrings.t('kernel_stopped'),
                          style: TextStyle(
                              fontSize: 10,
                              color: running ? MBColors.green : MBColors.txt3)),
                    ],
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 17),
                tooltip: AppStrings.t('copy'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _copyAll(),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: AppStrings.t('clear_log'),
                visualDensity: VisualDensity.compact,
                // 清空必须确认（与 App 日志 tab 同一实现）：内核现场日志
                // 是排障证据，不能一次误点就没了
                onPressed: _clear,
              ),
            ],
          ),
        ),
        // 级别语义说明：这个下拉既改内核输出级别、也过滤本页显示
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(AppStrings.t('kernel_log_level_desc'),
              style: TextStyle(fontSize: 10, color: MBColors.txt3, height: 1.4)),
        ),
        Divider(height: 1, color: MBColors.line),
        // 日志区：**最新在最上方**（不用 reverse）。
        // 原实现用 reverse:true 让最新贴底，但日志条数少于视口高度时，内容会全部
        // 堆在底部、顶部留出一大片空白（真机反馈「上半截一片空白」）。
        // 改为从上往下、最新在前：无论日志多少都从顶部开始排，且最新一条无需滚动。
        //
        // 行本身用普通 Text：旧实现每行一个 SelectableText（最多 600 个，各自
        // 带一套选区状态），低端机上明显卡顿；整块套一个 SelectionArea，
        // 仍然可以跨行选择/复制（顶部另有「复制」按钮）。
        Expanded(
          child: _visibleLines.isEmpty
              ? Center(
                  child: Text(
                      _lines.isEmpty
                          ? AppStrings.t('kernel_log_empty')
                          : AppStrings.t('kernel_log_empty_at_level',
                              {'level': _level.toUpperCase()}),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: MBColors.txt3, height: 1.7)))
              : SelectionArea(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    itemCount: _visibleLines.length,
                    itemBuilder: (context, i) {
                      final line = _visibleLines[_visibleLines.length - 1 - i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          line,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.55,
                            color: _lineColor(line),
                            fontFamily: kNumFont,
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// 级别数值：越大越严重。兼容 sing-box（trace/debug/info/warn/error/fatal/panic）
  /// 与旧内核的 warning/silent 写法。
  static int _levelRank(String level) => kernelLogLevelRank(level);

  static String _lineLevel(String line) => kernelLogLineLevel(line);

  /// 本页显示的行：**按当前级别过滤**。
  /// 原先级别只作用于「内核输出」（PATCH /configs），已收集的日志不受影响，
  /// 于是切换 debug/info/warning/error 时看到的内容几乎一样（真机反馈
  /// 「感觉区别不大」）。现在同一级别同时过滤显示，切换立刻可见。
  List<String> get _visibleLines {
    final min = _levelRank(_level);
    return _lines
        .where((l) => _levelRank(_lineLevel(l)) >= min)
        .toList(growable: false);
  }

  Future<void> _copyAll() async {
    // 复制「当前可见」的行：与页面所见一致（级别过滤后只导错误时有意义）
    final text = _visibleLines.join('\n');
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(
      content: Text(AppStrings.t('kernel_log_copied'),
          style: const TextStyle(fontSize: 13)),
      duration: const Duration(seconds: 1),
    ));
  }
}

// ================= App 运行日志 Tab =================

class _AppLogTab extends StatefulWidget {
  const _AppLogTab();

  @override
  State<_AppLogTab> createState() => _AppLogTabState();
}

class _AppLogTabState extends State<_AppLogTab>
    with AutomaticKeepAliveClientMixin {
  List<String> _lines = const [];
  bool _loading = true;
  bool _filterError = false;

  @override
  bool get wantKeepAlive => true;

  static bool _isErrorLine(String line) =>
      line.contains('[ERROR]') || line.toLowerCase().contains('level=error');

  Color _lineColor(String line) =>
      _isErrorLine(line) ? const Color(0xFFFF6B6B) : MBColors.txt2;

  List<String> get _visible =>
      _filterError ? _lines.where(_isErrorLine).toList() : _lines;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    var lines = const <String>[];
    try {
      final content = await AppLog.read();
      final raw = content.split('\n');
      // 文件以换行结尾，去掉末尾的空串（避免渲染出多余空行）
      lines = raw.isNotEmpty && raw.last.isEmpty
          ? raw.sublist(0, raw.length - 1)
          : raw;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _lines = lines;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    // 与内核日志 tab 共用同一份确认实现
    final ok = await _confirmClearLog(context, AppStrings.t('log_clear_confirm'));
    if (!ok) return;
    await AppLog.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(AppStrings.t('app_log_desc'),
                    style: TextStyle(fontSize: 10.5, color: MBColors.txt3)),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 17),
                tooltip: AppStrings.t('refresh'),
                visualDensity: VisualDensity.compact,
                onPressed: _load,
              ),
              IconButton(
                icon: Icon(
                    _filterError ? Icons.filter_alt : Icons.filter_alt_outlined,
                    size: 17),
                tooltip: AppStrings.t('log_only_errors'),
                color: _filterError ? MBColors.brandLight : null,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _filterError = !_filterError),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 17),
                tooltip: AppStrings.t('copy'),
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  final visible = _visible;
                  if (visible.isEmpty) return;
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(
                      ClipboardData(text: visible.join('\n')));
                  messenger.showSnackBar(SnackBar(
                    content: Text(AppStrings.t('kernel_log_copied')),
                    duration: const Duration(seconds: 1),
                  ));
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: AppStrings.t('clear_log'),
                visualDensity: VisualDensity.compact,
                onPressed: _clear,
              ),
            ],
          ),
        ),
        Divider(height: 1, color: MBColors.line),
        Expanded(
          child: _loading
              ? Center(
                  child: CircularProgressIndicator(color: MBColors.brand))
              : _lines.isEmpty
                  ? Center(
                      child: Text(AppStrings.t('log_empty'),
                          style: TextStyle(
                              fontSize: 12, color: MBColors.txt3)))
                  : _visible.isEmpty
                      ? Center(
                          child: Text(AppStrings.t('log_no_errors'),
                              style: TextStyle(
                                  fontSize: 12, color: MBColors.txt3)))
                      // 不用 reverse：日志条数少时 reverse 会把内容全堆在底部，
                      // 顶部留一大片空白（真机反馈）；改为最新在最上方。
                      // 行用普通 Text + 外层单个 SelectionArea（理由同内核日志 tab）。
                      : SelectionArea(
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            itemCount: _visible.length,
                            itemBuilder: (context, i) {
                              final line = _visible[_visible.length - 1 - i];
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 1),
                                child: Text(
                                  line,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    height: 1.6,
                                    color: _lineColor(line),
                                    fontFamily: kNumFont,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
        ),
      ],
    );
  }
}

/// 内核日志级别排序：数值越大越严重。
///
/// 同时兼容 sing-box（trace/debug/info/warn/error/fatal/panic）与旧内核写法
/// （warning/silent）。**必须放在顶层并可测**：这套映射曾按旧内核格式写死，
/// 换成 sing-box 后行内级别是 `INFO`/`DEBUG` 而非 `level=info`，
/// 导致日志页的级别过滤完全失效（切 debug/error 看到的内容一样）。
int kernelLogLevelRank(String level) {
  switch (level.toLowerCase()) {
    case 'trace':
    case 'debug':
      return 0;
    case 'info':
      return 1;
    case 'warning':
    case 'warn':
      return 2;
    case 'error':
    case 'fatal':
    case 'panic':
      return 3;
    case 'silent':
      return 4;
    default:
      return 1; // 无法识别的行（如 app 自己写的 `[app] …` 提示行）按 info 处理
  }
}

/// 从内核日志行里取级别，兼容两种格式：
///  - sing-box：`+0800 2026-10-26 18:06:04 INFO [3230225162 0ms] inbound/...`
///  - 旧内核：  `time="…" level=info msg="…"`
final _sbLevelRe = RegExp(r'\s(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|PANIC)\s');
final _kvLevelRe = RegExp(r'level=([a-zA-Z]+)');

String kernelLogLineLevel(String line) {
  final kv = _kvLevelRe.firstMatch(line);
  if (kv != null) return kv.group(1)!.toLowerCase();
  final sb = _sbLevelRe.firstMatch(line);
  if (sb != null) return sb.group(1)!.toLowerCase();
  return 'info';
}
