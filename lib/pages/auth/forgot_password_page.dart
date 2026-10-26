import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/api_client.dart';
import '../../l10n/app_strings.dart';
import '../../core/api/endpoints.dart';
import '../../core/services/password_policy.dart';
import '../../theme/app_theme.dart';
import '../../widgets/password_rules.dart';

/// 找回密码（设计稿 08）：邮箱验证码两步重置。
/// 校验反馈三层：新密码下方实时规则清单（输入即打勾）+ 按钮上方常驻
/// 红字错误（不随 SnackBar 消失，键盘挡不住）+ 底部 SnackBar —— 修复
/// 「密码不达标时点重置像没反应」的反馈缺失。
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();

  bool _obscure = true;
  bool _sending = false;
  bool _codeSent = false;
  int _countdown = 0;
  Timer? _timer;
  bool _loading = false;

  /// 最近一次点「重置密码」的校验错误：常驻按钮上方（红字），
  /// 用户修改任意输入后清除
  String? _formError;

  @override
  void initState() {
    super.initState();
    for (final c in [_email, _code, _newPassword, _confirm]) {
      c.addListener(_clearFormError);
    }
  }

  void _clearFormError() {
    if (_formError != null && mounted) setState(() => _formError = null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_email, _code, _newPassword, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!looksLikeEmail(email)) return _toast(AppStrings.t('email_reg_invalid'));
    setState(() => _sending = true);
    try {
      await ApiClient.instance.post(Endpoints.forgotPassword, data: {'email': email});
      if (!mounted) return; // 等待期间页面已退出
      _toast(AppStrings.t('reset_code_sent'));
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

  /// 校验失败统一出口：红字常驻按钮上方 + SnackBar 双通道提示
  void _fail(String msg) {
    setState(() => _formError = msg);
    _toast(msg);
  }

  Future<void> _reset() async {
    // 就地校验（与后端同规则），失败原因常驻显示，绝不「点了没反应」
    if (!looksLikeEmail(_email.text)) {
      return _fail(AppStrings.t('email_reg_invalid'));
    }
    if (_code.text.trim().length != 6) {
      return _fail(AppStrings.t('code_required'));
    }
    final pwdErr = PasswordPolicy.errorFor(_newPassword.text);
    if (pwdErr != null) return _fail(pwdErr);
    if (_newPassword.text != _confirm.text) {
      return _fail(AppStrings.t('pwd_mismatch'));
    }
    setState(() {
      _formError = null;
      _loading = true;
    });
    try {
      await ApiClient.instance.post(Endpoints.resetPassword, data: {
        'email': _email.text.trim(),
        'verification_code': _code.text.trim(),
        'new_password': _newPassword.text,
      });
      _toast(AppStrings.t('pwd_reset'));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      // 服务端拒绝（验证码错误/过期等）：同样常驻显示真实原因
      if (mounted) _fail(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
        title: Text(AppStrings.t('forgot_title')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('login_title'), style: TextStyle(color: MBColors.brandLight, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, compact ? 6 : 12, 24, compact ? 16 : 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 步骤条：反映真实进度 —— 验证码**真的发出去之前**第 1 步不算完成
              // （旧实现把第 1 步硬编码 done:true，一进页面就打绿勾，用户在还
              // 没收到验证码时被误导成「这步已经过了」）。当前所处步骤高亮，
              // 未开始的步骤置灰（三态可分辨）。
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Step(
                    key: const ValueKey('fp_step_verify'),
                    done: _codeSent,
                    current: !_codeSent,
                    no: _codeSent ? '✓' : '1',
                    label: AppStrings.t('step_verify'),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    // 连接线跟随第 1 步的完成状态（绿 = 已通过验证码这一步）
                    child: SizedBox(
                        width: 26,
                        height: 1,
                        child: ColoredBox(
                            color: _codeSent ? MBColors.green : MBColors.line2)),
                  ),
                  _Step(
                    key: const ValueKey('fp_step_pwd'),
                    done: false,
                    current: _codeSent,
                    no: '2',
                    label: AppStrings.t('step_new_pwd'),
                  ),
                ],
              ),
              SizedBox(height: compact ? 16 : 26),
              _field(AppStrings.t('email_label'), _email, hint: AppStrings.t('email_reg_hint')),
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
                              decoration: BoxDecoration(gradient: MBColors.brandGradient, borderRadius: BorderRadius.circular(12)),
                              child: Text(_sending ? AppStrings.t('sending') : AppStrings.t('send_code'),
                                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ),
                  )),
              if (_codeSent) ...[
                const SizedBox(height: 6),
                Text(AppStrings.t('identity_ok'), style: TextStyle(fontSize: 10.5, color: MBColors.green, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 12),
              _field(AppStrings.t('new_pwd'), _newPassword,
                  hint: PasswordPolicy.hint, obscure: _obscure, suffix: _eyeBtn()),
              // 实时规则清单：输入即打勾，提交前就知道差哪一条
              PasswordRuleHints(controller: _newPassword),
              const SizedBox(height: 12),
              _field(AppStrings.t('confirm_pwd'), _confirm, hint: AppStrings.t('confirm_pwd_hint'), obscure: _obscure, suffix: _eyeBtn()),
              const SizedBox(height: 14),
               Text(AppStrings.t('forgot_tip'),
                  style: TextStyle(fontSize: 11, color: MBColors.txt3, height: 1.7)),
              // 校验失败原因常驻此处（红字），键盘挡不住、不会一闪而过
              if (_formError != null) ...[
                const SizedBox(height: 10),
                Text('⚠ $_formError',
                    style: TextStyle(
                        fontSize: 12, color: MBColors.red, height: 1.5,
                        fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 22),
              MBPrimaryButton(label: AppStrings.t('reset_pwd_btn'), loading: _loading, onPressed: _loading ? null : _reset),
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

/// 步骤条单元格：三态 —— 已完成（绿✓）/ 当前步骤（品牌色高亮）/ 未开始（置灰）。
class _Step extends StatelessWidget {
  const _Step({
    super.key,
    required this.done,
    required this.no,
    required this.label,
    this.current = false,
  });
  final bool done;
  final bool current;
  final String no;
  final String label;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final Color bg;
    if (done) {
      color = MBColors.green;
      bg = MBColors.green.withValues(alpha: .18);
    } else if (current) {
      color = MBColors.brandLight;
      bg = MBColors.brand.withValues(alpha: .18);
    } else {
      // 未开始：弱化，与「当前步骤」一眼可分
      color = MBColors.txt3;
      bg = MBColors.txt3.withValues(alpha: .12);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(no, style: TextStyle(fontSize: 10.5, color: color, fontFamily: kNumFont, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
