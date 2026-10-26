import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/settings_store.dart';
import '../../widgets/mf_input.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// 直连名单条目类型（条目本身带前缀，展示/校验按类型区分）
enum _BypassKind {
  /// 域名后缀（裸格式，如 example.com）→ DOMAIN-SUFFIX
  suffix,

  /// 精确域名（`DOMAIN:` 前缀，如 DOMAIN:portal.example.com）→ DOMAIN
  domain,

  /// IP 段（`IP-CIDR:` 前缀，如 IP-CIDR:192.168.1.0/24）→ IP-CIDR
  cidr,
}

/// 直连名单（最小规则覆盖）：名单内的域名/IP 段一律不走代理、直连本地网络。
/// 三类条目（存在 SettingsStore['bypassDomains']，条目自带前缀区分）：
/// - 域名后缀（旧格式，如 company.com，含子域名）
/// - `IP-CIDR:` + IP 段（如 IP-CIDR:192.168.1.0/24）
/// - `DOMAIN:` + 精确域名（可选，如 DOMAIN:portal.example.com）
/// 用于：内网/公司域名、银行/支付 App 需要本地出口、某域名被错误代理等场景。
/// 更改在下次连接时生效。
class BypassPage extends StatefulWidget {
  const BypassPage({super.key});

  /// 测试注入点：替换设置读取（默认 [SettingsStore.instance.load]）。
  /// 「设置读取抛错」这条路径必须能被稳定复现（`load()` 自身无法在不碰
  /// SettingsStore 的前提下抛错），真实运行时恒为 null。
  @visibleForTesting
  static Future<Map<String, dynamic>> Function()? debugLoadOverride;

  @override
  State<BypassPage> createState() => _BypassPageState();
}

class _BypassPageState extends State<BypassPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  String? _errorText;
  List<String> _domains = [];
  bool _loaded = false;

  /// 设置读取失败时的错误文案（null = 正常）。
  /// 旧实现在读取失败时 _loaded 永远为 false，页面死在一个**没有 AppBar、
  /// 没有返回按钮**的转圈页上 —— 只能重启 App 才能离开。
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 读取设置 → 直连名单。**必须捕获异常**（旧实现只有 `.then()`，没有
  /// `catchError`，一旦抛错就永远停在没有返回入口的转圈页）。
  Future<void> _load() async {
    final load = BypassPage.debugLoadOverride ?? SettingsStore.instance.load;
    try {
      final s = await load();
      if (!mounted) return;
      setState(() {
        _domains = List<String>.from(
            (s['bypassDomains'] as List?)?.cast<String>() ?? const <String>[]);
        _loadError = null;
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = AppStrings.t('bypass_load_fail');
        _loaded = true;
      });
    }
  }

  /// 错误态「重试」：回到加载中并重新读取设置
  void _retryLoad() {
    setState(() {
      _loaded = false;
      _loadError = null;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 解析用户输入 → (规范化条目, 错误文案)。
  /// - 空输入：两者皆 null（清错误即可，不添加）；
  /// - 合法：返回规范化条目（含前缀的大写规范形），error 为 null；
  /// - 非法：entry 为 null，error 为提示（不静默吞）。
  ({String? entry, String? error}) _parseInput(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return (entry: null, error: null);
    final lower = t.toLowerCase();

    // IP 段：IP-CIDR: 前缀（大小写不敏感）
    if (lower.startsWith('ip-cidr:')) {
      final cidr = t.substring('IP-CIDR:'.length).trim();
      if (!_isValidCidr(cidr)) {
        return (entry: null, error: AppStrings.t('bypass_invalid_cidr'));
      }
      return (entry: 'IP-CIDR:$cidr', error: null);
    }

    // 精确域名：DOMAIN: 前缀（大小写不敏感）
    if (lower.startsWith('domain:')) {
      final host = _normHost(t.substring('DOMAIN:'.length),
          allowSingleLabel: true);
      if (host == null) {
        return (entry: null, error: AppStrings.t('bypass_invalid_domain'));
      }
      return (entry: 'DOMAIN:$host', error: null);
    }

    // 疑似裸 IP 段（漏了 IP-CIDR: 前缀）：明确提示，而不是当域名吞掉
    if (_looksLikeBareCidr(t)) {
      return (entry: null, error: AppStrings.t('bypass_invalid_format'));
    }

    // 域名后缀（旧格式，不变）：规范化后校验
    final host = _normHost(t, allowSingleLabel: false);
    if (host == null) {
      return (entry: null, error: AppStrings.t('bypass_invalid'));
    }
    return (entry: host, error: null);
  }

  /// 规范化域名：小写、去协议头/路径/端口/通配符前缀。
  /// [allowSingleLabel]=true 时允许单标签（如局域网主机名，供精确域名用）。
  String? _normHost(String raw, {required bool allowSingleLabel}) {
    var d = raw.trim().toLowerCase();
    if (d.isEmpty) return null;
    for (final p in ['https://', 'http://']) {
      if (d.startsWith(p)) d = d.substring(p.length);
    }
    d = d.split('/').first.split(':').first; // 去路径与端口
    if (d.startsWith('*.')) d = d.substring(2);
    if (d.startsWith('.')) d = d.substring(1);
    if (d.isEmpty) return null;
    final re = allowSingleLabel
        ? RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$')
        : RegExp(
            r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');
    if (!re.hasMatch(d)) return null; // 非法域名
    return d;
  }

  /// 是否像「裸 IP 段」（带前缀号的 IP/CIDR，但没有 IP-CIDR: 前缀）
  bool _looksLikeBareCidr(String t) {
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$').hasMatch(t)) return true;
    if (t.contains('/') &&
        RegExp(r'^[0-9a-fA-F:]+/\d{1,3}$').hasMatch(t)) {
      return true;
    }
    return false;
  }

  /// 校验 IPv4/IPv6 CIDR 段（支持 IP-CIDR:1.2.3.0/24 / fe80::/10）
  bool _isValidCidr(String cidr) {
    final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$');
    final m4 = v4.firstMatch(cidr);
    if (m4 != null) {
      for (var i = 1; i <= 4; i++) {
        if (int.parse(m4.group(i)!) > 255) return false;
      }
      return int.parse(m4.group(5)!) <= 32;
    }
    final v6 = RegExp(r'^[0-9a-fA-F:.]+/(\d{1,3})$');
    final m6 = v6.firstMatch(cidr);
    if (m6 == null) return false;
    if (!cidr.contains(':') || !(cidr.contains('::') || ':'.allMatches(cidr).length >= 2)) {
      return false;
    }
    return int.parse(m6.group(1)!) <= 128;
  }

  /// 条目类型（按前缀判定；无前缀 = 域名后缀）
  _BypassKind _kindOf(String entry) {
    final lower = entry.toLowerCase();
    if (lower.startsWith('ip-cidr:')) return _BypassKind.cidr;
    if (lower.startsWith('domain:')) return _BypassKind.domain;
    return _BypassKind.suffix;
  }

  String _kindLabel(_BypassKind k) => switch (k) {
        _BypassKind.cidr => AppStrings.t('bypass_type_cidr'),
        _BypassKind.domain => AppStrings.t('bypass_type_domain'),
        _BypassKind.suffix => AppStrings.t('bypass_type_suffix'),
      };

  Color _kindColor(_BypassKind k) => switch (k) {
        _BypassKind.cidr => MBColors.green,
        _BypassKind.domain => MBColors.amber,
        _BypassKind.suffix => MBColors.brand,
      };

  String _kindIcon(_BypassKind k) => switch (k) {
        _BypassKind.cidr => '📡',
        _BypassKind.domain => '🎯',
        _BypassKind.suffix => '🌐',
      };

  /// 是否已存在同名条目（大小写不敏感比较）
  bool _containsEntry(String entry) {
    final e = entry.toLowerCase();
    return _domains.any((d) => d.toLowerCase() == e);
  }

  Future<void> _add() async {
    final parsed = _parseInput(_input.text);
    if (parsed.error != null) {
      setState(() => _errorText = parsed.error);
      _inputFocus.requestFocus();
      return;
    }
    final entry = parsed.entry;
    if (entry == null) {
      // 空输入：按钮本身已是禁用态（视觉上明显不同）。键盘回车仍会走到这里，
      // 这时必须明确告知 —— 旧实现 setState(_errorText = null) 直接 return，
      // 用户按了回车毫无反应，不知道是自己没填还是 App 坏了。
      setState(() => _errorText = null);
      _toast(AppStrings.t('bypass_input_empty'));
      _inputFocus.requestFocus();
      return;
    }
    _input.clear();
    setState(() => _errorText = null);
    _inputFocus.unfocus();
    if (_containsEntry(entry)) {
      _toast(AppStrings.t('bypass_exists'));
      return;
    }
    setState(() => _domains.insert(0, entry));
    await _save();
  }

  Future<void> _remove(String d) async {
    setState(() => _domains.remove(d));
    await _save();
  }

  Future<void> _save() async {
    try {
      await SettingsStore.instance
          .update((s) => s['bypassDomains'] = List<String>.from(_domains));
    } catch (_) {
      // 保存失败必须提示,不能静默(用户以为已生效)
      _toast(AppStrings.t('save_failed'));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    // 只留文案：背景/圆角/浮动样式统一由 ThemeData.snackBarTheme 提供
    // （旧实现这里自己又写了一套 floating + card2，和主题重复且容易走偏）
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // AppBar **始终**渲染：无论加载中还是读取失败，用户都必须能返回
      // （旧实现把加载中的 Scaffold 写成没有 AppBar 的裸转圈页）
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('bypass_title')),
      ),
      body: SafeArea(
        child: !_loaded
            ? Center(child: CircularProgressIndicator(color: MBColors.brand))
            : _loadError != null
                ? _errorBody()
                : _body(),
      ),
    );
  }

  /// 读取失败态：看得懂的错误 + 重试入口（不是一直转圈）
  Widget _errorBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('⚠️', style: TextStyle(fontSize: 24)),
            const SizedBox(height: 10),
            Text(_loadError!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, color: MBColors.txt2, height: 1.6)),
            const SizedBox(height: 6),
            TextButton(
                onPressed: _retryLoad, child: Text(AppStrings.t('retry'))),
          ],
        ),
      ),
    );
  }

  /// 「添加」按钮：空输入时呈**禁用态**（点击无反应必须一眼可见是禁用的）。
  /// 命中区保持 48 高；禁用态用 card2 底 + txt3 文字，和可点态的品牌渐变明显不同。
  Widget _addButton() {
    final enabled = _input.text.trim().isNotEmpty;
    final radius = BorderRadius.circular(12);
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: enabled ? MBColors.brandGradient : null,
          color: enabled ? null : MBColors.card2,
          borderRadius: radius,
          border: enabled ? null : Border.all(color: MBColors.line),
        ),
        child: InkWell(
          onTap: enabled ? _add : null,
          borderRadius: radius,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.center,
            child: Text(AppStrings.t('bypass_add'),
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: enabled ? Colors.white : MBColors.txt3)),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.t('bypass_desc'),
              style: TextStyle(fontSize: 11.5, color: MBColors.txt3, height: 1.6)),
          const SizedBox(height: 12),
          // 输入行（输入框与添加按钮同高对齐，无重叠）
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    style: TextStyle(fontSize: 13.5, color: MBColors.txt),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: mfInput(hint: AppStrings.t('bypass_hint'))
                        .copyWith(errorText: _errorText),
                    // 空 ↔ 非空切换「添加」按钮的可用态，必须重建
                    onChanged: (_) => setState(() => _errorText = null),
                    onSubmitted: (_) => _add(),
                    textInputAction: TextInputAction.done,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _addButton(),
            ],
          ),
          const SizedBox(height: 6),
          // 输入格式说明（三种条目类型示例）
          Text(AppStrings.t('bypass_help'),
              style:
                  TextStyle(fontSize: 10, color: MBColors.txt3, height: 1.6)),
          const SizedBox(height: 12),
          Text(
              '${AppStrings.t('bypass_count', {'n': '${_domains.length}'})}'
              ' · ${AppStrings.t('bypass_effect')}',
              style: TextStyle(fontSize: 11, color: MBColors.txt3)),
          const SizedBox(height: 8),
          Expanded(
            child: _domains.isEmpty
                ? Center(
                    child: Text(AppStrings.t('bypass_empty'),
                        style: TextStyle(
                            fontSize: 12.5, color: MBColors.txt3)))
                : ListView.separated(
                    itemCount: _domains.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final d = _domains[i];
                      final kind = _kindOf(d);
                      final color = _kindColor(kind);
                      return Container(
                        // 垂直内边距 3（+ 1px 边框）：给行尾 40×40 的删除命中区
                        // 留出空间，行整体视觉高度仍是 48
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 3),
                        height: 48,
                        decoration: BoxDecoration(
                            color: MBColors.card,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: MBColors.line)),
                        child: Row(
                          children: [
                            Text(_kindIcon(kind),
                                style: const TextStyle(fontSize: 13)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(d,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      color: MBColors.txt,
                                      fontWeight: FontWeight.w500)),
                            ),
                            const SizedBox(width: 8),
                            // 类型小标签（后缀 / 精确域名 / IP 段）
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: .13),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(_kindLabel(kind),
                                  style: TextStyle(
                                      fontSize: 9.5,
                                      color: color,
                                      fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 8),
                            // 删除是破坏性操作：命中区至少 40×40（视觉仍是 30×30），
                            // 并用 InkWell 给出按压反馈（旧实现 GestureDetector 无反馈）
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => _remove(d),
                                borderRadius: BorderRadius.circular(9),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                      minWidth: 40, minHeight: 40),
                                  child: Center(
                                    child: Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                          color: MBColors.red
                                              .withValues(alpha: .1),
                                          borderRadius:
                                              BorderRadius.circular(9)),
                                      child: Icon(Icons.close,
                                          size: 15, color: MBColors.red),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
