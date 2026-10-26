import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/api/endpoints.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/login_lock.dart';
import '../../l10n/app_strings.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import 'forgot_password_page.dart';
import 'register_page.dart';

/// 登录页（设计稿 01）
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const _autoLoginKey = 'mbox_auto_login';

  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _autoLogin = true;
  bool _loading = false;

  /// 限流冷却截止时间（服务端 429 后本地点亮，用于按钮倒计时）。
  ///
  /// 为什么要有：后端 `/auth/login` 是**按 IP 每分钟 10 次**限流，登录页反复点
  /// 「登录」正好让计数器一直不滑出窗口 —— 客户看到的「怎么都登不上」有一多半
  /// 是这么来的。这里冷却期内不再发请求，并在按钮上如实显示还要等多久。
  DateTime? _cooldownUntil;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    // 恢复「自动登录」开关状态（与 SessionState.restore 联动）
    SharedPreferences.getInstance()
        .then((p) => p.getBool(_autoLoginKey))
        .then((v) {
      if (mounted && v != null) setState(() => _autoLogin = v);
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 自动登录开关：关闭后下次启动不自动恢复登录态
  static Future<void> setAutoLogin(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_autoLoginKey, v);
  }

  /// 冷却剩余秒数（0 = 不在冷却中）
  int get _cooldownLeft {
    final until = _cooldownUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inSeconds;
    return left > 0 ? left : 0;
  }

  void _startCooldown(Duration d) {
    _cooldownUntil = DateTime.now().add(d);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_cooldownLeft <= 0) {
        t.cancel();
        _cooldownUntil = null;
      }
      setState(() {});
    });
    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    if (_account.text.trim().isEmpty || _password.text.isEmpty) {
      _toast(AppStrings.t('input_account_pwd'));
      return;
    }
    // 冷却期内不再发请求：继续点只会让服务端限流计数一直满格
    final left = _cooldownLeft;
    if (left > 0) {
      _toast(AppStrings.t('rate_limit_cooldown', {'n': '$left'}));
      return;
    }
    setState(() => _loading = true);
    try {
      await AuthService.instance.login(_account.text, _password.text);
      if (mounted) context.read<SessionState>().setLoggedIn(true);
    } catch (e) {
      final msg = ApiClient.errorMsg(e);
      // ① 限流 / 锁定：服务端 429（按 IP 限流 或 失败次数锁定）——必须专门提示：
      //    这两种情况下密码是对的却登不进，用户只会反复点，反而让限流一直不解除。
      final limit = parseRateLimit(e, path: Endpoints.login);
      if (limit != null) {
        _startCooldown(limit.cooldown);
        _showRateLimitDialog(limit);
        return;
      }
      // ② 账号被禁用：后端登录返回 403「账户已被禁用…」——弹窗明确提示，
      // 而不是普通 toast（用户需要知道不是密码错、且无法自助解决）
      final m = msg.toLowerCase();
      if (msg.contains('禁用') ||
          msg.contains('禁止') ||
          m.contains('disabled') ||
          m.contains('banned')) {
        _showDisabledDialog(msg);
      } else {
        _toast(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 限流/锁定提示：服务端原文 + 剩余等待 + 「怎么办」（等待 or 换网络）
  void _showRateLimitDialog(RateLimitInfo info) {
    if (!mounted) return;
    final wait = formatRemaining(info.retryAfter ?? Duration.zero);
    final body = [
      AppStrings.t('rate_limit_server', {'msg': info.message}),
      info.isAccountLock
          ? AppStrings.t('rate_limit_hint_lock')
          : AppStrings.t('rate_limit_hint_ip'),
      if (wait.isNotEmpty) AppStrings.t('rate_limit_wait', {'time': wait}),
    ].join('\n\n');
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: MBColors.card2,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18))),
        title: Text(AppStrings.t('rate_limit_title'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(body,
            style: TextStyle(fontSize: 13, color: MBColors.txt2, height: 1.7)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ForgotPasswordPage()));
            },
            child: Text(AppStrings.t('forgot_password')),
          ),
          // 锁定是按「IP(+账号)」算的：换了网络（WiFi ↔ 移动数据）本来就该能立刻登录，
          // 所以给一个显式出口，而不是让用户对着倒计时干等。
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              _cooldownTimer?.cancel();
              _cooldownUntil = null;
              if (mounted) setState(() {});
              _login();
            },
            child: Text(AppStrings.t('rate_limit_retry_now')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.t('ok_btn')),
          ),
        ],
      ),
    );
  }

  void _showDisabledDialog(String msg) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MBColors.card2,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
        title: Text(AppStrings.t('account_disabled_title'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(msg,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: MBColors.txt2, height: 1.7)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('ok_btn')),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.height < 820;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: compact ? 32 : 70),
              Center(
                child: Container(
                  width: compact ? 60 : 76,
                  height: compact ? 60 : 76,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: MBColors.brand.withValues(alpha: .35), blurRadius: 40, offset: Offset(0, 16)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset('assets/mbox-logo.png', width: compact ? 60 : 76, height: compact ? 60 : 76),
                  ),
                ),
              ),
              SizedBox(height: compact ? 12 : 18),
              Center(
                child: Text(AppStrings.t('app_name'),
                    style: TextStyle(fontSize: compact ? 24 : 28, fontWeight: FontWeight.w700, letterSpacing: 1.6)),
              ),
              const SizedBox(height: 6),
               Center(
                child: Text(AppStrings.t('slogan'),
                    style: TextStyle(fontSize: 12.5, color: MBColors.txt3, letterSpacing: 3)),
              ),
              SizedBox(height: compact ? 24 : 44),
              _Field(
                label: AppStrings.t('account_label'),
                controller: _account,
                hint: AppStrings.t('account_hint'),
                action: TextInputAction.next,
                onSubmitted: (_) => FocusScope.of(context).nextFocus(),
              ),
              const SizedBox(height: 12),
              _Field(
                label: AppStrings.t('password_label'),
                controller: _password,
                hint: AppStrings.t('password_hint'),
                obscure: _obscure,
                action: TextInputAction.done,
                onSubmitted: (_) => _loading ? null : _login(),
                trailing: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      size: 20, color: MBColors.txt3),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                   Text(AppStrings.t('auto_login'), style: TextStyle(fontSize: 13, color: MBColors.txt2)),
                  const Spacer(),
                  Switch(
                    value: _autoLogin,
                    onChanged: (v) {
                      setState(() => _autoLogin = v);
                      setAutoLogin(v);
                    },
                  ),
                ],
              ),
              SizedBox(height: compact ? 10 : 16),
              MBPrimaryButton(
                label: _cooldownLeft > 0
                    ? AppStrings.t('rate_limit_cooldown', {'n': '$_cooldownLeft'})
                    : AppStrings.t('login_button'),
                loading: _loading,
                onPressed: _loading ? null : _login,
              ),
              SizedBox(height: compact ? 16 : 26),
              // 两个入口（注册 / 忘记密码）的命中区撑到 44px：旧实现只有一行
              // 13.5px 的文字（实际可点高度 ≈18px），手机端很难点中
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _LinkTap(
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const RegisterPage())),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: AppStrings.t('no_account'), style: TextStyle(fontSize: 13.5, color: MBColors.txt2)),
                      TextSpan(text: AppStrings.t('register'), style: TextStyle(fontSize: 13.5, color: MBColors.brandLight, fontWeight: FontWeight.w600)),
                    ])),
                  ),
                  Container(width: 1, height: 12, margin: const EdgeInsets.symmetric(horizontal: 18), color: MBColors.line2),
                  _LinkTap(
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ForgotPasswordPage())),
                    child: Text(AppStrings.t('forgot_password'), style: TextStyle(fontSize: 13.5, color: MBColors.txt2)),
                  ),
                ],
              ),
              SizedBox(height: compact ? 16 : 40),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.trailing,
    this.action,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Widget? trailing;
  final TextInputAction? action;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(label, style:  TextStyle(fontSize: 12.5, color: MBColors.txt2, fontWeight: FontWeight.w500)),
        ),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 15),
          cursorColor: MBColors.brand,
          textInputAction: action,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(hintText: hint, suffixIcon: trailing),
        ),
      ],
    );
  }
}

/// 登录页底部文字入口：视觉不变，但保证 ≥44px 的命中高度 + 按压反馈。
class _LinkTap extends StatelessWidget {
  const _LinkTap({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Center(widthFactor: 1, heightFactor: 1, child: child),
        ),
      ),
    );
  }
}
