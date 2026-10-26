import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 表单校验失败的**常驻**提示（红字 + ⚠），插在提交按钮上方。
///
/// 为什么不用 snackbar：手机端键盘弹出会挡住 snackbar，而且只显示 2~4 秒 ——
/// 用户看到的现象是「点了没反应」，然后要重填一遍。忘记密码页已经改成这种常驻
/// 提示（并留有注释说明），注册页/修改密码页当时还在用 `return _toast(...)`，
/// 现在统一走这个组件。
///
/// 用法：
/// ```dart
/// if (_formError != null) MBFormError(message: _formError!),
/// ```
class MBFormError extends StatelessWidget {
  const MBFormError({super.key, required this.message, this.margin});

  /// 已本地化的错误文案
  final String message;

  /// 自定义外边距（默认上方 10、下方 0）
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin ?? const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('⚠',
              style: TextStyle(fontSize: 12, color: MBColors.red)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    fontSize: 12,
                    color: MBColors.red,
                    height: 1.5,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
