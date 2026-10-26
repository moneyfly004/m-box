import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/proxy/speed_probe_kernel.dart';
import '../../core/services/account_service.dart';
import '../../core/models/models.dart';
import '../../core/services/speed_test_mode.dart';
import '../../core/services/speed_tester.dart';
import '../../core/services/subscription_service.dart';
import '../../l10n/app_strings.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_chip.dart';
import '../../widgets/mf_input.dart';
import '../../widgets/country_flag.dart';
import '../../widgets/subscribe_issue.dart';
import '../devices/devices_page.dart';

/// 节点列表（设计稿 03）：自动选优条 + 分组 + 延迟徽标 + 真实测速
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  bool _testing = false;
  bool _refreshing = false;
  String _sort = 'default'; // default / latency / name
  final Set<String> _testingNode = {}; // 正在单点测速的 tag(显示小环)
  String _query = '';
  int _testDone = 0;
  int _testTotal = 0;
  /// 进度节流状态（每轮测速开始前 _resetProgress 重置）
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);
  double _lastPct = -1;
  Timer? _debounce; // 搜索防抖

  /// 每轮测速开始前重置进度节流状态：否则上一轮的 _lastPct(≈1.0) 会把
  /// 新一轮开头几次进度回调节流掉，用户看到进度条纹丝不动。
  void _resetProgress() {
    _lastTick = DateTime.fromMillisecondsSinceEpoch(0);
    _lastPct = -1;
  }
  final _searchCtrl = TextEditingController();

  Future<void> _load({bool force = false}) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final conn = context.read<ConnectionController>();
    try {
      final nodes = await SubscriptionService.instance.fetchNodes(force: force);
      // 受保护合并:已连接且当前线路不在新订阅时保持现状,不打断连接
      await conn.applySubscriptionNodes(nodes);
      if (mounted && nodes.isEmpty) {
        // 原因优先：能分类就弹可操作框（重新登录/续费/设备管理/重试），
        // 分类不出来才退回「订阅中没有可用节点」
        if (!mounted) return;
        if (!await SubscribeIssuePrompt.showIfAny(context,
            onRetry: () => _load(force: true))) {
          _toast(AppStrings.t('no_nodes_hint'));
        }
      }
      if (mounted && nodes.isNotEmpty && force) _toast(AppStrings.t('refresh_sub_ok'));
    } catch (e) {
      if (mounted) {
        final msg = ApiClient.errorMsg(e);
        // 设备被踢下线：断开当前连接并清空节点，提示用户
        if (SubscriptionService.isKickedMessage(msg)) {
          await conn.disconnect();
          await conn.loadNodes(const []);
        }
        if (!mounted) return;
        if (!await SubscribeIssuePrompt.showIfAny(context,
            onRetry: () => _load(force: true))) {
          _toast(msg);
        }
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _pickSort() {
    showModalBottomSheet<String>(
      context: context,
      backgroundColor: MBColors.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Text(AppStrings.t('sort_title'),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            for (final (v, l) in [
              ('default', AppStrings.t('sort_default')),
              ('latency', AppStrings.t('sort_latency')),
              ('name', AppStrings.t('sort_name')),
            ])
              ListTile(
                title: Text(l, style: const TextStyle(fontSize: 13.5)),
                trailing: _sort == v
                    ? Icon(Icons.check, size: 16, color: MBColors.brandLight)
                    : null,
                onTap: () {
                  Navigator.pop(ctx, v);
                },
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    ).then((v) {
      if (v != null && mounted) setState(() => _sort = v);
    });
  }

  /// 单点测速(点节点行延迟胶囊)：按设置里选定的测速方式走
  /// （内核测速＝真连接，TCP 测速＝仅端口握手，见 SpeedTestMode）。
  Future<void> _testOne(dynamic n) async {
    if (_testing) return;
    final conn = context.read<ConnectionController>();
    setState(() => _testingNode.add(n.tag));
    try {
      final ms = await conn.testOneNode(n);
      if (!mounted) return;
      // 用副本替换该节点结果,不污染其它引用
      final idx = conn.nodes.indexWhere((x) => x.tag == n.tag);
      if (idx >= 0) {
        final fresh = conn.nodes[idx].clone()
          ..latencyMs = ms
          // UDP 协议裸 TCP 测不了、面板占位项也不该给数字 → 保持在线、延迟未知
          ..online =
              (n.isUdpOnly || n.isPanelPseudo) ? true : mfLatencyUsable(ms);
        final list = List<ProxyNode>.of(conn.nodes);
        list[idx] = fresh;
        await conn.loadNodes(list);
      }
    } on KernelProbeException catch (e) {
      // 内核测速不可用（未连接且内核拉不起来）→ 明确告知，绝不静默失败
      if (mounted) _toast(_probeErrorText(e));
    } finally {
      if (mounted) setState(() => _testingNode.remove(n.tag));
    }
  }

  /// 内核测速失败的展示文案：带上具体原因，用户据此才能自救
  /// （先连接 / 去设置改回 TCP 测速）。缺原因时退回通用提示。
  String _probeErrorText(KernelProbeException e) {
    final detail = e.detail;
    if (detail == null || detail.isEmpty) {
      return AppStrings.t('speed_mode_kernel_needs_connect');
    }
    return AppStrings.t('speed_mode_probe_failed', {'err': detail});
  }

  /// 当前搜索/筛选命中的节点（与列表展示口径完全一致）。
  /// 测速按这个子集进行：用户筛完再点测速，只测他正在看的节点。
  List<ProxyNode> _filterNodes(List<ProxyNode> all) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return List<ProxyNode>.of(all);
    return all
        .where((n) =>
            n.tag.toLowerCase().contains(q) ||
            n.type.toLowerCase().contains(q) ||
            (n.countryCode?.toLowerCase().contains(q) ?? false) ||
            n.regionName.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _runSpeedTest() async {
    if (_testing) return; // 防并发
    final conn = context.read<ConnectionController>();
    if (conn.nodes.isEmpty) {
      _toast(AppStrings.t('no_nodes'));
      return;
    }
    // 有搜索/筛选时**只测筛选出的节点**：筛出 50 个就测 50 个，
    // 不再把上千个没在看的节点一起测（白等且看不出对比结果）。
    final targets = _filterNodes(conn.nodes);
    if (targets.isEmpty) {
      _toast(AppStrings.t('no_match_nodes'));
      return;
    }
    final filtered = targets.length != conn.nodes.length;
    _resetProgress();
    setState(() {
      _testing = true;
      _testDone = 0;
      _testTotal = targets.length;
    });
    try {
      // userInitiated: true —— 已连接时后台自动测速往往正在跑（连接后立刻
      // 一轮），旧实现遇到"忙"直接 return，用户看到的就是「只弹了个提示、
      // 延迟一个没变、进度也不动」。现在会先让那轮收尾再测用户要的这批。
      final tested = await conn.speedTest(
        tags: filtered ? {for (final n in targets) n.tag} : null,
        switchToBest: conn.autoTest,
        userInitiated: true,
        onProgress: _onTestProgress,
      );
      if (!mounted) return;
      // 只有真的测了节点才提示"完成"；一个都没测到（连接刚断/被取代）
      // 如实告知，不让用户以为测过了。
      // 内核测速失败时优先把**具体原因**说出来（speedTestError）：
      // 否则用户只看到「测速未执行」而不知道是「内核起不来/要先连接」。
      if (tested == 0) {
        final err = conn.speedTestError;
        _toast(err == null || err.isEmpty
            ? AppStrings.t('speed_test_none')
            : AppStrings.t('speed_mode_probe_failed', {'err': err}));
      } else if (filtered) {
        _toast(AppStrings.t('speed_done_filtered', {'n': '$tested'}));
      } else {
        _toast(AppStrings.t('speed_done'));
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 测速进度回调：驱动顶部 ⚡ 按钮显示 done/total（如 12/50）。
  /// 节流：千节点时每完成一个就 setState 会触发上千次整页重建（含分组/
  /// 排序/拍平）→ 每 ≥120ms 或进度 ≥5% 才刷新一次（首帧必刷）。
  void _onTestProgress(int done, int total) {
    final pct = total <= 0 ? 1.0 : done / total;
    final now = DateTime.now();
    if (pct < 1.0 &&
        pct - _lastPct < 0.05 &&
        now.difference(_lastTick).inMilliseconds < 120) {
      return;
    }
    _lastTick = now;
    _lastPct = pct;
    if (mounted) {
      setState(() {
        _testDone = done;
        _testTotal = total;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    // 精准订阅：仅这些字段变化时重建列表。
    // 加入了「测速方式 / 上次测速时刻 / 测速中」：顶部那行测速口径提示
    // （来源标识）必须随设置切换即时刷新 —— 否则用户切了测速方式，界面还写着
    // 旧方式，又会让人误以为列表里的旧数字是新方式测出来的。
    context.select((ConnectionController c) => (
          n: c.nodes.length,
          t: c.current?.tag,
          m: c.speedTestMode,
          lt: c.lastSpeedTestTime,
          st: c.speedTesting,
        ));
    final conn = context.read<ConnectionController>();
    final q = _query.toLowerCase();
    final filtered = _filterNodes(conn.nodes);
    final groups = <String, List<ProxyNode>>{};
    for (final n in filtered) {
      final key = n.countryCode ?? 'XX';
      groups.putIfAbsent(key, () => []).add(n);
    }
    // 组内排序:默认=国家热度+在线+延迟+名称;延迟=在线优先再延迟升序;
    // 名称=字母序
    for (final list in groups.values) {
      switch (_sort) {
        case 'latency':
          list.sort((a, b) {
            if (a.online != b.online) return a.online ? -1 : 1;
            if (a.latencyMs < 0 && b.latencyMs < 0) return a.tag.compareTo(b.tag);
            if (a.latencyMs < 0) return 1;
            if (b.latencyMs < 0) return -1;
            return a.latencyMs.compareTo(b.latencyMs);
          });
        case 'name':
          list.sort((a, b) => a.tag.toLowerCase().compareTo(b.tag.toLowerCase()));
        default:
          list.sort(ProxyNode.compareForList);
      }
    }
    // 国家分组顺序：热门在前（港·日·新·美），其余按距中国远近（见 countryOrder）
    final sortedCodes = groups.keys.toList()
      ..sort((a, b) {
        final r = ProxyNode.countryRank(a).compareTo(ProxyNode.countryRank(b));
        return r != 0 ? r : regionName(a).compareTo(regionName(b));
      });

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
              child: Row(
                children: [
                  // 标题可收缩：英文/窄屏下「Nodes + 两个筛选芯片」会溢出
                  // （实测 Android 411dp 报 "RIGHT OVERFLOWED BY 26 PIXELS"）
                  Expanded(
                    child: Text(
                      AppStrings.t('nodes_title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 21, fontWeight: FontWeight.w700),
                    ),
                  ),
                  // 排序切换(默认国家/延迟/名称) + 刷新订阅。
                  // 都用 MBChip：命中区 ≥40px 且有按压反馈（旧实现是 24~26px 的
                  // 裸 GestureDetector，触屏上很难点准）
                  MBChip(
                    dense: true,
                    icon: Icons.sort,
                    label: switch (_sort) {
                      'latency' => AppStrings.t('sort_latency'),
                      'name' => AppStrings.t('sort_name'),
                      _ => AppStrings.t('sort_default'),
                    },
                    onTap: _pickSort,
                  ),
                  const SizedBox(width: 8),
                  MBChip(
                    dense: true,
                    icon: Icons.refresh,
                    busy: _refreshing,
                    enabled: !_refreshing,
                    label: AppStrings.t('refresh_sub'),
                    onTap: () => _load(force: true),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 10),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (v) {
                          _debounce?.cancel();
                          _debounce = Timer(const Duration(milliseconds: 300), () {
                            if (mounted) setState(() => _query = v.trim());
                          });
                        },
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontSize: 13.5),
                        decoration: mfInput(hint: AppStrings.t('search_hint'))
                            .copyWith(
                          prefixIcon: Icon(Icons.search,
                              size: 17, color: MBColors.txt3),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 11),
                          suffixIcon: _query.isEmpty
                              ? null
                              : GestureDetector(
                                  onTap: () {
                                    _searchCtrl.clear();
                                    _debounce?.cancel();
                                    setState(() => _query = '');
                                  },
                                  child: Icon(Icons.close,
                                      size: 16, color: MBColors.txt3),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _testing ? null : _runSpeedTest,
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(gradient: MBColors.brandGradient, borderRadius: BorderRadius.circular(13)),
                      alignment: Alignment.center,
                      child: _testing
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(width: 12, height: 12,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                                const SizedBox(width: 7),
                                Text('$_testDone/$_testTotal',
                                    style: const TextStyle(fontSize: 12.5, color: Colors.white, fontWeight: FontWeight.w600, fontFamily: kNumFont)),
                              ],
                            )
                          : Text('⚡ ${AppStrings.t('speed_test')}',
                              style: const TextStyle(fontSize: 12.5, color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
            // 测速口径提示：**当前方式** + 上次测速时刻。
            //
            // 为什么必须有：内核测速与 TCP 测速的数字口径不同（前者是真连接
            // RTT，后者只是端口握手），用户切了方式后如果界面上没有任何标识，
            // 就没法判断「这个 12ms 到底可不可信」。切换方式时控制器会清空旧
            // 延迟，这里再把来源与时刻写明，两种口径永远不会被混着解读。
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 22, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _speedSourceText(conn),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10.5,
                          color: MBColors.txt3,
                          fontFamily: kNumFont),
                    ),
                  ),
                ],
              ),
            ),
            // 节点列表：与其它列表页一致的**下拉刷新**（旧实现只有右上角一个小
            // chip，触屏上很难发现）。空态/无匹配分支也保持可滚动，长文案
            // （如服务端下发的禁用原因）在 620 高窗口下能滚不溢出。
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _load(force: true),
                color: MBColors.brand,
                child: conn.nodes.isEmpty
                    ? _EmptyNodesView(
                        refreshing: _refreshing,
                        onRefresh: () => _load(force: true),
                      )
                    : groups.isEmpty
                        ? _ScrollableCenter(
                            child: Text(
                              AppStrings.t('no_match_nodes'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 13, color: MBColors.txt3),
                            ),
                          )
                        : _NodeListView(
                            conn: conn,
                            groups: groups,
                            sortedCodes: sortedCodes,
                            buildNodeRow: _buildNodeRow,
                            searching: q.isNotEmpty,
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static final _nodeRadius = BorderRadius.circular(15);
  static final _nodeMargin = const EdgeInsets.fromLTRB(22, 0, 22, 8);
  static final _nodePadding = const EdgeInsets.symmetric(horizontal: 13, vertical: 12);
  static final _flagRadius = BorderRadius.circular(11);
  static final _latencyRadius = BorderRadius.circular(20);

  /// 测速口径提示文案（当前方式 + 上次测速时刻）。
  String _speedSourceText(ConnectionController conn) {
    final mode = conn.speedTestMode == SpeedTestMode.tcp
        ? AppStrings.t('speed_mode_tcp_short')
        : AppStrings.t('speed_mode_kernel_short');
    final at = conn.lastSpeedTestTime;
    if (at == null || at.isEmpty) {
      return AppStrings.t('speed_mode_label', {'mode': mode});
    }
    return AppStrings.t('speed_last_result', {'time': at, 'mode': mode});
  }

  /// 延迟胶囊文案。
  ///
  /// - 面板占位项（📢官网 等）：显示 `— ms`（绝不是数字）；
  /// - UDP 协议 + **TCP 测速**：裸 TCP 测不了，提示「连接后测速」；
  ///   内核测速下这类节点是可以测的（内核走它自己的 UDP 传输），不提示；
  /// - 其余：在线且有数字 → `123 ms`，否则 `— ms`。
  String _latencyLabel(dynamic n, {bool tcpMode = false}) {
    if (n.isPanelPseudo) return '— ms';
    if (n.isUdpOnly && n.latencyMs < 0 && tcpMode) {
      return AppStrings.t('node_need_connect_test');
    }
    if (n.online && n.latencyMs >= 0) return '${n.latencyMs} ms';
    return '— ms';
  }

  Widget _buildNodeRow(ConnectionController conn, dynamic n) {
    final isCurrent = conn.current?.tag == n.tag;
    final latencyColor = mfLatencyColor(n.latencyMs, n.online);
    return GestureDetector(
      onTap: () async {
        await conn.switchNode(n);
        if (mounted) _toast(AppStrings.t('pin_toast', {'name': n.tag}));
      },
      child: Container(
        margin: _nodeMargin,
        padding: _nodePadding,
        decoration: BoxDecoration(
          color: isCurrent ? MBColors.brand.withValues(alpha: .09) : MBColors.card,
          borderRadius: _nodeRadius,
          border: Border.all(color: isCurrent ? MBColors.brand.withValues(alpha: .6) : MBColors.line),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: MBColors.card2, borderRadius: _flagRadius),
              alignment: Alignment.center,
              child: CountryFlag(n.countryCode, size: 17),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n.tag, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text('${n.type} · ${n.port}',
                      style:  TextStyle(fontSize: 10.5, color: MBColors.txt3, fontFamily: kNumFont)),
                  if (conn.pinnedTag == n.tag) ...[
                    const SizedBox(height: 2),
                    Text('📌 ${AppStrings.t('node_pinned_hint')}',
                        style: TextStyle(fontSize: 9.5, color: MBColors.brandLight, fontWeight: FontWeight.w700)),
                  ] else if (isCurrent) ...[
                    const SizedBox(height: 2),
                    Text('✨ ${AppStrings.t('selected')}', style: TextStyle(fontSize: 9.5, color: MBColors.brandLight, fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ),
            // 延迟胶囊:点击=单点测速(测速中显示小环)。
            // 用 InkWell + 命中区 ≥40：这是「给单个节点测速」的唯一入口，
            // 旧实现只有 ~20px 高的裸 GestureDetector，触屏上几乎点不中。
            Material(
              color: Colors.transparent,
              child: InkWell(
              borderRadius: _latencyRadius,
              onTap: _testing ? null : () => _testOne(n),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: latencyColor.withValues(alpha: .1),
                  borderRadius: _latencyRadius,
                  border: Border.all(color: latencyColor.withValues(alpha: .25)),
                ),
                child: _testingNode.contains(n.tag)
                    ? SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.6, color: latencyColor))
                    : Text(
                        _latencyLabel(n,
                            tcpMode: conn.speedTestMode == SpeedTestMode.tcp),
                        style: TextStyle(
                            fontSize: (n.online && n.latencyMs >= 0) ? 11.5 : 9.5,
                            color: latencyColor,
                            fontFamily: (n.online && n.latencyMs >= 0)
                                ? kNumFont
                                : null,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              ),
            ),
            if (isCurrent) ...[
              const SizedBox(width: 8),
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(gradient: MBColors.brandGradient, shape: BoxShape.circle),
                child: const Icon(Icons.check, size: 11, color: Colors.white),
              ),
            ],
          ],
        ),
      ),
    );
  }
}


/// 节点懒加载列表：国家分组头（可折叠，默认折叠）+ 节点行，拍平为索引，
/// 只构建视口内可见项（680+ 节点也流畅）。点分组头折叠/展开该国节点。
/// 默认全部折叠、仅展开当前节点所在国家；搜索时强制全部展开（不藏结果）。
class _NodeListView extends StatefulWidget {
  const _NodeListView({
    required this.conn,
    required this.groups,
    required this.sortedCodes,
    required this.buildNodeRow,
    required this.searching,
  });

  final ConnectionController conn;
  final Map<String, List<ProxyNode>> groups;
  final List<String> sortedCodes;
  final Widget Function(ConnectionController, dynamic) buildNodeRow;
  /// 搜索态：为 true 时无视折叠集合，全部展开（避免命中节点被折叠头藏住）
  final bool searching;

  @override
  State<_NodeListView> createState() => _NodeListViewState();
}

class _NodeListViewState extends State<_NodeListView> {
  /// 已折叠的国家码。State 随组件位置保活，搜索/测速/刷新触发父级重建时
  /// 折叠状态不丢。默认折叠全部国家、仅展开当前节点所在国家（见 initState）。
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    // 首帧初始化折叠集合：默认折叠所有国家，只保留“当前节点所在国家”展开，
    // 让正在使用的节点可见、其余收起（长列表更清爽）。
    final currentCode =
        (widget.conn.current?.countryCode ?? '').toUpperCase();
    _collapsed
      .addAll(widget.sortedCodes.where((c) => c.toUpperCase() != currentCode));
  }

  void _toggle(String code) {
    setState(() {
      if (!_collapsed.remove(code)) _collapsed.add(code);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 搜索态：全部展开（不藏命中节点）；非搜索：按折叠集合。
    final searching = widget.searching;
    // 拍平：header 标记 + 展开的分组才追加节点行
    final entries = <dynamic>[];
    for (final code in widget.sortedCodes) {
      entries.add('__header__$code');
      if (searching || !_collapsed.contains(code)) {
        entries.addAll(widget.groups[code]!);
      }
    }
    return ListView.builder(
      // 内容不足一屏也能下拉（否则短列表在桌面上无法触发下拉刷新）
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        if (e is String && e.startsWith('__header__')) {
          final code = e.substring('__header__'.length);
          return _CountryHeader(
            code: code,
            count: widget.groups[code]!.length,
            // 搜索态视觉上全部展开，箭头也应显示展开
            collapsed: !searching && _collapsed.contains(code),
            onTap: () => _toggle(code),
          );
        }
        return widget.buildNodeRow(widget.conn, e);
      },
    );
  }
}

/// 可折叠国家分组头：旗标 + 国名 + 节点数 + 旋转箭头（点按折叠/展开）
class _CountryHeader extends StatelessWidget {
  const _CountryHeader({
    required this.code,
    required this.count,
    required this.collapsed,
    required this.onTap,
  });

  final String code;
  final int count;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        // 命中区 ≥40（审计 P2：旧实现约 34px；图标 20 + 上下 11 = 42）
        padding: const EdgeInsets.fromLTRB(24, 11, 20, 11),
        child: Row(
          children: [
            Text(regionFlag(code), style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 7),
            Expanded(
              child: Text(regionName(code),
                  style: TextStyle(
                      fontSize: 12,
                      color: MBColors.txt3,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            Text('$count ${AppStrings.t('nodes_count')}',
                style: TextStyle(
                    fontSize: 11, color: MBColors.txt3, fontFamily: kNumFont)),
            const SizedBox(width: 6),
            AnimatedRotation(
              turns: collapsed ? -0.25 : 0, // 展开↓ / 折叠→
              duration: const Duration(milliseconds: 180),
              child: Icon(Icons.keyboard_arrow_down,
                  size: 20, color: MBColors.txt3),
            ),
          ],
        ),
      ),
    );
  }
}

/// 居中但**可滚动**的内容容器：最小窗口（380×620）或超长文案（服务端下发的
/// 禁用原因等）时，用 SingleChildScrollView + minHeight 撑满视口 —— 内容居中
/// 不变，但不再抛 RenderFlex overflow，也仍然能下拉刷新。
class _ScrollableCenter extends StatelessWidget {
  const _ScrollableCenter({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: c.maxHeight.isFinite ? c.maxHeight : 0,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 16),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 节点空态：受限账号给出对应引导（到期续费 / 设备满管理·升级 / 禁用提示），
/// 正常账号给出「刷新订阅」重试。不再让到期/禁用用户看到干巴巴的「暂无节点」。
class _EmptyNodesView extends StatelessWidget {
  const _EmptyNodesView({required this.refreshing, required this.onRefresh});
  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final acc = context.watch<AccountService>();
    if (!acc.isBlocked) {
      return _ScrollableCenter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(AppStrings.t('no_nodes'),
                style: TextStyle(fontSize: 14, color: MBColors.txt3)),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: refreshing ? null : onRefresh,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                    gradient: MBColors.brandGradient,
                    borderRadius: BorderRadius.circular(12)),
                child: refreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(AppStrings.t('refresh_sub'),
                        style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      );
    }
    final status = acc.status;
    final isManageable =
        status == AccountStatus.expired ||
        status == AccountStatus.noSubscription ||
        status == AccountStatus.deviceFull;
    return _ScrollableCenter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('⛔', style: const TextStyle(fontSize: 30)),
          const SizedBox(height: 10),
          Text(acc.blockText,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: MBColors.txt2, height: 1.6)),
          const SizedBox(height: 16),
          if (isManageable)
            GestureDetector(
              onTap: () {
                if (status == AccountStatus.deviceFull) {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const DevicesPage()));
                } else {
                  mainTabIndex.value = 2; // 购买套餐
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                decoration: BoxDecoration(
                    gradient: MBColors.brandGradient,
                    borderRadius: BorderRadius.circular(12)),
                child: Text(
                  status == AccountStatus.deviceFull
                      ? AppStrings.t('manage_devices')
                      : AppStrings.t('go_purchase'),
                  style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 地区旗标（统一按码计算 emoji，任意国家可用）
String regionFlag(String code) => ProxyNode.flagEmoji(code);

/// 地区名（统一用 ProxyNode.countryNames；合法未收录码显示码本身）
String regionName(String code) =>
    ProxyNode.countryNames[code] ??
    (RegExp(r'^[A-Z]{2}$').hasMatch(code) && code != 'XX' ? code : '其他');
