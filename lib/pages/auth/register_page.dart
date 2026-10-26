import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_strings.dart';
import '../../core/api/api_client.dart';
import '../../core/api/endpoints.dart';
import '../../core/services/password_policy.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_form_error.dart';
import '../../widgets/password_rules.dart';

/// 注册页（设计稿 07）：邮箱 + 验证码（60s 倒计时）+ 用户名 + 密码 + 邀请码
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  /// 测试用：替换真实的外呼（widget 测试里 launchUrl 会挂住不返回）
  static Future<bool> Function(String url)? debugOpenUrlOverride;

  /// 用户协议 / 隐私政策入口。App 内没有内置正文，统一打开官网（与设置页
  /// 页脚展示的同一个域名）—— 旧实现这两个「链接」只是彩色文字，点了没有任何
  /// 反应（用户以为点了没生效）。
  static const docsUrl = 'https://dy.moneyfly.top';

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _invite = TextEditingController();

  bool _obscure = true;

  /// 同意条款默认**未勾选**：默认勾选会让「必须同意」的校验形同虚设（用户从未
  /// 做出同意表示，却已经完成注册）—— 合规风险。未勾选时点注册会明确提示。
  bool _agreed = false;

  /// 未勾选就点注册时的常驻提示（toast 只闪一下，容易被忽略）
  /// 校验/接口失败原因：**常驻**在按钮上方（审计 P2：注册页和改密码页当时只
  /// 靠 `return _toast(...)`，手机端键盘会挡住 snackbar，用户看到的是「点了没反应」）
  String? _formError;

  late final TapGestureRecognizer _tosTap = TapGestureRecognizer()
    ..onTap = () => _openDocs();
  late final TapGestureRecognizer _privacyTap = TapGestureRecognizer()
    ..onTap = () => _openDocs();

  Future<void> _openDocs() async {
    try {
      final open = RegisterPage.debugOpenUrlOverride ??
          (String u) => launchUrl(Uri.parse(u),
              mode: LaunchMode.externalApplication);
      await open(RegisterPage.docsUrl);
    } catch (_) {
      if (mounted) _toast(AppStrings.t('open_link_failed'));
    }
  }
  bool _sending = false;
  bool _codeSent = false;
  int _countdown = 0;
  Timer? _timer;
  bool _loading = false;

  @override
  void dispose() {
    _tosTap.dispose();
    _privacyTap.dispose();
    _timer?.cancel();
    for (final c in [_email, _code, _username, _password, _confirm, _invite]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!looksLikeEmail(email)) {
      _toast(AppStrings.t('email_invalid'));
      return;
    }
    setState(() => _sending = true);
    try {
      await ApiClient.instance.post(Endpoints.sendCode, data: {'type': 'email', 'email': email});
      if (!mounted) return; // 等待期间页面已退出
      _toast(AppStrings.t('code_sent_email'));
      setState(() {
        _codeSent = true;
        _countdown = 60;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel(); // 页面销毁后停止倒计时
        if (_countdown <= 1) {
          t.cancel();
          setState(() => _countdown = 0);
        } else {
          setState(() => _countdown--);
        }
      });
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _register() async {
    if (_username.text.trim().length < 4) {
      return _fail(AppStrings.t('username_short'));
    }
    // 与后端同规则校验新密码（长度 + 四类字符至少三种）
    final pwdErr = PasswordPolicy.errorFor(_password.text);
    if (pwdErr != null) return _fail(pwdErr);
    if (_password.text != _confirm.text) {
      return _fail(AppStrings.t('pwd_mismatch'));
    }
    if (!looksLikeEmail(_email.text)) {
      return _fail(AppStrings.t('email_invalid'));
    }
    // 未同意协议时绝不发起注册请求，并把原因常驻在按钮上方
    if (!_agreed) return _fail(AppStrings.t('agree_required'));
    setState(() {
      _formError = null;
      _loading = true;
    });
    try {
      await ApiClient.instance.post(Endpoints.register, data: {
        'username': _username.text.trim(),
        'email': _email.text.trim(),
        'password': _password.text,
        'verification_code': _code.text.trim(),
        if (_invite.text.trim().isNotEmpty) 'invite_code': _invite.text.trim(),
      });
      _toast(AppStrings.t('registered'));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _fail(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 校验/接口失败：常驻在按钮上方（清掉上一次的提示）
  void _fail(String msg) {
    if (!mounted) return;
    setState(() => _formError = msg);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.height < 820;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('register_title')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('login_title'), style: TextStyle(color: MBColors.brandLight, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, compact ? 4 : 8, 24, compact ? 16 : 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
               Text(AppStrings.t('join_mbox'),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: MBColors.txt)),
              const SizedBox(height: 4),
               Text(AppStrings.t('join_tip'),
                  style: TextStyle(fontSize: 11.5, color: MBColors.txt3)),
              SizedBox(height: compact ? 14 : 24),
              _field(AppStrings.t('email_label'), _email, hint: AppStrings.t('email_hint')),
              const SizedBox(height: 12),
              _field(AppStrings.t('code_label'), _code,
                  hint: AppStrings.t('code_hint'),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  suffix: SizedBox(
                    width: 104,
                    height: 48,
                    child: _countdown > 0
                        ? Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: MBColors.card,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: MBColors.line2),
                            ),
                            child: Text('$_countdown${AppStrings.t('resend_in')}',
                                style:  TextStyle(fontSize: 12, color: MBColors.txt3, fontFamily: kNumFont)),
                          )
                        : GestureDetector(
                            onTap: _sending ? null : _sendCode,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                gradient: MBColors.brandGradient,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(_sending ? AppStrings.t('sending') : AppStrings.t('send_code'),
                                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ),
                  )),
              if (_codeSent) ...[
                const SizedBox(height: 6),
                Text(AppStrings.t('code_sent'),
                    style: TextStyle(fontSize: 10.5, color: MBColors.green, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 12),
              _field(AppStrings.t('username_label'), _username, hint: AppStrings.t('username_hint')),
              const SizedBox(height: 12),
              _field(AppStrings.t('password_label'), _password, hint: AppStrings.t('new_pwd_hint'), obscure: _obscure, suffix: _eyeBtn()),
              PasswordRuleHints(controller: _password),
              const SizedBox(height: 12),
              _field(AppStrings.t('confirm_pwd'), _confirm, hint: AppStrings.t('confirm_pwd_hint'), obscure: _obscure, suffix: _eyeBtn()),
              const SizedBox(height: 12),
              _field(AppStrings.t('invite_label'), _invite, hint: AppStrings.t('invite_hint')),
              const SizedBox(height: 14),
              // 同意条款：整行都可点（旧实现只有 18×18 的小方块可点，手指/鼠标
              // 都很难命中），文案走 l10n，两个「链接」真的能打开（旧实现是死的）
              // 勾选整行可点，命中区 ≥44 且用 InkWell 给按压反馈 ——
              // 旧实现只有 18×18 的小方块能点，手指/鼠标都很难命中
              Material(
                color: Colors.transparent,
                child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() {
                  _agreed = !_agreed;
                  if (_agreed) _formError = null;
                }),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  child: Row(
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          gradient: _agreed ? MBColors.brandGradient : null,
                          color: _agreed ? null : MBColors.card,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: _agreed ? Colors.transparent : MBColors.line2),
                        ),
                        child: _agreed
                            ? const Icon(Icons.check, size: 12, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text.rich(TextSpan(children: [
                          TextSpan(
                              text: AppStrings.t('agree_prefix'),
                              style: TextStyle(fontSize: 11.5, color: MBColors.txt2)),
                          TextSpan(
                              text: AppStrings.t('settings_tos'),
                              recognizer: _tosTap,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: MBColors.brandLight,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.underline)),
                          TextSpan(
                              text: AppStrings.t('agree_and'),
                              style: TextStyle(fontSize: 11.5, color: MBColors.txt2)),
                          TextSpan(
                              text: AppStrings.t('settings_privacy_policy'),
                              recognizer: _privacyTap,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: MBColors.brandLight,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.underline)),
                        ])),
                      ),
                    ],
                  ),
                  ),
                ),
                ),
              ),
              const SizedBox(height: 22),
              // 校验/接口失败原因常驻在按钮上方（键盘挡不住、不会一闪而过）
              if (_formError != null) MBFormError(message: _formError!),
              if (_formError != null) const SizedBox(height: 10),
              MBPrimaryButton(label: AppStrings.t('register_btn'), loading: _loading, onPressed: _loading ? null : _register),
            ],
          ),
        ),
      ),
    );
  }

  Widget _eyeBtn() => IconButton(
        icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 19, color: MBColors.txt3),
        onPressed: () => setState(() => _obscure = !_obscure),
      );

  Widget _field(String label, TextEditingController c,
      {required String hint, bool obscure = false, Widget? suffix,
      List<TextInputFormatter>? inputFormatters}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(label, style:  TextStyle(fontSize: 12.5, color: MBColors.txt2, fontWeight: FontWeight.w500)),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: c,
                obscureText: obscure,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 15),
                cursorColor: MBColors.brand,
                inputFormatters: inputFormatters,
                decoration: InputDecoration(hintText: hint),
              ),
            ),
            if (suffix != null) ...[const SizedBox(width: 10), suffix],
          ],
        ),
      ],
    );
  }
}
