import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_strings.dart';
import '../../core/services/order_service.dart';
import '../../theme/app_theme.dart';

/// 支付二维码弹窗：渲染二维码 + 后台静默轮询订单状态。
/// 手机端对支付宝额外提供跳转 App 按钮（同机无法自扫屏幕）；桌面端仅二维码。
class PaymentQrDialog extends StatefulWidget {
  const PaymentQrDialog({
    super.key,
    required this.qrContent,
    required this.orderNo,
    required this.amount,
    required this.methodName,
    this.onPaid,
  });

  final String qrContent;
  final String orderNo;
  final double amount;
  final String methodName;
  final VoidCallback? onPaid;

  /// 测试用：把轮询超时缩到几秒，验证「已停止自动查询」提示真的会出现
  static int? debugTimeoutSecsOverride;

  @override
  State<PaymentQrDialog> createState() => _PaymentQrDialogState();
}

class _PaymentQrDialogState extends State<PaymentQrDialog> with WidgetsBindingObserver {
  static const int _timeoutSecs = 900; // 轮询超时：真实 15 分钟，与二维码有效期对齐
  static const int _pollIntervalMs = 3000; // 与网站端一致；后端每次查询会实时向网关查单，勿过密

  int get _timeout => PaymentQrDialog.debugTimeoutSecsOverride ?? _timeoutSecs;
  /// 超时用「轮询次数」而不是墙上时钟：周期是固定 3s，次数 × 周期 就是有效等待
  /// 时长；好处是确定性（可测）、App 挂起时不会因为时钟跳跃而提前停止查询。
  int get _timeoutTicks => (_timeout * 1000 / _pollIntervalMs).ceil();
  int _ticks = 0;

  bool _zoom = false;
  bool _polling = true; // 是否仍在轮询（超时/终态后置 false）
  bool _timedOut = false; // 轮询超时：必须让用户看见，否则会一直盯着不再被查询的二维码
  String? _closedStatus; // 后端返回 cancelled / expired：原因要留在界面上（toast 只闪 2 秒）
  bool _launching = false; // 跳转按钮防连点
  Timer? _timer;
  bool _pollInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling(notify: false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// 从支付宝/浏览器切回 App 时立即补查一次，不必等下个轮询周期。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _polling && mounted) {
      _pollOnce();
    }
  }

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// 支付宝当面付/易支付收银台等可唤起；微信 NATIVE(weixin://) 只能扫码、USDT 是地址码，均不跳转。
  bool get _launchable {
    final s = widget.qrContent.trim().toLowerCase();
    if (s.startsWith('weixin://') || s.startsWith('wxp://') || s.startsWith('usdt:')) {
      return false;
    }
    return s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('alipay://') ||
        s.startsWith('alipays://');
  }

  /// 启动/重启后台静默轮询：立即查一次（不等首个间隔），再周期节流轮询。
  void _startPolling({bool notify = true}) {
    _timer?.cancel();
    _pollInFlight = false;
    _polling = true;
    _timedOut = false;
    _closedStatus = null;
    _ticks = 0;
    if (notify && mounted) setState(() {});
    _pollOnce();
    _timer = Timer.periodic(const Duration(milliseconds: _pollIntervalMs), (_) {
      if (!mounted || !_polling) return;
      _ticks++;
      if (_ticks >= _timeoutTicks) {
        _timer?.cancel();
        // 旧实现在这里直接 return：界面毫无变化，用户以为还在查单，可能对着一个
        // 已经不再被查询的二维码付款。现在给出明确的「已停止查询」状态。
        setState(() {
          _polling = false;
          _timedOut = true;
        });
        return;
      }
      _pollOnce();
    });
  }

  /// 查一次订单状态：paid → 回调并关闭；cancelled/expired → 停轮询并提示；
  /// pending / 瞬时网络错误 → 静默，下个周期继续。
  Future<void> _pollOnce() async {
    if (!_polling || !mounted || _pollInFlight) return;
    _pollInFlight = true;
    try {
      final s = await OrderService.instance.status(widget.orderNo);
      if (!mounted) return;
      if (s.isPaid) {
        _timer?.cancel();
        _polling = false;
        widget.onPaid?.call();
        Navigator.of(context).pop(true);
        return;
      }
      if (s.status == 'cancelled' || s.status == 'expired') {
        _timer?.cancel();
        _polling = false;
        final label = s.status == 'cancelled'
            ? AppStrings.t('cancelled')
            : AppStrings.t('expired');
        // 终态要**留在界面上**（toast 只闪 2 秒，用户从支付 App 切回来就看不到了）
        setState(() => _closedStatus = label);
        _snack(AppStrings.t('order_status_tip', {'status': label}));
      }
    } catch (_) {
      // 瞬时网络错误：静默，下个周期重试
    } finally {
      _pollInFlight = false;
    }
  }

  /// 手机端拉起支付 App
  Future<void> _openPayApp() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      final raw = widget.qrContent.trim();
      // 支付宝当面付二维码包成 App 深链直接唤起支付宝（与网站端一致），比开网页再跳更可靠
      final target = raw.toLowerCase().contains('qr.alipay.com')
          ? 'alipays://platformapi/startapp?saId=10000007&qrcode=${Uri.encodeComponent(raw)}'
          : raw;
      final ok = await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
      if (!ok && mounted) _snack(AppStrings.t('open_pay_failed'));
    } catch (_) {
      if (mounted) _snack(AppStrings.t('open_pay_failed'));
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 轮询状态行：等待中 / 已超时停止 / 订单终态。
  /// 三个状态都必须**看得见** —— 旧实现下这三种情况界面完全一样（没有任何提示），
  /// 用户无法判断这个二维码还在不在被查询。
  Widget _statusRow() {
    final Color color;
    final String text;
    var spinner = false;
    if (_closedStatus != null) {
      color = MBColors.red;
      text = AppStrings.t('order_status_tip', {'status': _closedStatus!});
    } else if (_timedOut) {
      color = MBColors.amber;
      text = AppStrings.t('pay_poll_stopped');
    } else {
      color = Colors.white70;
      text = AppStrings.t('pay_waiting');
      spinner = true;
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (spinner) ...[
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10.5, color: color)),
        ),
      ],
    );
  }

  /// 底部两个操作按钮的统一高度。
  /// 旧实现左侧 OutlinedButton 靠 padding 撑出 ~42 高、右侧容器写死 height:50，
  /// 并排看两个按钮明显不等高。
  static const double _actionBtnHeight = 48;

  @override
  Widget build(BuildContext context) {
    final showLaunch = _isMobile && _launchable;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 26),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: const LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Color(0xFF171E2E), Color(0xFF10141F)]),
          border: Border.all(color: MBColors.line2),
        ),
        // 窄窗口（最小 380×620）下「二维码 196 + 金额 + 跳转按钮 + 底部按钮」
        // 可能超过可视高度：内容整体可滚动，绝不抛 RenderFlex overflow。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppStrings.t('pay_with_method', {'method': widget.methodName}),
                  style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: Colors.white)),
              const SizedBox(height: 3),
              Text('${widget.methodName.toUpperCase()} · SECURE PAYMENT',
                  style: const TextStyle(fontSize: 10, color: Colors.white60, letterSpacing: 1.4)),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => setState(() => _zoom = !_zoom),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: _zoom ? 250 : 196,
                  height: _zoom ? 250 : 196,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(17),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .5), blurRadius: 30)],
                  ),
                  child: QrImageView(
                    data: widget.qrContent,
                    version: QrVersions.auto,
                    size: _zoom ? 228 : 174,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF111111)),
                    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF111111)),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(AppStrings.t('qr_tap_zoom'),
                  style: const TextStyle(fontSize: 10, color: Colors.white60)),
              const SizedBox(height: 10),
              _statusRow(),
              const SizedBox(height: 8),
              Text.rich(TextSpan(children: [
                TextSpan(text: '¥',
                    style: const TextStyle(fontSize: 15, color: Colors.white)),
                TextSpan(text: formatPrice(widget.amount),
                    style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w700, fontFamily: kNumFont, color: Colors.white)),
              ])),
              const SizedBox(height: 5),
              GestureDetector(
                onTap: () {
                  // 剪贴板无需等待，直接提示
                  Clipboard.setData(ClipboardData(text: widget.orderNo));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(AppStrings.t('order_copied')), duration: Duration(seconds: 1)),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text('${AppStrings.t('order_no')} ${widget.orderNo}',
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: kNumFont, letterSpacing: .5)),
                    ),
                    const SizedBox(width: 5),
                    const Icon(Icons.copy, size: 12, color: Colors.white70),
                  ],
                ),
              ),
              // 手机端一键拉起支付 App
              if (showLaunch) ...[
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: _launching ? null : _openPayApp,
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(gradient: MBColors.brandGradient, borderRadius: BorderRadius.circular(14)),
                    alignment: Alignment.center,
                    child: _launching
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.open_in_new, size: 16, color: Colors.white),
                              const SizedBox(width: 7),
                              Text(AppStrings.t('open_pay_app', {'method': widget.methodName}),
                                  style: const TextStyle(fontSize: 14.5, color: Colors.white, fontWeight: FontWeight.w700)),
                            ],
                          ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              // 两个按钮等高（统一的 _actionBtnHeight）：左「取消」右「我已支付」
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: _actionBtnHeight,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, _actionBtnHeight),
                        ),
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(AppStrings.t('cancel'),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        // 立即确认一次：重启轮询（首查不等间隔），超时后也能靠它救回
                        _startPolling();
                        _snack(AppStrings.t('confirming_pay'));
                      },
                      child: Container(
                        height: _actionBtnHeight,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(gradient: MBColors.brandGradient, borderRadius: BorderRadius.circular(14)),
                        alignment: Alignment.center,
                        child: Text(AppStrings.t('i_paid'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
