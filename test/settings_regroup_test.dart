// 设置页重排（2.2.23）回归测试：
//   1) 8 个分组标题都在，且纵向顺序符合「按用户意图分组」的方案；
//   2) **不丢功能**：重排前列出的每一个设置行/入口都能在新版页面里找到
//      （逐条断言，不是抽样）；
//   3) 同类功能确实集中：新增的「测速」组里四项（自动测速/间隔/方式/地址）
//      都落在组标题下方；①组里不再有测速项；
//   4) 设置项搜索：按文案与 i18n key 都能命中，未命中的行消失，搜不到有空态。
//
// 实现要点：把测试视口设成「很高的一张纸」（1200×4000），让 ListView 一次
// 建出全部行 —— 不依赖 scrollUntilVisible 的单向滚动（它会因为「目标在当前位置
// 上方」而永远找不到，且懒加载会让离屏行根本不存在）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/settings/settings_page.dart';
import 'package:mbox/theme/app_theme.dart';
import 'package:mbox/widgets/mf_row.dart';

/// 新版分组顺序（组标题 key，按页面从上到下）
const _groupOrder = [
  'group_connect',
  'group_speedtest',
  'group_dns_split',
  'group_subscription_update',
  'group_account',
  'group_notify',
  'group_appearance',
  'group_about',
];

/// 重排前页面里的**每一个**设置行/入口（i18n key），逐条必须在。
const _allRows = <String>[
  // ① 连接与内核
  'settings_default_mode',
  'settings_auto_connect',
  'settings_reconnect',
  'settings_local_port',
  'settings_clash_api_port',
  'settings_kernel',
  'settings_geo_data',
  // ② 测速
  'settings_auto_test',
  'settings_test_interval',
  'settings_speed_mode',
  'settings_test_url',
  // ③ DNS 与分流
  'settings_dns',
  'settings_dns_mode',
  'settings_fakeip_extra',
  'settings_bypass_lan',
  'settings_bypass',
  'settings_udp_insecure',
  // ④ 订阅与更新
  'settings_subscribe_ua',
  'settings_server_line',
  // ⑤ 账号与安全
  'settings_change_pwd',
  'profile_devices',
  'settings_clear_data',
  // ⑥ 通知与提醒
  'settings_notify',
  // ⑦ 外观与语言
  'settings_theme',
  'settings_language',
  // ⑧ 诊断与关于
  'log_center_title',
  'settings_crash_report',
  'settings_licenses',
];

/// 桌面独占行（macOS/Windows/Linux 才显示；Android/iOS 隐藏）
const _desktopRows = <String>[
  'settings_launch_startup',
  'close_action',
  'settings_tun',
];

/// 只在 Android/Windows/macOS 显示的桌面平台行（**Linux 上本来就不显示**，
/// 与重排无关 —— 见 settings_page 里原来的 `Platform.isAndroid || isWindows || isMacOS`）
const _autoDownloadRow = 'settings_auto_download_update';

/// Android 独占行
const _androidOnlyRows = <String>[
  'settings_tun_stack',
  'settings_access',
];

/// 当前平台应该**看不到**的行（平台门控，防止重排时误把某平台的隐藏行放出来）
List<String> _expectedAbsentRows() => <String>[
      if (Platform.isAndroid || Platform.isIOS) ..._desktopRows,
      if (Platform.isLinux) _autoDownloadRow,
      if (!Platform.isAndroid) ..._androidOnlyRows,
    ];

/// 当前平台应该**看得到**的行（与页面里的 Platform 条件一一对应）
List<String> _expectedRows() => <String>[
      ..._allRows,
      if (!Platform.isAndroid && !Platform.isIOS) ..._desktopRows,
      if (Platform.isAndroid || Platform.isWindows || Platform.isMacOS)
        _autoDownloadRow,
      if (Platform.isAndroid) ..._androidOnlyRows,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'mbox_lang': 'zh'}));

  /// 用「一张很高的纸」渲染设置页：所有行一次建出，避免懒加载/单向滚动的坑
  Future<void> pumpTall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ConnectionController.instance),
        ChangeNotifierProvider.value(value: AccountService.instance),
      ],
      child: MaterialApp(theme: buildMBoxTheme(), home: const SettingsPage()),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('8 个分组标题都在，且纵向顺序符合重排方案', (tester) async {
    await pumpTall(tester);

    double? prevY;
    for (final key in _groupOrder) {
      final title = AppStrings.t(key);
      final f = find.text(title);
      expect(f, findsOneWidget, reason: '分组标题「$title」缺失（$key）');
      final y = tester.getTopLeft(f).dy;
      debugPrint('[group] $key → "$title" y=$y');
      if (prevY != null) {
        expect(y, greaterThan(prevY), reason: '分组顺序不对：$key 应在上一组之下');
      }
      prevY = y;
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('不丢功能：重排前每一个设置行都能在新版页面找到（按当前平台）', (tester) async {
    await pumpTall(tester);

    final expected = _expectedRows();
    final missing = <String>[];
    final duplicated = <String>[];
    for (final key in expected) {
      final text = AppStrings.t(key);
      final n = find.text(text).evaluate().length;
      if (n == 0) missing.add('$key("$text")');
      if (n > 1) duplicated.add('$key("$text")×$n');
    }
    debugPrint('[rows] 平台=${Platform.operatingSystem} 检查 ${expected.length} 项，'
        '缺失 ${missing.length}，重复 ${duplicated.length}');
    expect(missing, isEmpty, reason: '以下设置项在新版设置页里找不到了：$missing');
    expect(duplicated, isEmpty, reason: '以下设置项在页面上出现了多次（重排时复制粘贴漏删）：$duplicated');
    expect(expected.length, greaterThan(25), reason: '清单本身要有足够覆盖度');

    // 反向：平台门控行不得在本平台出现（重排时误放出来会被这条抓住）
    final leaked = <String>[];
    for (final key in _expectedAbsentRows()) {
      if (find.text(AppStrings.t(key)).evaluate().isNotEmpty) {
        leaked.add(key);
      }
    }
    expect(leaked, isEmpty, reason: '以下行在当前平台不应显示：$leaked');
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('同类功能集中：测速四项都在「测速」组标题之下', (tester) async {
    await pumpTall(tester);

    final groupY =
        tester.getTopLeft(find.text(AppStrings.t('group_speedtest'))).dy;
    for (final key in const [
      'settings_auto_test',
      'settings_test_interval',
      'settings_speed_mode',
      'settings_test_url',
    ]) {
      final f = find.text(AppStrings.t(key));
      expect(f, findsOneWidget, reason: '$key 缺失');
      final y = tester.getTopLeft(f).dy;
      debugPrint('[speed] $key y=$y（组标题 y=$groupY）');
      expect(y, greaterThan(groupY),
          reason: '${AppStrings.t(key)} 必须在「测速」组标题之下（同类功能集中）');
    }

    // ①组（连接与内核）里不应再出现任何测速项：它们都在测速组标题下方，
    // 而①组标题在测速组标题上方 —— 用「测速项 y > groupY」已经证明这一点。
    final connectY =
        tester.getTopLeft(find.text(AppStrings.t('group_connect'))).dy;
    expect(groupY, greaterThan(connectY));
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('设置项搜索：按文案命中，未命中的行消失，搜不到有空态', (tester) async {
    await pumpTall(tester);

    await tester.enterText(find.byType(TextField).first, '测速');
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.t('settings_speed_mode')), findsOneWidget);
    expect(find.text(AppStrings.t('settings_test_url')), findsOneWidget);
    expect(find.text(AppStrings.t('settings_auto_test')), findsOneWidget);
    // 未命中的行必须消失
    expect(find.text(AppStrings.t('settings_language')), findsNothing);
    expect(find.text(AppStrings.t('settings_clear_data')), findsNothing);
    expect(find.text(AppStrings.t('settings_dns')), findsNothing);

    // 按 i18n key 也能搜（英文环境/记得 key 的用户）
    await tester.enterText(find.byType(TextField).first, 'tun');
    await tester.pumpAndSettle();
    if (!Platform.isAndroid && !Platform.isIOS) {
      expect(find.text(AppStrings.t('settings_tun')), findsOneWidget);
    }
    expect(find.text(AppStrings.t('settings_language')), findsNothing);

    // 搜不到时给出明确空态（不能白屏）
    await tester.enterText(find.byType(TextField).first, 'zzz-not-exist');
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.t('settings_search_empty')), findsOneWidget);

    // 清空后恢复全部设置项
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.t('settings_language')), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('通知开关：默认开（既有键 notify 默认 true），关掉后落盘 notify=false', (tester) async {
    SharedPreferences.setMockInitialValues({});
    SettingsStore.resetForTest();
    await pumpTall(tester);

    final row = find.ancestor(
        of: find.text(AppStrings.t('settings_notify')),
        matching: find.byType(MBRow));
    expect(row, findsOneWidget, reason: '「允许通知」行必须存在');
    final sw = find.descendant(of: row, matching: find.byType(Switch));
    expect(sw, findsOneWidget);

    // 默认（settings 里没有 notify 键）= 开：与 SettingsStore._defaults() 一致，
    // 也就是说这次改动不会改变任何老用户的通知行为
    expect(tester.widget<Switch>(sw).value, isTrue);

    await tester.tap(sw);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(sw).value, isFalse);

    final saved = await SettingsStore.instance.load();
    debugPrint('[notify] 落盘 notify=${saved['notify']}');
    expect(saved['notify'], isFalse, reason: '开关必须落到既有 settings 键 notify');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
