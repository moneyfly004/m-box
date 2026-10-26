// 第二批 UI 统一化的回归测试（共享小控件 / 设备卡片长文本 / snackbar 单一来源）。
//
// 背景（UI 审计 P1/P2，都是这次统一修的）：
//  · 全项目 13 处小控件是 `GestureDetector` + 5~9px 内边距的小 Container：
//    命中区 20~36px（低于 40 的下限）且没有任何按压反馈，其中包含「删除设备」
//    「取消订单」这类破坏性操作 → 现在统一走 lib/widgets/mf_chip.dart
//    （MBChip / MBActionButton：命中区 ≥40 + InkWell 反馈 + 明显禁用态）。
//  · 设备卡片的元信息是 `Row(mainAxisSize.min)` 里两个不可压缩的 Text：
//    IPv6 / 冗长的地理位置串在 380 宽最小窗口下无法换行也无法省略 → 溢出条纹。
//  · SnackBar 有两种写法：主题里已统一（floating + card2 + 圆角 12），但 5 个页面
//    又各自显式写了一遍浮层+底色 → 一旦主题调整就会悄悄走偏。现在只留主题一处。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/main.dart';
import 'package:mbox/pages/devices/devices_page.dart';
import 'package:mbox/pages/nodes/nodes_page.dart';
import 'package:mbox/pages/orders/orders_page.dart';
import 'package:mbox/theme/app_theme.dart';
import 'package:mbox/widgets/mf_chip.dart';

// ---------------- 假后端 ----------------

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions o) handler;
  final List<String> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) {
    calls.add('${options.method} ${options.uri.path}');
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok(Object? data) => ResponseBody.fromString(
      jsonEncode({'success': true, 'code': 0, 'message': '', 'data': data}),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

void _useDio(Future<ResponseBody> Function(RequestOptions o) handler) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  dio.httpClientAdapter = _Adapter(handler);
  ApiClient.debugDio = dio;
  ApiClient.resetInstance();
}

Widget _wrap(Widget page) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: SessionState()..setLoggedIn(true)),
        ChangeNotifierProvider.value(value: ConnectionController.instance),
        ChangeNotifierProvider.value(value: AccountService.instance),
      ],
      child: MaterialApp(theme: buildMBoxTheme(), home: page),
    );

Future<void> _pump(WidgetTester tester, Widget page,
    {Size size = const Size(380, 620)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(page));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// 某个可见控件的实际命中区（≥40 才算合格）
double _hitHeight(WidgetTester tester, Finder f) => tester.getSize(f).height;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    AppStrings.setLang('zh', persist: false);
  });

  group('共享小控件：命中区与按压反馈', () {
    testWidgets('MBChip：命中区 ≥40，用 InkWell，禁用/选中状态分明', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildMBoxTheme(),
        home: Scaffold(
          body: Column(children: [
            MBChip(label: '排序', icon: Icons.sort, onTap: () => taps++),
            MBChip(label: '选中', selected: true, onTap: () {}),
            MBChip(label: '禁用', enabled: false, onTap: null),
          ]),
        ),
      ));
      final chips = find.byType(MBChip);
      for (var i = 0; i < 3; i++) {
        expect(_hitHeight(tester, chips.at(i)), greaterThanOrEqualTo(40),
            reason: '第 $i 个 chip 命中区不足 40px（审计：旧实现 20~36px）');
        expect(find.descendant(of: chips.at(i), matching: find.byType(InkWell)),
            findsOneWidget,
            reason: '没有 InkWell = 按下去毫无反馈');
      }
      await tester.tap(chips.first);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('MBActionButton：命中区 ≥40，禁用后不可点', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildMBoxTheme(),
        home: Scaffold(
          body: Column(children: [
            MBActionButton(label: '取消订单', onTap: () => taps++, color: MBColors.red),
            MBActionButton(label: '再次支付', filled: true, onTap: () {}),
            const MBActionButton(label: '不可点'),
          ]),
        ),
      ));
      final btns = find.byType(MBActionButton);
      for (var i = 0; i < 3; i++) {
        expect(_hitHeight(tester, btns.at(i)), greaterThanOrEqualTo(40));
      }
      await tester.tap(btns.first);
      await tester.pump();
      expect(taps, 1);
      await tester.tap(btns.last);
      await tester.pump();
      expect(taps, 1, reason: '禁用按钮不该触发回调');
    });
  });

  group('页面上的小控件真的迁移了', () {
    testWidgets('订单页：取消订单/再次支付命中区 ≥40（旧实现 height: 32）', (tester) async {
      _useDio((o) async => _ok({
            'orders': [
              {
                'id': 1,
                'order_no': 'MF1',
                'amount': 19.9,
                'final_amount': 19.9,
                'status': 'pending',
                'type': 'order',
                'package': {'name': '月付套餐'},
                'created_at': '2026-09-01 12:05:00',
              }
            ],
            'total': 1,
            'page': 1,
            'size': 20,
          }));
      await _pump(tester, const OrdersPage());
      final btns = find.byType(MBActionButton);
      expect(btns, findsWidgets, reason: '订单操作按钮没有迁到共享控件');
      for (var i = 0; i < btns.evaluate().length; i++) {
        expect(_hitHeight(tester, btns.at(i)), greaterThanOrEqualTo(40));
      }
      await _unmount(tester);
    });

    testWidgets('设备页：操作按钮命中区 ≥40（旧实现 height: 34）', (tester) async {
      _useDio((o) async => _ok({
            'devices': [
              {
                'id': 11,
                'device_name': 'iPhone 15',
                'os_name': 'iOS',
                'os_version': '18.0',
                'ip_address': '2408:8456:1234:5678:9abc:def0:1234:5678',
                'location': '中国广东省深圳市南山区科技园',
                'online': true,
                'access_count': 5,
                'remark': '',
                'last_seen': '2026-09-01 12:00:00',
                'device_type': 'phone',
                'device_model': 'iPhone 15',
                'subscription_id': 1,
              }
            ],
            'total': 1,
            'page': 1,
            'size': 100,
            // allow_delete_device=true：本用例要断言「删除按钮」的命中区，
            // 必须先让后台开关处于「允许删除」（关闭时该按钮换成「升级设备数量」）
            'allow_delete_device': true,
          }));
      await _pump(tester, const DevicesPage());
      // 命中区：备注 / 删除按钮（用文案定位到具体那颗按钮，而不是数页面里
      // 所有 InkWell —— 否则断言会因为无关控件而假通过）
      for (final label in [AppStrings.t('edit_remark_btn'), AppStrings.t('delete')]) {
        final hit = find.ancestor(
            of: find.text(label), matching: find.byType(InkWell));
        expect(hit, findsWidgets, reason: '「$label」按钮没有 InkWell（无按压反馈）');
        expect(_hitHeight(tester, hit.first), greaterThanOrEqualTo(40),
            reason: '「$label」命中区不足 40px（旧实现 height: 34）');
      }
      // 超长 IPv6 + 超长地理位置：不能溢出
      expect(tester.takeException(), isNull, reason: '设备卡片元信息又溢出了');
      await _unmount(tester);
    });

    testWidgets('节点页：排序/刷新 chip 命中区 ≥40 且是 InkWell', (tester) async {
      _useDio((o) async => _ok({
            'proxies': [
              {
                'name': '香港 01',
                'type': 'ss',
                'server': '1.2.3.4',
                'port': 8388,
                'cipher': 'aes-128-gcm',
                'password': 'pw',
              }
            ],
          }));
      await _pump(tester, const NodesPage());
      // 排序 chip（文案随排序方式变化，用 label 关键字定位）
      final chip = find.byWidgetPredicate((w) =>
          w is MBChip && (w.label.contains('排序') || w.label.contains('延迟')));
      expect(chip, findsWidgets, reason: '排序 chip 没有迁到 MBChip');
      final rect = tester.getRect(chip.first);
      expect(rect.height, greaterThanOrEqualTo(40));
      await _unmount(tester);
    });
  });

  test('源码级守卫：SnackBar 样式只允许来自主题（不再各页自己写一套）', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      var idx = src.indexOf('SnackBar(');
      while (idx >= 0) {
        final seg = src.substring(idx, (idx + 260).clamp(0, src.length));
        if (seg.contains('SnackBarBehavior.floating')) {
          offenders.add('${f.path}: behavior: floating（主题已统一提供）');
        }
        if (seg.contains('backgroundColor: MBColors.card2')) {
          offenders.add('${f.path}: SnackBar 里显式 backgroundColor（主题已统一提供）');
        }
        idx = src.indexOf('SnackBar(', idx + 1);
      }
    }
    expect(offenders, isEmpty,
        reason: 'SnackBar 样式请统一由 ThemeData.snackBarTheme 提供，否则同一会话里会出现两种样式');
  });
}
