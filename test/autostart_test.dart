// 开机自启：回归「开关显示已开启、系统里什么都没注册」这个实测 bug。
//
// 旧实现（设置页直接调插件）有两个致命点，这里各有用例钉住：
//   1) 从未调用 `launchAtStartup.setup(appName, appPath)` → 插件内部保持
//      AppAutoLauncherImplNoop → enable()/disable() 抛 UnsupportedError；
//   2) 调用点是 `unawaited(enable())`，异常被吞 → 设置项却已经落盘，
//      于是开关显示「已开启」而注册从未发生。
// 现在由 [AutostartService] 统一：**先 setup**、失败返回 false 且抛不出异常，
// 调用方据此决定设置项是否落盘。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/autostart.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假后端：记录调用、可配置返回值与抛错（复刻 Noop 的 UnsupportedError）
class _FakeBackend implements AutostartBackend {
  _FakeBackend({
    this.enableResult = true,
    this.disableResult = true,
    this.isEnabledResult = false,
    this.throwOn,
  });

  final bool enableResult;
  final bool disableResult;
  final bool isEnabledResult;

  /// 'enable' / 'disable' / 'isEnabled' → 抛异常（模拟 Noop / 缺原生实现）
  final String? throwOn;

  int setupCalls = 0;
  String? lastAppName;
  String? lastAppPath;
  int enableCalls = 0;
  int disableCalls = 0;
  int isEnabledCalls = 0;

  @override
  void setup({required String appName, required String appPath}) {
    setupCalls++;
    lastAppName = appName;
    lastAppPath = appPath;
  }

  @override
  Future<bool> enable() async {
    enableCalls++;
    if (throwOn == 'enable') throw UnsupportedError('enable');
    return enableResult;
  }

  @override
  Future<bool> disable() async {
    disableCalls++;
    if (throwOn == 'disable') throw UnsupportedError('disable');
    return disableResult;
  }

  @override
  Future<bool> isEnabled() async {
    isEnabledCalls++;
    if (throwOn == 'isEnabled') throw UnsupportedError('isEnabled');
    return isEnabledResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => AutostartService.resetForTest());
  tearDown(() => AutostartService.resetForTest());

  group('AutostartService：setup 必须先发生（旧 bug 的根因）', () {
    test('enable 前自动完成 setup，且注册名/路径正确', () async {
      final fake = _FakeBackend();
      AutostartService.debugBackend = fake;

      expect(await AutostartService.enable(), isTrue);
      expect(fake.setupCalls, 1, reason: '未 setup 就会退化成 Noop → 注册静默失效');
      expect(fake.lastAppName, 'MBox');
      expect(fake.lastAppPath, isNotEmpty);
    });

    test('多次调用只 setup 一次（幂等）', () async {
      final fake = _FakeBackend();
      AutostartService.debugBackend = fake;

      await AutostartService.enable();
      await AutostartService.disable();
      await AutostartService.isEnabled();
      expect(fake.setupCalls, 1);
    });
  });

  group('AutostartService：失败不抛、返回 false（让调用方决定是否落盘）', () {
    test('后端抛 UnsupportedError（Noop / 缺原生实现）→ false，不外抛', () async {
      final fake = _FakeBackend(throwOn: 'enable');
      AutostartService.debugBackend = fake;

      expect(await AutostartService.enable(), isFalse);
      expect(fake.enableCalls, 1);
    });

    test('后端返回 false（注册未生效）→ 原样返回 false', () async {
      final fake = _FakeBackend(enableResult: false);
      AutostartService.debugBackend = fake;
      expect(await AutostartService.enable(), isFalse);
    });

    test('isEnabled 抛异常 → 返回 null（调用方知道「取不到」，不误判为关闭）', () async {
      final fake = _FakeBackend(throwOn: 'isEnabled');
      AutostartService.debugBackend = fake;
      expect(await AutostartService.isEnabled(), isNull);
    });

    test('disable 返回 false（取消注册未生效）→ 原样返回 false', () async {
      final fake = _FakeBackend(disableResult: false);
      AutostartService.debugBackend = fake;
      expect(await AutostartService.disable(), isFalse);
    });

    test('disable 抛异常 → false，不外抛', () async {
      final fake = _FakeBackend(throwOn: 'disable');
      AutostartService.debugBackend = fake;
      expect(await AutostartService.disable(), isFalse);
    });
  });

  group('syncOnStartup：让系统注册与设置项一致', () {
    test('设置开着但系统里没有 → 补注册（换目录/被清理后自愈）', () async {
      final fake = _FakeBackend(isEnabledResult: false);
      AutostartService.debugBackend = fake;

      await AutostartService.syncOnStartup(prefEnabled: true);
      expect(fake.enableCalls, 1);
      expect(fake.disableCalls, 0);
    });

    test('设置开着且系统里已有 → 不重复注册', () async {
      final fake = _FakeBackend(isEnabledResult: true);
      AutostartService.debugBackend = fake;

      await AutostartService.syncOnStartup(prefEnabled: true);
      expect(fake.enableCalls, 0);
    });

    test('设置关着但系统里还注册着（旧版本残留）→ 清掉，避免「关了还自启」', () async {
      final fake = _FakeBackend(isEnabledResult: true);
      AutostartService.debugBackend = fake;

      await AutostartService.syncOnStartup(prefEnabled: false);
      expect(fake.disableCalls, 1);
    });

    test('状态取不到（macOS 插件不可用）→ 什么都不做，更不能误 disable', () async {
      final fake = _FakeBackend(throwOn: 'isEnabled');
      AutostartService.debugBackend = fake;

      await AutostartService.syncOnStartup(prefEnabled: false);
      expect(fake.disableCalls, 0);
      expect(fake.enableCalls, 0);
    });
  });

  group('注册路径：Windows/Linux 用 exe，macOS 用 App bundle', () {
    test('Windows 路径原样使用（注册表值就是 exe 绝对路径）', () {
      expect(
        AutostartService.resolveLaunchPath(
            resolvedExecutable: r'D:\MBox\mbox.exe', isMacOS: false),
        r'D:\MBox\mbox.exe',
      );
    });

    test('macOS 从 bundle 内二进制回溯到 .app（启动项要拉起整个 app）', () {
      expect(
        AutostartService.resolveLaunchPath(
            resolvedExecutable:
                '/Applications/MBox.app/Contents/MacOS/MBox',
            isMacOS: true),
        '/Applications/MBox.app',
      );
    });

    test('宿主平台不影响判定：POSIX 与 Windows 分隔符都能识别（CI 踩过的坑）', () {
      // 这条在 Windows 上跑时曾失败：旧实现用 Platform.pathSeparator 拼 '\\Contents\\'，
      // 而输入是 macOS 路径（/Contents/）→ 匹配不上就原样返回。
      for (final p in [
        '/Applications/MBox.app/Contents/MacOS/MBox',
        r'C:\Applications\MBox.app\Contents\MacOS\MBox',
      ]) {
        final out = AutostartService.resolveLaunchPath(
            resolvedExecutable: p, isMacOS: true);
        expect(out.endsWith('MBox.app'), isTrue, reason: '未回溯到 bundle：$out');
        expect(out.contains('Contents'), isFalse, reason: '仍带着 bundle 内部路径：$out');
      }
    });

    test('macOS 上取不到 bundle 结构时退化为原路径（不猜、不乱改）', () {
      expect(
        AutostartService.resolveLaunchPath(
            resolvedExecutable: '/tmp/mbox', isMacOS: true),
        '/tmp/mbox',
      );
    });
  });
  _settingsPageCases();
}

/// 点开关：必须用 runAsync 让真实异步完成 —— 设置写盘走 SerialExecutor +
/// SharedPreferences 通道，纯 fake-async 的 pump 未必推进它们（仓库惯例同
/// pages_test.dart 的 tapSettle）。
Future<void> _tapSwitch(WidgetTester tester, Finder row) async {
  await tester.runAsync(() async {
    await tester.tap(find.descendant(of: row.first, matching: find.byType(Switch)));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pump();
  await tester.pump();
}

/// 端到端：设置页开关的真实行为（旧 bug 的核心 —— 开关说「开了」但系统没注册）
///
/// 用注入的假后端，保证在任意平台（CI 的 Windows/Linux 也在内）都确定：
/// - 后端失败 → 设置项**不落盘**、弹提示（开关弹回关闭）
/// - 后端成功 → 设置项落盘为 true
void _settingsPageCases() {
  group('设置页开关：失败不落盘', () {
    testWidgets('注册失败 → 提示 + 设置保持关闭（旧实现是写进设置并静默失败）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      AutostartService.debugBackend = _FakeBackend(enableResult: false);

      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pump(const Duration(milliseconds: 300));

      final row = find.ancestor(
        of: find.text(AppStrings.t('settings_launch_startup')),
        matching: find.byType(Row),
      );
      expect(row, findsWidgets, reason: '找不到开机自试行');
      await _tapSwitch(tester, row);

      // 提示出现
      expect(find.text(AppStrings.t('launch_at_startup_failed')), findsOneWidget);
      // 设置项没有被写成「开着」
      final settings = await SettingsStore.instance.load();
      expect(settings['launchAtStartup'], isFalse);
      // 开关回到关闭
      final sw = tester.widget<Switch>(find.descendant(
          of: find.ancestor(
              of: find.text(AppStrings.t('settings_launch_startup')),
              matching: find.byType(Row)).first,
          matching: find.byType(Switch)));
      expect(sw.value, isFalse);
    });

    testWidgets('注册成功 → 设置落盘为 true', (tester) async {
      SharedPreferences.setMockInitialValues({});
      AutostartService.debugBackend = _FakeBackend(enableResult: true);

      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pump(const Duration(milliseconds: 300));

      final row = find.ancestor(
        of: find.text(AppStrings.t('settings_launch_startup')),
        matching: find.byType(Row),
      );
      await _tapSwitch(tester, row);

      final settings = await SettingsStore.instance.load();
      expect(settings['launchAtStartup'], isTrue);
      expect(find.text(AppStrings.t('launch_at_startup_failed')), findsNothing);
    });
  });
}
