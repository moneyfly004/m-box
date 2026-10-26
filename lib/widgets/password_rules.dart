import 'package:flutter/material.dart';

import '../core/services/password_policy.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// 新密码「实时规则清单」：随输入逐项打勾（绿✓/灰·），
/// 让用户在点提交前就知道密码差在哪 —— 解决「点了重置没反应」的实际
/// 根因：密码不达标时只有一闪而过的底部 SnackBar，被键盘挡住就像没反应。
/// 直接监听 TextEditingController（ValueListenable），父组件零额外接线。
class PasswordRuleHints extends StatelessWidget {
  const PasswordRuleHints({super.key, required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final pwd = value.text;
        final lenOk = pwd.length >= 8;
        final kinds = PasswordPolicy.kindsOf(pwd);
        final kindsOk = kinds >= 3;
        return Padding(
          padding: const EdgeInsets.only(left: 2, top: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _rule(lenOk, AppStrings.t('pwd_rule_len')),
              const SizedBox(height: 3),
              _rule(kindsOk,
                  AppStrings.t('pwd_rule_kinds', {'n': '$kinds'})),
            ],
          ),
        );
      },
    );
  }

  Widget _rule(bool ok, String text) {
    return Row(
      children: [
        Icon(ok ? Icons.check_circle : Icons.circle_outlined,
            size: 12, color: ok ? MBColors.green : MBColors.txt3),
        const SizedBox(width: 5),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 10.5,
                  height: 1.4,
                  color: ok ? MBColors.green : MBColors.txt3)),
        ),
      ],
    );
  }
}
