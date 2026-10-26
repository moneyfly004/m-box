// 纯新增测试文件（不改任何既有测试）。
//
// 覆盖 UI 审计里通知 / 设备 / 订单三页的四个问题：
//   P1-1 改一个条目就整页转圈：`_load()` 无条件 `_loading = true`，mutation 之后
//        整页列表被一个居中 CircularProgressIndicator 顶掉 → 闪白 + 丢滚动位置；
//   P1-2 设备页把「加载失败」显示成「暂无设备」（没有 _error 字段）；
//   P1-3 通知只能长按删除（桌面端没有长按手势 → 删除入口不可发现）；
//   P2-4 错误态是 Center + Column 且后端原始错误文本不限长，620 高的窗口里溢出。
//
// 断言方式：
//   * 用一个记录型 HttpClientAdapter 做假后端：能记录每个请求（断言「点删除没有
//     顺带发标记已读」），也能让某次请求挂起在闸门上 —— 专门断言「请求进行中」
//     那一瞬间的 UI（旧的整页 spinner 就出现在这一瞬间）；
//   * 窗口跑 380×620（应用允许的最小窗口）与 420×780，widget 测试是 Ahem 字体
//     （每个字符都是等宽方块，比真实字体宽约 1.6 倍）→ 这里不溢出，真实更安全。

import 'dart:async';
import 'dart:convert';
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
import 'package:mbox/pages/devices/devices_page.dart';
import 'package:mbox/pages/notifications/notifications_page.dart';
import 'package:mbox/pages/orders/orders_page.dart';
import 'package:mbox/theme/app_theme.dart';

// ---------------- 假后端 ----------------

String _ep(RequestOptions o) {
  const prefix = '/api/v1';
  final p = o.uri.path;
  final i = p.indexOf(prefix);
  return i >= 0 ? p.substring(i + prefix.length) : p;
}

/// 记录型适配器：记录 `'GET /notifications'` 形式的调用序列；
/// handler 里可以 `await 闸门` 把某个请求挂起（模拟慢网络）。
class RecAdapter implements HttpClientAdapter {
  RecAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions o) handler;
  final List<String> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) {
    calls.add('${options.method} ${_ep(options)}');
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _body(Object? json) => ResponseBody.fromString(
      jsonEncode(json),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

ResponseBody _ok(Object? data) =>
    _body({'success': true, 'code': 0, 'message': '', 'data': data});

/// 业务失败信封（success:false）：ApiClient 抛 ApiException(message)，
/// 页面错误态展示的就是这段原文（后端原始错误，长度不可控）。
ResponseBody _fail(String msg) =>
    _body({'success': false, 'code': 1, 'message': msg, 'data': null});

Dio _dio(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  dio.httpClientAdapter = adapter;
  return dio;
}

// ---------------- 测试数据 ----------------

Map<String, dynamic> _notif(int id, {required bool read, required String title}) => {
      'id': id,
      'title': title,
      'content': '您的套餐还剩 3 天到期，请及时续费。',
      'type': 'system',
      'is_read': read,
      'created_at': '2026-09-01 10:00:00',
    };

Map<String, dynamic> _device(int id, {String name = 'iPhone 15'}) => {
      'id': id,
      'device_name': name,
      'os_name': 'iOS',
      'os_version': '18.0',
      'ip_address': '1.2.3.4',
      'location': '广东',
      'online': true,
      'access_count': 5,
      'remark': '',
      'last_seen': '2026-09-01 12:00:00',
      'device_type': 'phone',
      'device_model': 'iPhone 15',
      'subscription_id': 1,
    };

Map<String, dynamic> _order(int i, {String status = 'pending'}) => {
      'id': 100 + i,
      'order_no': 'MF20260901${i.toString().padLeft(4, '0')}',
      'amount': 19.9,
      'final_amount': 19.9,
      'status': status,
      'type': 'order',
      'package': {'name': '月付套餐 $i'},
      'created_at': '2026-09-01 12:05:00',
    };

// ---------------- 泵送辅助 ----------------

Widget _wrap(Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ConnectionController.instance),
        ChangeNotifierProvider.value(value: AccountService.instance),
      ],
      child: MaterialApp(theme: buildMBoxTheme(), home: child),
    );

/// 建页 + 把已排队的微任务全部跑完（假后端只走微任务，不需要 runAsync）。
Future<void> _pump(WidgetTester tester, Widget page,
    {Size size = const Size(420, 780)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(page));
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 点一下并把请求链路推到底（假后端的响应除了微任务还需要跑计时器）
Future<void> _tapAndTick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 20));
}

/// 卸载页面：SnackBar 自带 4s 计时器，测试结束时留着会报 Pending timers。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// 可滚动区域的当前偏移（列表页都是 body 里唯一那个 ListView）
double _offset(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first)
    .position
    .pixels;

/// 找一个**当前完全落在窗口内**的文案（滚动之后第一项可能在屏幕外，
/// 点它会打空）
Finder _visibleText(WidgetTester tester, String text) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  final f = find.text(text);
  for (var i = 0; i < f.evaluate().length; i++) {
    final r = tester.getRect(f.at(i));
    if (r.top >= kToolbarHeight + 4 && r.bottom <= size.height - 4) return f.at(i);
  }
  fail('窗口内没有可见的「$text」');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    AppStrings.setLang('zh', persist: false);
  });

  group('问题1：mutation 之后静默刷新（不整页转圈 / 不丢滚动位置）', () {
    testWidgets('通知：标记已读期间不出现整页 spinner，列表不被顶掉', (tester) async {
      final gate = Completer<void>();
      var listCalls = 0;
      final items = <Map<String, dynamic>>[
        _notif(1, read: false, title: '套餐即将到期'),
        _notif(2, read: true, title: '新公告'),
      ];
      final adapter = RecAdapter((o) async {
        final ep = _ep(o);
        if (o.method == 'GET' && ep == '/notifications') {
          listCalls++;
          if (listCalls >= 2) await gate.future; // 静默刷新的那次挂起
          return _ok(items);
        }
        if (o.method == 'PUT' && ep == '/notifications/1/read') {
          items[0] = _notif(1, read: true, title: '套餐即将到期');
          return _ok(null);
        }
        return _ok(null);
      });
      ApiClient.debugDio = _dio(adapter);
      await _pump(tester, const NotificationsPage());

      expect(find.text('套餐即将到期'), findsOneWidget);
      expect(find.text('全部已读'), findsOneWidget, reason: '有未读 → 全部已读入口可见');

      // 点条目 = 标记已读：PUT 返回后那次静默 GET 挂在闸门上
      await _tapAndTick(tester, find.text('套餐即将到期'));
      expect(adapter.calls, contains('PUT /notifications/1/read'));

      // 请求进行中这一瞬间：旧实现整页只剩一个居中 spinner
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '改一条通知就整页转圈 = 闪一下 + 丢滚动位置 + 像卡死');
      expect(find.text('套餐即将到期'), findsOneWidget, reason: '列表被 spinner 顶掉 = 闪白');

      gate.complete();
      await _flush(tester);
      expect(find.text('全部已读'), findsNothing, reason: '静默刷新后未读已清空');
      expect(find.text('套餐即将到期'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await _unmount(tester);
    });

    testWidgets('订单：取消订单后静默刷新，滚动位置保留', (tester) async {
      final gate = Completer<void>();
      var listCalls = 0;
      final orders = [for (var i = 0; i < 12; i++) _order(i)];
      final adapter = RecAdapter((o) async {
        final ep = _ep(o);
        if (o.method == 'GET' && ep == '/orders') {
          listCalls++;
          if (listCalls >= 2) await gate.future; // 静默刷新的那次挂起
          return _ok(orders);
        }
        if (o.method == 'POST' && ep.startsWith('/orders/') && ep.endsWith('/cancel')) {
          final no = ep.substring('/orders/'.length, ep.length - '/cancel'.length);
          orders.firstWhere((e) => e['order_no'] == no)['status'] = 'cancelled';
          return _ok(null);
        }
        return _ok(null);
      });
      ApiClient.debugDio = _dio(adapter);
      await _pump(tester, const OrdersPage(), size: const Size(380, 620));

      // 滚到列表中间
      await tester.drag(find.byType(ListView), const Offset(0, -320));
      await tester.pump();
      final before = _offset(tester);
      expect(before, greaterThan(0), reason: '前置条件：列表已滚动');

      await tester.tap(_visibleText(tester, '取消订单'));
      await _flush(tester);
      expect(find.text('确定取消这笔待支付订单吗？'), findsOneWidget);
      // 弹窗标题与确认按钮文案相同（都是「取消订单」）→ 取 actions 里的那个
      await _tapAndTick(
          tester,
          find
              .descendant(of: find.byType(AlertDialog), matching: find.text('取消订单'))
              .last);

      expect(adapter.calls.any((c) => c.contains('/cancel')), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '取消订单后整页转圈（旧实现每次 mutation 都转）');
      expect(_offset(tester), closeTo(before, .5), reason: '整页换 spinner 重建 → 滚动位置丢失');

      gate.complete();
      await _flush(tester);
      expect(_offset(tester), closeTo(before, .5), reason: '静默刷新也不该动滚动位置');
      expect(find.text('已取消'), findsOneWidget, reason: '静默刷新确实落到了新数据');
      await _unmount(tester);
    });

    testWidgets('设备：删除后静默刷新，列表不被 spinner 顶掉', (tester) async {
      final gate = Completer<void>();
      var listCalls = 0;
      final devices = [for (var i = 0; i < 6; i++) _device(11 + i, name: '设备 $i')];
      final adapter = RecAdapter((o) async {
        final ep = _ep(o);
        if (o.method == 'GET' && ep == '/subscriptions/devices') {
          listCalls++;
          if (listCalls >= 2) await gate.future; // 静默刷新的那次挂起
          // allow_delete_device=true：本用例验证「删除后静默刷新」，
          // 需要后台开关处于「允许删除」状态才会渲染删除按钮
          // （开关关闭时设备卡片上只有「升级设备数量」入口，见 devices_page.dart）
          return _ok({'devices': devices, 'total': devices.length, 'page': 1, 'size': 100,
              'allow_delete_device': true});
        }
        if (o.method == 'DELETE' && ep == '/devices/11') {
          devices.removeAt(0);
          return _ok(null);
        }
        return _ok(null);
      });
      ApiClient.debugDio = _dio(adapter);
      await _pump(tester, const DevicesPage());

      expect(find.text('设备 0'), findsOneWidget);
      await tester.tap(find.text('删除').first);
      await _flush(tester);
      expect(find.textContaining('确定删除「设备 0」吗？'), findsOneWidget);
      await _tapAndTick(
          tester,
          find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')));

      expect(adapter.calls, contains('DELETE /devices/11'));
      // 只允许卡片里的按钮进度圈（12×12）；旧的整页 spinner 会把整个 ListView 顶掉
      expect(find.byType(ListView), findsOneWidget, reason: '整页被 spinner 顶掉 = 闪白');
      final spinners = find.byType(CircularProgressIndicator);
      for (var i = 0; i < spinners.evaluate().length; i++) {
        expect(tester.getSize(spinners.at(i)).width, lessThanOrEqualTo(16),
            reason: '出现整页居中 spinner（旧行为：删一台设备整页转圈）');
      }
      expect(find.text('设备 1'), findsOneWidget, reason: '列表被 spinner 顶掉 = 闪白');

      gate.complete();
      await _flush(tester);
      expect(find.text('设备 0'), findsNothing, reason: '静默刷新后已删除的设备消失');
      await _unmount(tester);
    });
  });

  group('问题2：设备页失败态（失败 ≠ 没设备）', () {
    testWidgets('加载失败显示「加载失败 + 重试」，重试后恢复列表', (tester) async {
      var calls = 0;
      final adapter = RecAdapter((o) async {
        calls++;
        if (calls == 1) return _fail('网络连接失败，请检查网络后重试');
        return _ok({
          'devices': [_device(11)],
          'total': 1,
          'page': 1,
          'size': 100,
        });
      });
      ApiClient.debugDio = _dio(adapter);
      await _pump(tester, const DevicesPage());

      expect(find.text('暂无设备'), findsNothing,
          reason: 'P1：加载失败被显示成「没有设备」，用户以为设备没了');
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);

      await tester.tap(find.text('重试'));
      await _flush(tester);
      expect(find.text('iPhone 15'), findsOneWidget, reason: '重试成功应显示真实设备');
      expect(find.text('加载失败'), findsNothing);
    });

    testWidgets('加载成功且确实没设备时，才显示空态', (tester) async {
      ApiClient.debugDio = _dio(RecAdapter((o) async => _ok({
            'devices': <Map<String, dynamic>>[],
            'total': 0,
            'page': 1,
            'size': 100,
          })));
      await _pump(tester, const DevicesPage());
      expect(find.text('暂无设备'), findsOneWidget);
      expect(find.text('加载失败'), findsNothing);
    });
  });

  group('问题3：通知的可见删除入口', () {
    testWidgets('行尾删除图标：点击弹确认框，且不会顺带标记已读', (tester) async {
      final items = <Map<String, dynamic>>[
        _notif(1, read: false, title: '套餐即将到期'),
        _notif(2, read: true, title: '新公告'),
      ];
      final adapter = RecAdapter((o) async {
        final ep = _ep(o);
        if (o.method == 'GET' && ep == '/notifications') return _ok(items);
        if (o.method == 'DELETE' && ep == '/notifications/1') {
          items.removeWhere((e) => e['id'] == 1);
          return _ok(null);
        }
        return _ok(null);
      });
      ApiClient.debugDio = _dio(adapter);
      await _pump(tester, const NotificationsPage());

      // 桌面端没有长按手势：每条都必须有可见的删除入口
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(2),
          reason: 'P1：通知只能长按删除，桌面端不可发现');

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('删除通知'), findsOneWidget, reason: '点图标应弹二次确认');
      expect(adapter.calls.where((c) => c.contains('/read')), isEmpty,
          reason: '点删除不能同时触发外层点击的「标记已读」');

      await _tapAndTick(
          tester,
          find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')));
      await _flush(tester);
      expect(adapter.calls, contains('DELETE /notifications/1'));
      expect(find.text('套餐即将到期'), findsNothing, reason: '删除后条目消失（静默刷新）');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await _unmount(tester);
    });

    testWidgets('长按仍保留为删除快捷方式', (tester) async {
      final adapter = RecAdapter((o) async {
        final ep = _ep(o);
        if (o.method == 'GET' && ep == '/notifications') {
          return _ok([_notif(1, read: true, title: '新公告')]);
        }
        return _ok(null);
      });
      ApiClient.debugDio = _dio(adapter);
      await _pump(tester, const NotificationsPage());

      await tester.longPress(find.text('新公告'));
      await tester.pump();
      await tester.pump();
      expect(find.text('删除通知'), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('问题4：错误态可滚动 + 长错误不溢出', () {
    // 后端原始错误：长度不可控（这里塞 60 遍 + 一条长 URL）
    final longError =
        '服务器开小差了，请稍后重试。' * 60 + 'https://dy.moneyfly.top/api/v1/orders?page=1&size=100';

    final pages = <String, Widget>{
      '订单页': const OrdersPage(),
      '通知页': const NotificationsPage(),
      '设备页': const DevicesPage(),
    };

    for (final entry in pages.entries) {
      for (final lang in ['zh', 'en']) {
        for (final size in const [Size(380, 620), Size(420, 780)]) {
          testWidgets(
              '${entry.key} $lang @ ${size.width.toInt()}x${size.height.toInt()}：'
              '超长错误文本不溢出且可滚动', (tester) async {
            await AppStrings.setLang(lang, persist: false);
            ApiClient.debugDio = _dio(RecAdapter((o) async => _fail(longError)));
            await _pump(tester, entry.value, size: size);

            expect(find.text(AppStrings.t('load_failed')), findsOneWidget);
            expect(find.text(AppStrings.t('retry')), findsOneWidget);

            if (entry.key == '设备页') {
              // MBEmpty 的 hint 不能限行 → 页面侧截断，保证「重试」按钮留在可视区
              final hint = tester
                  .widget<Text>(find.textContaining('服务器开小差了'))
                  .data!;
              expect(hint.length, lessThanOrEqualTo(101),
                  reason: '未截断的几十行错误文本会把重试按钮顶出可视区');
              expect(tester.getSize(find.text(AppStrings.t('retry'))).height,
                  greaterThan(0));
            } else {
              expect(find.text(longError), findsOneWidget);
              // 错误文本限行（无 maxLines 时 620 高的窗口会被顶破）
              final Text err = tester.widget<Text>(find.text(longError));
              expect(err.maxLines, isNotNull, reason: '后端原始错误文本没有限行');
              expect(err.overflow, TextOverflow.ellipsis);
              // 4 行 × 12.5px × 1.5 行高 ≈ 75：真的被截住了，而不是排了几十行
              expect(tester.getSize(find.text(longError)).height, lessThanOrEqualTo(80),
                  reason: '错误文本按原文排了几十行 = 620 高的窗口里溢出');
            }

            // 错误态外层可滚动
            expect(
                find.ancestor(
                    of: find.text(AppStrings.t('retry')),
                    matching: find.byType(SingleChildScrollView)),
                findsOneWidget,
                reason: '错误态不可滚动 → 窄窗口里读不到全文');

            await tester.drag(find.text(AppStrings.t('load_failed')), const Offset(0, -60));
            await tester.pump();
            expect(tester.takeException(), isNull,
                reason: '长错误文本把布局顶破了（RenderFlex overflow）');
          });
        }
      }
    }

    testWidgets('错误文本本身保持可读（不裁成空白）', (tester) async {
      final err = '服务暂时不可用，请稍后重试' * 3;
      ApiClient.debugDio = _dio(RecAdapter((o) async => _fail(err)));
      await _pump(tester, const OrdersPage(), size: const Size(380, 620));
      final Text t = tester.widget<Text>(find.text(err));
      final box = tester.getSize(find.text(err));
      expect(t.maxLines, greaterThanOrEqualTo(2), reason: '可换行显示，不是单行省略');
      expect(box.height, greaterThan(0));
    });
  });

  group('窄窗口 + 长文案：新增的删除入口不会挤破通知行', () {
    final longTitle = '您的订阅即将到期请及时续费以免影响正常使用' * 4;
    final longContent = '尊敬的用户，您的套餐将于 3 天后到期，请及时续费。' * 10;

    for (final size in const [Size(380, 620), Size(420, 780)]) {
      testWidgets('通知列表 @ ${size.width.toInt()}x${size.height.toInt()}：零异常', (tester) async {
        ApiClient.debugDio = _dio(RecAdapter((o) async => _ok([
              {
                'id': 1,
                'title': longTitle,
                'content': longContent,
                'type': 'system',
                'is_read': false,
                'created_at': '2026-09-01 10:00:00',
              },
              _notif(2, read: true, title: '新公告'),
            ])));
        await _pump(tester, const NotificationsPage(), size: size);

        expect(find.text(longTitle), findsOneWidget);
        // 行尾删除入口必须在窗口内、不被长标题挤出屏幕
        final icon = find.byIcon(Icons.delete_outline).first;
        final r = tester.getRect(icon);
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(size.width));
        expect(r.width, greaterThanOrEqualTo(17));
        // 时间戳没有被标题挤没
        expect(tester.getSize(find.textContaining('-01 ').first).width, greaterThan(0));
        expect(tester.takeException(), isNull, reason: '长文案 + 窄窗口下 RenderFlex overflow');
      });
    }
  });
}
