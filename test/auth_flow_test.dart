import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/services/password_policy.dart';
import 'package:mbox/pages/auth/change_password_page.dart';
import 'package:mbox/pages/auth/forgot_password_page.dart';
import 'package:mbox/pages/auth/register_page.dart';
import 'package:mbox/theme/app_theme.dart';

/// 注册 / 找回密码 / 接收验证码 / 填写验证码 / 修改密码 全链路测试。
/// 使用自建 stub HttpClientAdapter：捕获每个请求的 method/path/JSON body，
/// 返回标准信封，断言字段契约与 UI 反馈。

/// 记录一次调用
class Call {
  Call(this.method, this.path, this.body);
  final String method;
  final String path;
  final Map<String, dynamic>? body;
}

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
    final envelope =
        jsonEncode({'success': true, 'code': 0, 'message': '', 'data': <String, dynamic>{}});
    return ResponseBody.fromString(envelope, 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }

  @override
  void close({bool force = false}) {}
}

/// 可 push 目标页的宿主（便于断言「成功后返回」）
Widget _host(Widget page) {
  return MaterialApp(
    theme: buildMBoxTheme(),
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () =>
                Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => page)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

/// 真实异步区点击（stub HTTP 在 runAsync 中真实完成）
Future<void> runTap(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pump();
  await tester.pump();
}

/// 滚动到目标并点击（长表单底部按钮可能超出 600px 视口）
Future<void> tapButton(WidgetTester tester, String text) async {
  final f = find.text(text);
  await tester.ensureVisible(f);
  await tester.pump();
  await runTap(tester, f);
}

/// 勾选注册页的「同意条款」：点整行最左侧（勾选框位置）。
/// 不点文案本身 —— 那是带手势识别器的《用户协议》外链。
Future<void> tickAgree(WidgetTester tester) async {
  final row = find
      .ancestor(
          of: find.textContaining('用户协议', findRichText: true),
          matching: find.byType(GestureDetector))
      .first;
  final r = tester.getRect(row);
  await tester.tapAt(Offset(r.left + 8, r.center.dy));
  await tester.pump();
}

/// 放大测试视口，长表单无需滚动即可点到底部按钮
void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
  });

  group('密码策略（与后端一致）', () {
    test('长度不足拒绝', () {
      expect(PasswordPolicy.errorFor('Ab1!'), isNotNull);
    });
    test('仅两类字符拒绝（小写+数字）', () {
      expect(PasswordPolicy.errorFor('abcdefg1'), isNotNull);
    });
    test('三类字符通过（小写+数字+符号）', () {
      expect(PasswordPolicy.errorFor('abc123!@'), isNull);
    });
    test('四类全含通过', () {
      expect(PasswordPolicy.errorFor('Abc123!@'), isNull);
    });
  });

  group('注册页：接收验证码 → 填写验证码 → 注册', () {
    testWidgets('发送验证码进入倒计时，注册请求字段契约正确', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'))
        ..httpClientAdapter = StubAdapter(calls);
      ApiClient.debugDio = dio;

      await tester.pumpWidget(_host(const RegisterPage()));
      await runTap(tester, find.text('open'));
      await tester.pumpAndSettle(); // 完成 push 转场后再交互
      expect(find.text('注册账号'), findsOneWidget);

      // 填邮箱 → 发送验证码
      await tester.enterText(find.byType(TextField).at(0), 'user@test.com');
      await tapButton(tester, '发送验证码');
      expect(calls, isNotEmpty);
      expect(calls.first.method, 'POST');
      expect(calls.first.path.endsWith('/auth/verification/send'), isTrue);
      expect(calls.first.body, {'type': 'email', 'email': 'user@test.com'});
      // 进入倒计时，按钮不可立即重发
      expect(find.textContaining('后重发'), findsOneWidget);
      expect(find.text('发送验证码'), findsNothing);

      // 填写验证码 + 用户名 + 强密码（两次一致）
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.enterText(find.byType(TextField).at(2), 'testuser');
      await tester.enterText(find.byType(TextField).at(3), 'Abc123!@');
      await tester.enterText(find.byType(TextField).at(4), 'Abc123!@');
      // 清掉「验证码已发送」toast，让注册成功 toast 立刻可见
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .clearSnackBars();
      await tester.pump();
      // 同意条款默认**未勾选**（合规：用户必须显式同意才能注册），
      // 所以要先把整行勾上，否则会被本地校验拦下、不发注册请求
      await tickAgree(tester);
      await tapButton(tester, '注 册');
      await tester.pumpAndSettle(); // 注册成功 pop 回宿主

      final reg = calls
          .where((c) => c.path.endsWith('/auth/register') && c.body != null)
          .map((c) => c.body!)
          .last;
      expect(reg, {
        'username': 'testuser',
        'email': 'user@test.com',
        'password': 'Abc123!@',
        'verification_code': '123456',
      });
      // 返回宿主 + 成功提示
      expect(find.text('注册账号'), findsNothing);
      expect(find.text('注册成功，请登录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('弱密码本地拦截（不必等后端返回强度错误）', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'))
        ..httpClientAdapter = StubAdapter(calls);
      ApiClient.debugDio = dio;
      await tester.pumpWidget(_host(const RegisterPage()));
      await runTap(tester, find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.enterText(find.byType(TextField).at(2), 'testuser');
      await tester.enterText(find.byType(TextField).at(3), 'abcdefg1'); // 仅小写+数字
      await tester.enterText(find.byType(TextField).at(4), 'abcdefg1');
      await tapButton(tester, '注 册');
      expect(find.textContaining('密码强度不足'), findsOneWidget);
      expect(
          calls.where((c) => c.path.endsWith('/auth/register')), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('忘记密码页：接收验证码 → 填写验证码 → 重置', () {
    testWidgets('发验证码倒计时 + 重置请求字段契约正确', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'))
        ..httpClientAdapter = StubAdapter(calls);
      ApiClient.debugDio = dio;

      await tester.pumpWidget(_host(const ForgotPasswordPage()));
      await runTap(tester, find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('找回密码'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), 'user@test.com');
      await tapButton(tester, '发送验证码');
      expect(calls.first.method, 'POST');
      expect(calls.first.path.endsWith('/auth/forgot-password'), isTrue);
      expect(calls.first.body, {'email': 'user@test.com'});
      expect(find.textContaining('后重发'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(1), '654321');
      await tester.enterText(find.byType(TextField).at(2), 'NewAbc123!');
      await tester.enterText(find.byType(TextField).at(3), 'NewAbc123!');
      // 清掉「验证码已发送」toast，让重置成功 toast 立刻可见
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .clearSnackBars();
      await tester.pump();
      await tapButton(tester, '重置密码');
      await tester.pumpAndSettle();

      final reset = calls
          .where((c) => c.path.endsWith('/auth/reset-password') && c.body != null)
          .map((c) => c.body!)
          .last;
      expect(reset, {
        'email': 'user@test.com',
        'verification_code': '654321',
        'new_password': 'NewAbc123!',
      });
      expect(find.text('找回密码'), findsNothing); // 成功返回宿主
      expect(find.text('密码已重置，请使用新密码登录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('修改密码', () {
    testWidgets('请求字段契约：current_password + new_password', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'))
        ..httpClientAdapter = StubAdapter(calls);
      ApiClient.debugDio = dio;

      await tester.pumpWidget(_host(const ChangePasswordPage()));
      await runTap(tester, find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'Old123!@');
      await tester.enterText(find.byType(TextField).at(1), 'NewAbc123!');
      await tester.enterText(find.byType(TextField).at(2), 'NewAbc123!');
      await tapButton(tester, '保存新密码');
      await tester.pumpAndSettle();

      expect(calls.single.method, 'POST');
      expect(calls.single.path.endsWith('/users/change-password'), isTrue);
      expect(calls.single.body, {
        'current_password': 'Old123!@',
        'new_password': 'NewAbc123!',
      });
      expect(find.text('修改密码'), findsNothing); // 成功返回宿主
      expect(find.text('密码修改成功'), findsOneWidget);
    });
  });

  group('忘记密码页：校验失败必须有常驻可见反馈（修复「点了没反应」）', () {
    testWidgets('弱密码 → 按钮上方红字 + SnackBar；改输入后红字清除', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'))
        ..httpClientAdapter = StubAdapter(calls);
      ApiClient.debugDio = dio;

      await tester.pumpWidget(_host(const ForgotPasswordPage()));
      await runTap(tester, find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'user@test.com');
      await tester.enterText(find.byType(TextField).at(1), '654321');
      // 弱密码：只有小写+数字两种 → 不达标
      await tester.enterText(find.byType(TextField).at(2), 'abc12345');
      await tester.enterText(find.byType(TextField).at(3), 'abc12345');
      await tapButton(tester, '重置密码');
      await tester.pump();

      // 常驻红字（不随 SnackBar 消失）+ 不发请求
      expect(find.textContaining('密码强度不足'), findsWidgets);
      expect(calls.where((c) => c.path.endsWith('/auth/reset-password')), isEmpty);

      // 修改输入 → 红字清除
      await tester.enterText(find.byType(TextField).at(2), 'Abc12345!');
      await tester.pump();
      expect(find.textContaining('⚠'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('验证码缺失 → 本地拦截并提示，不发请求', (tester) async {
      _bigScreen(tester);
      final calls = <Call>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'))
        ..httpClientAdapter = StubAdapter(calls);
      ApiClient.debugDio = dio;

      await tester.pumpWidget(_host(const ForgotPasswordPage()));
      await runTap(tester, find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'user@test.com');
      await tester.enterText(find.byType(TextField).at(2), 'NewAbc123!');
      await tester.enterText(find.byType(TextField).at(3), 'NewAbc123!');
      await tapButton(tester, '重置密码');
      await tester.pump();

      expect(find.textContaining('请输入 6 位邮箱验证码'), findsWidgets);
      expect(calls.where((c) => c.path.endsWith('/auth/reset-password')), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('新密码实时规则清单随输入打勾', (tester) async {
      _bigScreen(tester);
      ApiClient.debugDio =
          Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'))
            ..httpClientAdapter = StubAdapter(<Call>[]);
      await tester.pumpWidget(_host(const ForgotPasswordPage()));
      await runTap(tester, find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('当前 0 种'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(2), 'Abc123');
      await tester.pump();
      expect(find.textContaining('当前 3 种'), findsOneWidget); // 大写+小写+数字
      await tester.pumpWidget(const SizedBox());
    });
  });
}
