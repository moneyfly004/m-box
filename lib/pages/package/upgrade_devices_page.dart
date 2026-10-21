import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/account_service.dart';
import '../../core/services/app_log.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/proxy/proxy_core.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../payment/payment_dialog.dart';

/// 设备增量升级：设备超限时 +N 台（可选顺带 +M 天到期）。
/// 调后端 POST /orders/upgrade-devices（preview_only 算价 → 下单 → 扫码支付），
/// 支付成功后端对 device_limit 做加法、到期时间顺延，前端刷新展示。
class UpgradeDevicesPage extends StatefulWidget {
  const UpgradeDevicesPage({super.key});

  @override
  State<UpgradeDevicesPage> createState() => _UpgradeDevicesPageState();
}

class _UpgradeDevicesPageState extends State<UpgradeDevicesPage> {
  static const _deviceOptions = [1, 2, 3, 4, 5];
  // 与后台「设备升级」的月份卡片一致：不延长 / 1 / 2 / 3 / 4 / 6 / 12 个月
  static const _dayOptions = [0, 30, 60, 90, 120, 180, 360];

  int _addDevices = 1;
  int _addDays = 0;

  List<PayMethod> _methods = [];
  int? _selectedMethod;

  bool _loading = true;
  bool _previewing = false;
  bool _paying = false;

  double? _finalAmount;
  double? _originalAmount;
  String? _previewError;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 先确保账号订阅信息已加载：推荐时长依赖 remainingDays，
    // 数据为空时会退回「不加时长」，金额又会和后台对不上。
    // （测试环境用 debugDio 注入 mock，这里跳过，避免对未 mock 的端点发请求）
    if (AccountService.instance.sub == null && ApiClient.debugDio == null) {
      try {
        await AccountService.instance.refresh(force: true);
      } catch (_) {
        // 拉取失败不影响页面：用户仍可手动选天数
      }
    }
    try {
      final methods = await PaymentService.instance.methods();
      if (mounted) {
        setState(() {
          _methods = methods;
          _selectedMethod = _methods.isEmpty ? null : 0;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _previewError = ApiClient.errorMsg(e));
      }
    } finally {
      // 默认选中「推荐时长」：剩余不足 45 天时自动带 +90 天。
      // 之前 _addDays 恒为 0，客户打开页面看到的是「仅加设备」的几块钱，
      // 和后台按「+设备 + 90 天」算出来的金额对不上（用户反馈 susansg@qq.com）。
      final rec = _recommendedDays;
      if (mounted) {
        setState(() {
          if (rec > 0) _addDays = rec;
          _loading = false;
        });
      }
    }
    // 置 _loading=false 后再算价：否则 _preview 开头的 if(_loading) return 会跳过首个算价
    await _preview();
  }

  SubscriptionInfo? get _sub => AccountService.instance.sub;

  /// 推荐时长：剩余不足 45 天 → 推荐 +90 天（避免到期断连）；否则 0（仅加设备）
  int get _recommendedDays {
    final s = _sub;
    if (s == null) return 0;
    if (s.isExpired || (s.remainingDays >= 0 && s.remainingDays < 45)) return 90;
    return 0;
  }

  bool get _expired => _sub?.isExpired ?? false;

  void _onSelectionChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _preview);
  }

  Future<void> _preview() async {
    if (_loading) return;
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      final r = await OrderService.instance
          .previewDeviceUpgrade(addDevices: _addDevices, addDays: _addDays);
      if (!mounted) return;
      final amt = (r['final_amount'] as num?)?.toDouble() ??
          (r['amount'] as num?)?.toDouble() ??
          0;
      final orig = (r['amount'] as num?)?.toDouble();
      setState(() {
        _finalAmount = amt;
        _originalAmount = orig;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _finalAmount = null;
          _previewError = ApiClient.errorMsg(e);
        });
      }
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _pay() async {
    final method = _selectedMethod == null ? null : _methods[_selectedMethod!];
    if (method == null) {
      _toast(AppStrings.t('select_pay'));
      return;
    }
    if (_finalAmount == null || _finalAmount! <= 0) {
      _toast(AppStrings.t('upgrade_no_amount'));
      return;
    }
    setState(() => _paying = true);
    try {
      // 合并下单+支付：带支付方式 key，后端直接返回二维码，省一个来回
      final order = await OrderService.instance.createDeviceUpgrade(
          addDevices: _addDevices, addDays: _addDays, paymentMethodKey: method.payType);
      final orderId = (order['id'] as num?)?.toInt() ?? 0;
      final orderNo = order['order_no']?.toString() ?? '';
      if (orderId == 0) throw Exception(AppStrings.t('order_failed'));

      // 开通并刷新（付款成功 / 余额抵扣直接开通 共用）
      //
      // 【涉及钱，顺序很关键】旧实现先弹「设备升级成功」，再刷新账号与节点，
      // 而刷新失败被 `catch (_) {}` 整个吞掉 —— 支付回调刚完成时接口抖动/5xx
      // 很常见，客户于是看到「升级完成」却依旧被「设备已达上限」挡住、设备页
      // 名额没变，没有任何失败提示或重试入口（有人会因此重复下单）。
      // 现在：**刷新成功才报成功**；失败则如实提示并留在本页，让用户能再点一次。
      Future<void> activate() async {
        if (!mounted) return;
        try {
          final nodes = await AccountService.instance.refreshAfterPurchase();
          if (!mounted) return;
          await context.read<ConnectionController>().applySubscriptionNodes(nodes);
          if (mounted) {
            _toast(AppStrings.t('upgrade_done'));
            Navigator.of(context).pop(true);
          }
        } catch (e) {
          AppLog.error('设备升级后刷新账号状态失败: $e');
          if (mounted) {
            // 不 pop：留在本页，用户可再点一次「立即支付/开通」，或稍后在
            // 「我的-设备管理」里确认名额
            _toast(AppStrings.t('upgrade_paid_refresh_failed'));
          }
        }
      }

      // 余额/全额抵扣：后端直接置 paid，无需二维码，直接开通
      if (order['status']?.toString() == 'paid') {
        await activate();
        return;
      }

      // 金额以后端订单为准，为 0/缺省则回退预览价
      final fa = (order['final_amount'] as num?)?.toDouble() ?? 0;
      final orderAmount = fa > 0 ? fa : (_finalAmount ?? 0);

      // 优先用下单响应里的二维码；为空再回退单独发起支付
      var qr = order['payment_qr_code']?.toString() ?? order['payment_url']?.toString() ?? '';
      var payOrderNo = orderNo;
      if (qr.isEmpty) {
        final pay = await OrderService.instance.pay(orderId: orderId, paymentMethodId: method.id);
        qr = pay.qrCode;
        if (pay.orderNo.isNotEmpty) payOrderNo = pay.orderNo;
      }
      if (qr.isEmpty) throw Exception(AppStrings.t('no_qrcode'));

      if (!mounted) return;
      final paid = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PaymentQrDialog(
          qrContent: qr,
          orderNo: payOrderNo,
          amount: orderAmount,
          methodName: method.name,
          onPaid: () {},
        ),
      );
      if (paid == true) await activate();
    } catch (e) {
      _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _paying = false);
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
    final s = _sub;
    final limit = s?.deviceLimit ?? 0;
    final used = s?.currentDevices ?? 0;
    final expire = s?.expireTime;
    final expireText = expire == null
        ? '—'
        : formatDateYmd(expire); // 与设备页/订单页统一（见 app_theme.dart）

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('upgrade_title')),
      ),
      body: SafeArea(
        child: _loading
            // 加载态与套餐页同款「静态灰块骨架」：不再是裸的居中 spinner
            // （骨架镜像真实布局，低端机也不掉帧；且始终可滚动，不会溢出）
            ? _buildSkeleton()
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                children: [
                  // 当前订阅卡片
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            MFColors.brand.withValues(alpha: .22),
                            MFColors.brand.withValues(alpha: .06),
                          ]),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: MFColors.brand.withValues(alpha: .3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(AppStrings.t('upgrade_current'),
                            style: TextStyle(
                                fontSize: 11, color: MFColors.txt3)),
                        const SizedBox(height: 8),
                        Text(
                          '$used / $limit ${AppStrings.t('devices_unit')}'
                          ' · ${AppStrings.t('upgrade_expire')} $expireText',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: MFColors.txt),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(AppStrings.t('upgrade_add_devices'),
                      style: _sectionStyle()),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final n in _deviceOptions)
                        _chip(
                          '${AppStrings.t('devices_unit')} +$n',
                          _addDevices == n,
                          () {
                            setState(() => _addDevices = n);
                            _onSelectionChanged();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(AppStrings.t('upgrade_add_days'),
                          style: _sectionStyle()),
                      const Spacer(),
                      if (!_expired && _recommendedDays == 0)
                        Text(AppStrings.t('upgrade_no_days_needed'),
                            style: TextStyle(
                                fontSize: 10, color: MFColors.txt3)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final d in _dayOptions)
                        _chip(
                          d == 0
                              ? AppStrings.t('upgrade_days_only')
                              : '+$d ${AppStrings.t('days')}',
                          _addDays == d,
                          _expired && d == 0
                              ? null // 已过期必须顺带加时长
                              : () {
                                  setState(() => _addDays = d);
                                  _onSelectionChanged();
                                },
                          recommended: d == _recommendedDays,
                        ),
                    ],
                  ),
                  if (_expired)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(AppStrings.t('upgrade_expired_hint'),
                          style: TextStyle(
                              fontSize: 10.5, color: MFColors.amber)),
                    )
                  else if (_addDays == 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(AppStrings.t('upgrade_no_days_hint'),
                          style: TextStyle(
                              fontSize: 10.5, color: MFColors.txt3)),
                    ),
                  const SizedBox(height: 16),
                  // 金额
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                        color: MFColors.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: MFColors.line)),
                    child: Row(
                      children: [
                        Text(AppStrings.t('upgrade_amount'),
                            style: TextStyle(
                                fontSize: 13, color: MFColors.txt2)),
                        const Spacer(),
                        if (_previewing)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else if (_finalAmount != null)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (_originalAmount != null &&
                                  _originalAmount! > _finalAmount! + 0.001)
                                Padding(
                                  padding: const EdgeInsets.only(
                                      right: 6, bottom: 2),
                                  child: Text(
                                    // 与套餐页/支付弹窗同一口径（formatPrice）：
                                    // 200 不显示成 200.00，0.02 不显示成 0
                                    '¥${formatPrice(_originalAmount!)}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: MFColors.txt3,
                                        decoration:
                                            TextDecoration.lineThrough),
                                  ),
                                ),
                              Text(
                                '¥${formatPrice(_finalAmount!)}',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: MFColors.brand,
                                    fontFamily: kNumFont),
                              ),
                            ],
                          )
                        else
                          Text('—',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: MFColors.txt3,
                                  fontFamily: kNumFont)),
                      ],
                    ),
                  ),
                  if (_previewError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_previewError!,
                          style: TextStyle(
                              fontSize: 10.5, color: MFColors.red)),
                    ),
                  const SizedBox(height: 16),
                  Text(AppStrings.t('pay_methods'),
                      style: _sectionStyle()),
                  const SizedBox(height: 8),
                  if (_methods.isEmpty)
                    Text(AppStrings.t('no_pay_methods'),
                        style:
                            TextStyle(fontSize: 12, color: MFColors.txt3))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < _methods.length; i++)
                          _payChip(i, _methods[i]),
                      ],
                    ),
                  const SizedBox(height: 20),
                  GestureDetector(
                    onTap:
                        (_paying || _finalAmount == null) ? null : _pay,
                    child: Container(
                      height: 50,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: _paying || _finalAmount == null
                            ? null
                            : MFColors.brandGradient,
                        color: _paying || _finalAmount == null
                            ? MFColors.card2
                            : null,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: _paying
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text(
                              _finalAmount == null
                                  ? AppStrings.t('upgrade_pay_btn')
                                  : '${AppStrings.t('upgrade_pay_btn')} ¥${formatPrice(_finalAmount!)}',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  // 禁用态(未出价/预览失败)用主题文字色,
                                  // 避免 card2 底 + 白字在浅色主题下不可读
                                  color: _paying ? Colors.white : MFColors.txt3),
                            ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(AppStrings.t('upgrade_tip'),
                      style: TextStyle(
                          fontSize: 10.5,
                          color: MFColors.txt3,
                          height: 1.6)),
                ],
              ),
      ),
    );
  }

  TextStyle _sectionStyle() => TextStyle(
      fontSize: 13, fontWeight: FontWeight.w700, color: MFColors.txt);

  /// 首次加载（拉支付方式）期间的占位骨架：静态灰块镜像真实布局，与套餐页
  /// package_page._buildSkeleton 同一风格（不做 shimmer 动画，低端机不掉帧）。
  Widget _buildSkeleton() {
    Widget block(double w, double h, {double r = 8}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
              color: MFColors.card2, borderRadius: BorderRadius.circular(r)),
        );
    Widget chip(double w) => Container(
          margin: const EdgeInsets.only(right: 8, bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
              color: MFColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: MFColors.line)),
          child: block(w, 14, r: 6),
        );
    return ListView(
      // 骨架不参与滚动（与套餐页一致）
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: MFColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: MFColors.line)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              block(96, 11),
              const SizedBox(height: 10),
              block(190, 15),
            ],
          ),
        ),
        const SizedBox(height: 18),
        block(110, 13),
        const SizedBox(height: 10),
        Wrap(children: [chip(58), chip(58), chip(58), chip(58)]),
        const SizedBox(height: 14),
        block(110, 13),
        const SizedBox(height: 10),
        Wrap(children: [chip(70), chip(62), chip(62)]),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
              color: MFColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MFColors.line)),
          child: Row(children: [block(64, 13), const Spacer(), block(72, 20)]),
        ),
        const SizedBox(height: 20),
        block(double.infinity, 50, r: 14),
      ],
    );
  }

  /// 时长/支付方式等选择 chip。
  ///
  /// 审计 P1/P2 三条一起修在这里：
  ///  · 命中区 ≥40（旧实现是 36 高的裸 GestureDetector，触屏上不好点）；
  ///  · 用 InkWell 给按压反馈（旧实现按下去毫无反应）；
  ///  · **[onTap] == null 时必须看起来是禁用的** —— 旧实现里「仅设备」在订阅已
  ///    过期时被禁用，但画得和可用态一模一样，点了没反应，用户以为按钮坏了。
  Widget _chip(String label, bool selected, VoidCallback? onTap,
      {bool recommended = false}) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          gradient: selected && enabled ? MFColors.brandGradient : null,
          color: selected && enabled
              ? null
              : (enabled ? MFColors.card : MFColors.card2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: !enabled
                  ? MFColors.line
                  : (selected
                      ? Colors.transparent
                      : (recommended
                          ? MFColors.amber.withValues(alpha: .7)
                          : MFColors.line))),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight:
                        selected || recommended ? FontWeight.w700 : FontWeight.w500,
                    color: !enabled
                        ? MFColors.txt3 // 禁用：置灰，一眼看出不可点
                        : (selected
                            ? Colors.white
                            : (recommended
                                ? MFColors.amber
                                : MFColors.txt)))),
            if (recommended && !selected) ...[
              const SizedBox(width: 4),
              Text(AppStrings.t('upgrade_recommend'),
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: MFColors.amber)),
            ],
          ],
        ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _payChip(int index, PayMethod m) {
    final selected = _selectedMethod == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedMethod = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? MFColors.brand.withValues(alpha: .12) : MFColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected
                  ? MFColors.brand.withValues(alpha: .7)
                  : MFColors.line),
        ),
        child: Text(m.name,
            style: TextStyle(
                fontSize: 12.5,
                color: selected ? MFColors.brand : MFColors.txt)),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
