// 认证页合规/进度指示回归测试。
//
// 1) 注册页「同意条款」默认必须**未勾选**：旧实现 `bool _agreed = true` 让「必须
//    同意」的校验形同虚设（用户从未作出同意表示就完成注册）—— 合规风险。未勾选
//    时点注册要给出明确提示，且**绝不发起注册请求**。
// 2) 忘记密码页的步骤条必须是**真实进度**：旧实现第 1 步硬编码 done:true，
//    一进页面就打绿勾（验证码还没发），用户在还没拿到验证码时就被误导成
//    「这步已经过了」。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/auth/forgot_password_page.dart';
import 'package:mbox/pages/auth/register_page.dart';
import 'package:mbox/theme/app_theme.dart';

/// 记录一次请求
class Call {
  Call(this.method, this.path, this.body);
  final String method;
  final String path;
  final Map<String, dynamic>? body;
}

/// 自建 stub adapter：捕获 method/path/body，返回标准信封（不联网）
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.calls);
  final List<Call> calls;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    var bodyText = '';
    if (requestStream != null) {
      final bytes = <int>[];
      await for (final c in requestStream) {
        bytes.addAll(c);
      }
      bodyText = utf8.decode(bytes);
    }
    Map<String, dynamic>? body;
    if (bodyText.isNotEmpty) {
      try {
        body = (jsonDecode(bodyText) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    calls.add(Call(options.method, options.uri.path, body));
    return ResponseBody.fromString(
        jsonEncode({
          'success': true,
          'code': 0,
          'message': '',
          'data': <String, dynamic>{}
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }

  @override
  void close({bool force = false}) {}
}

Dio _stubDio(List<Call> calls) =>
    Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'))
      ..httpClientAdapter = StubAdapter(calls);

/// 放大视口：长表单底部按钮一屏可见（避免 ensureVisible 与断言互相干扰）
void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(500, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.runAsync(() async {
    await tester.tap(f);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pump();
  await tester.pump();
}

/// 点「同意条款」整行的左侧（勾选框位置）。
/// 不能直接点文案：那是带手势识别器的《用户协议》链接，会去调 launchUrl
/// （测试环境里通道调用永不返回）—— 这里只需命中外层的整行 GestureDetector。
Future<void> _tapAgreeRow(WidgetTester tester) async {
  final row = find
      .ancestor(
          of: find.textContaining(AppStrings.t('settings_tos'),
              findRichText: true),
          matching: find.byType(GestureDetector))
      .first;
  final r = tester.getRect(row);
  await tester.tapAt(Offset(r.left + 8, r.center.dy));
  await tester.pump();
}

/// 步骤圆圈里的文字（1 / 2 / ✓）
String _stepNo(WidgetTester tester, String key) {
  final t = tester.widget<Text>(find
      .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text))
      .first);
  return t.data ?? '';
}

Color _stepColor(WidgetTester tester, String key) =>
    _stepText(tester, key).style!.color!;

Text _stepText(WidgetTester tester, String key) => tester.widget<Text>(find
    .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text))
    .first);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 注册页的条款链接会外呼：测试里必须换成 seam，否则 launchUrl 挂住整轮
    RegisterPage.debugOpenUrlOverride = (url) async => true;
  });
  tearDown(() {
    AppStrings.setLang('zh', persist: false);
    RegisterPage.debugOpenUrlOverride = null;
  });

  group('注册页：同意条款默认未勾选', () {
    testWidgets('默认状态是未勾选（没有对勾）', (tester) async {
      _bigScreen(tester);
      await tester.pumpWidget(MaterialApp(
          theme: buildMBoxTheme(), home: const RegisterPage()));
      await tester.pump();

      expect(find.byIcon(Icons.check), findsNothing,
          reason: '同意框默认勾选 = 用户从未作出同意表示就完成注册（合规风险）');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('未勾选就点注册：明确提示且不发注册请求', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      ApiClient.debugDio = _stubDio(calls);
      addTearDown(() {
        ApiClient.debugDio = null;
        ApiClient.resetInstance();
      });

      await tester.pumpWidget(MaterialApp(
          theme: buildMBoxTheme(), home: const RegisterPage()));
      await tester.pump();

      // 所有字段都填对，只差「同意条款」
      await tester.enterText(find.byType(TextField).at(0), 'user@test.com');
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.enterText(find.byType(TextField).at(2), 'testuser');
      await tester.enterText(find.byType(TextField).at(3), 'Abc123!@');
      await tester.enterText(find.byType(TextField).at(4), 'Abc123!@');
      await tester.pump();

      await _tap(tester, find.text(AppStrings.t('register_btn')));

      // 提示（SnackBar + 按钮上方常驻红字都走同一 l10n 文案）
      expect(
          find.textContaining(AppStrings.t('agree_required'), findRichText: true),
          findsWidgets,
          reason: '未勾选必须明确提示，不能静默什么都不做');
      expect(calls.where((c) => c.path.endsWith('/auth/register')), isEmpty,
          reason: '未同意条款绝不能发起注册请求');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('勾选后注册请求正常发出（校验不是死拦住）', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      ApiClient.debugDio = _stubDio(calls);
      addTearDown(() {
        ApiClient.debugDio = null;
        ApiClient.resetInstance();
      });

      await tester.pumpWidget(MaterialApp(
          theme: buildMBoxTheme(), home: const RegisterPage()));
      await tester.pump();

      await tester.enterText(find.byType(TextField).at(0), 'user@test.com');
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.enterText(find.byType(TextField).at(2), 'testuser');
      await tester.enterText(find.byType(TextField).at(3), 'Abc123!@');
      await tester.enterText(find.byType(TextField).at(4), 'Abc123!@');
      await tester.pump();

      // 点整行勾选（命中区域 ≥ 40，见 ui_theme_consistency_test）
      await _tapAgreeRow(tester);
      expect(find.byIcon(Icons.check), findsOneWidget, reason: '点一下应该勾上');

      await _tap(tester, find.text(AppStrings.t('register_btn')));
      expect(calls.where((c) => c.path.endsWith('/auth/register')), isNotEmpty,
          reason: '已同意后必须正常发起注册请求');

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('忘记密码页：步骤条反映真实进度', () {
    testWidgets('初始状态：第 1 步未完成（不打勾），第 2 步未开始', (tester) async {
      _bigScreen(tester);
      ApiClient.debugDio = _stubDio(<Call>[]);
      addTearDown(() {
        ApiClient.debugDio = null;
        ApiClient.resetInstance();
      });

      await tester.pumpWidget(MaterialApp(
          theme: buildMBoxTheme(), home: const ForgotPasswordPage()));
      await tester.pump();
      await tester.pump();

      expect(_stepNo(tester, 'fp_step_verify'), '1',
          reason: '验证码还没发就打绿勾 = 假进度（旧实现硬编码 done: true）');
      expect(_stepNo(tester, 'fp_step_pwd'), '2');
      // 当前步骤高亮：第 1 步是 brandLight，第 2 步置灰
      expect(_stepColor(tester, 'fp_step_verify'), MBColors.brandLight);
      expect(_stepColor(tester, 'fp_step_pwd'), MBColors.txt3);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('验证码发送后：第 1 步变成已完成（✓），第 2 步变成当前步骤', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      ApiClient.debugDio = _stubDio(calls);
      addTearDown(() {
        ApiClient.debugDio = null;
        ApiClient.resetInstance();
      });

      await tester.pumpWidget(MaterialApp(
          theme: buildMBoxTheme(), home: const ForgotPasswordPage()));
      await tester.pump();

      final before = _stepNo(tester, 'fp_step_verify');

      await tester.enterText(find.byType(TextField).at(0), 'user@test.com');
      await tester.pump();
      await _tap(tester, find.text(AppStrings.t('send_code')));

      // 真的发了请求
      expect(calls.where((c) => c.path.contains('forgot-password')), isNotEmpty);

      final after = _stepNo(tester, 'fp_step_verify');
      expect(after, '✓', reason: '验证码已发出后第 1 步才应显示完成');
      expect(after, isNot(before),
          reason: '「验证码已发送前后」步骤条状态必须不同（旧实现两态完全一样）');
      expect(_stepColor(tester, 'fp_step_verify'), MBColors.green);
      // 第 2 步（设置新密码）成为当前步骤
      expect(_stepColor(tester, 'fp_step_pwd'), MBColors.brandLight);

      // 卸载页面：倒计时是 60s 周期定时器，必须释放（否则 Pending timers）
      await tester.pumpWidget(const SizedBox());
    });
  });
}
