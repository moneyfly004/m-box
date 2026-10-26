import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_skeleton.dart';
import '../../widgets/mf_chip.dart';
import '../../widgets/mf_empty.dart';
import '../payment/payment_dialog.dart';

/// 我的订单：列表 + 待支付订单可继续支付/取消
class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  List<OrderItem> _orders = [];
  bool _loading = true;
  bool _paying = false; // 支付进行中,防连点双弹二维码
  String? _error; // 加载失败原因(错误态与空态分流:失败≠没数据)

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉取列表。[spinner] = true 时整页转圈（首屏 / 用户主动刷新）；
  /// 取消订单、继续支付等 mutation 之后用 `spinner: false` 静默刷新：
  /// 旧实现每次都把列表换成居中 CircularProgressIndicator → 操作一次整页闪白、
  /// 滚动位置丢失、看着像卡死。
  Future<void> _load({bool spinner = true}) async {
    if (!mounted) return;
    setState(() {
      if (spinner) _loading = true;
      _error = null;
    });
    try {
      final list = await OrderService.instance.list();
      if (mounted) setState(() => _orders = list);
    } catch (e) {
      // 加载失败 → 显示「加载失败+重试」,不要把网络错误误当「暂无订单」
      if (!mounted) return;
      // 静默刷新失败：列表原样保留，只弹提示（不要用错误页顶掉已有内容）
      if (spinner) {
        setState(() => _error = ApiClient.errorMsg(e));
      } else {
        _toast(ApiClient.errorMsg(e));
      }
    } finally {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  Future<void> _payOrder(OrderItem o) async {
    if (_paying) return; // busy guard
    setState(() => _paying = true);
    try {
      // 先确认订单仍是待支付
      final st = await OrderService.instance.status(o.orderNo);
      if (!mounted) return;
      if (st.isPaid) {
        _toast(AppStrings.t('order_paid'));
        return;
      }
      if (st.status != 'pending') {
        _toast(AppStrings.t('order_status_tip', {'status': st.status}));
        return;
      }
      // 用当前启用的第一个支付方式（跟随官网后台设置）重新发起
      final methods = await PaymentService.instance.methods();
      if (!mounted) return;
      if (methods.isEmpty) {
        _toast(AppStrings.t('no_pay_methods'));
        return;
      }
      final pay = await OrderService.instance.pay(orderId: o.id, paymentMethodId: methods.first.id);
      if (pay.qrCode.isEmpty) {
        _toast(AppStrings.t('no_qrcode_retry'));
        return;
      }
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PaymentQrDialog(
          qrContent: pay.qrCode,
          orderNo: pay.orderNo.isEmpty ? o.orderNo : pay.orderNo,
          amount: o.finalAmount > 0 ? o.finalAmount : o.amount,
          methodName: methods.first.name,
          onPaid: () {},
        ),
      );
      await _load(spinner: false);
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Future<void> _cancelOrder(OrderItem o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MBColors.card2,
        title: Text(AppStrings.t('cancel_order'), style: TextStyle(fontSize: 16)),
        content: Text(AppStrings.t('order_cancel_confirm'), style: TextStyle(fontSize: 13.5, color: MBColors.txt2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.t('rethink'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('cancel_order'), style: TextStyle(color: MBColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await OrderService.instance.cancel(o.orderNo);
      await _load(spinner: false);
      if (mounted) _toast(AppStrings.t('order_cancelled'));
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 错误态（失败 ≠ 没订单）：外层可滚动 + 错误文本限行，
  /// 后端原始错误再长也不会在 380×620 的最小窗口里顶破布局。
  Widget _buildError() => LayoutBuilder(
        builder: (_, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                minHeight: box.maxHeight.isFinite ? box.maxHeight : 0),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 40, color: MBColors.txt3),
                    const SizedBox(height: 10),
                    Text(AppStrings.t('load_failed'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13.5, color: MBColors.txt2, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: MBColors.txt3, height: 1.5)),
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () => _load(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                        decoration: BoxDecoration(
                            gradient: MBColors.brandGradient,
                            borderRadius: BorderRadius.circular(12)),
                        child: Text(AppStrings.t('retry'),
                            style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('my_orders')),
        actions: [TextButton(onPressed: _load, child: Text(AppStrings.t('refresh'), style: TextStyle(color: MBColors.brandLight)))],
      ),
      body: SafeArea(
        child: _loading
            // 首屏用骨架屏而不是裸转圈：转圈→内容的跳变比骨架明显得多
            ? const MBListSkeleton()
            : _error != null
                ? _buildError()
                : _orders.isEmpty
                ? MBEmpty(
                    title: AppStrings.t('no_orders'),
                    hint: AppStrings.t('no_orders_hint'),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                    itemCount: _orders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _buildOrderCard(_orders[i]),
                  ),
      ),
    );
  }

  Color _statusColor(String status) => switch (status) {
        'paid' => MBColors.green,
        'pending' => MBColors.amber,
        _ => MBColors.txt3,
      };

  Widget _buildOrderCard(OrderItem o) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: MBColors.card, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MBColors.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(o.packageName ?? AppStrings.t('order_type', {'type': o.type}),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor(o.status).withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _statusColor(o.status).withValues(alpha: .3)),
                ),
                child: Text(o.statusLabel,
                    style: TextStyle(fontSize: 10.5, color: _statusColor(o.status), fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('¥${(o.finalAmount > 0 ? o.finalAmount : o.amount).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, fontFamily: kNumFont)),
              const Spacer(),
              Text(o.orderNo,
                  style:  TextStyle(fontSize: 10.5, color: MBColors.txt3, fontFamily: kNumFont)),
            ],
          ),
          if (o.createdAt.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('${AppStrings.t('order_time', {'time': ''})}${o.createdAt}', style: TextStyle(fontSize: 10.5, color: MBColors.txt3)),
          ],
          if (o.status == 'pending') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Spacer(),
                // 命中区 ≥40（旧实现是 height: 32 的裸 GestureDetector：触屏上
                // 「取消订单」这种动作很难点准，而且没有按压反馈）
                MBActionButton(
                  label: AppStrings.t('cancel_order'),
                  color: MBColors.red,
                  onTap: () => _cancelOrder(o),
                ),
                const SizedBox(width: 10),
                MBActionButton(
                  label: AppStrings.t('pay_again'),
                  filled: true,
                  onTap: () => _payOrder(o),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
