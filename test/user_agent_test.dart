import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/api/user_agent.dart';

void main() {
  group('UserAgent.build', () {
    test('无 OS 信息时退化为裸 MBox/<版本>', () {
      expect(UserAgent.build(version: '0.0.1'), 'MBox/0.0.1');
      expect(UserAgent.build(version: '1.2.3', osSection: '  '),
          'MBox/1.2.3');
    });

    test('带 OS 特征串时拼成 MBox/<版本> (<OS>)', () {
      expect(
        UserAgent.build(
            version: '1.0.0', osSection: 'Windows NT 10.0'),
        'MBox/1.0.0 (Windows NT 10.0)',
      );
    });
  });

  group('各平台特征串（对应后端 ParseUserAgent 的解析格式）', () {
    test('Windows → Windows NT x.y，后端识别为 Windows/desktop', () {
      expect(UserAgent.windowsSection(10, 0), 'Windows NT 10.0');
    });

    test('macOS → Macintosh; Mac OS X <maj>_<min>，后端解析 OS 版本 14.5', () {
      expect(UserAgent.macosSection(14, 5),
          'Macintosh; Mac OS X 14_5');
    });

    test('Android → Linux; Android <release>[; <model> Build/<id>]', () {
      expect(
        UserAgent.androidSection('14', 'Pixel 8', 'TQ3A.230805.001'),
        'Linux; Android 14; Pixel 8 Build/TQ3A.230805.001',
      );
      // 无型号/构建号时仍保留 Android release（OS/移动端仍可识别）
      expect(UserAgent.androidSection('13', '', ''),
          'Linux; Android 13');
    });

    test('iOS → iPhone<machine>; iOS <ver>', () {
      expect(UserAgent.iosSection('14,5', '17.5.1'),
          'iPhone14,5; iOS 17.5.1');
    });
  });

  group('完整 UA 与后端正则逐条对齐', () {
    // 与 ~/Downloads/myweb/internal/services/device/device_manager.go 的
    // parseOSInfo / reAndroidVersion / reAndroidBuild / reWindowsNT / reMacOSX 对齐
    test('Windows UA：版本号取 MBox 段而非 OS 段', () {
      final ua = UserAgent.build(
          version: '0.1.0', osSection: UserAgent.windowsSection(10, 0));
      expect(ua, 'MBox/0.1.0 (Windows NT 10.0)');
      // 后端 parseVersion 首个 x.y.z = 0.1.0（左起最先出现）
      expect(RegExp(r'(\d+\.\d+\.\d+)').firstMatch(ua)!.group(1), '0.1.0');
      // 后端 reWindowsNT 捕获 10.0
      expect(
        RegExp(r'Windows\s+NT\s+(\d+\.\d+)').firstMatch(ua)!.group(1),
        '10.0',
      );
    });

    test('macOS UA：后端 reMacOSX 将 14_5 规整为 14.5', () {
      final ua = UserAgent.build(
          version: '1.0.0', osSection: UserAgent.macosSection(14, 5));
      expect(
        RegExp(r'Mac OS X\s+(\d+[._]\d+)')
            .firstMatch(ua)!
            .group(1)!
            .replaceAll('_', '.'),
        '14.5',
      );
    });

    test('Android UA：后端识别 Android 版本与型号', () {
      final ua = UserAgent.build(
        version: '1.0.0',
        osSection: UserAgent.androidSection('14', 'Pixel 8', 'UD1A.230803.041'),
      );
      expect(RegExp(r'Android\s+(\d+[.\d]*)').firstMatch(ua)!.group(1), '14');
      expect(
        RegExp(r';\s*([^;]+)\s*build', caseSensitive: false)
            .firstMatch(ua)!
            .group(1)!
            .trim(),
        'Pixel 8',
      );
    });

    test('iOS 机型串不重复加 iPhone 前缀（utsname.machine 本身已带）', () {
      expect(UserAgent.iosSection('iPhone14,3', '16.6.1'),
          'iPhone14,3; iOS 16.6.1');
      expect(UserAgent.iosSection('iPad8,1', '17.0'), 'iPad8,1; iOS 17.0');
      // 兜底：机型串没有前缀时补上，后端正则仍能解析出机型
      expect(UserAgent.iosSection('14,3', '16.6.1'), 'iPhone14,3; iOS 16.6.1');
    });

    test('UA 前缀是品牌 MBox（后端 software_name 靠它识别；可用 dart-define 覆盖）', () {
      expect(UserAgent.brand, 'MBox');
      expect(UserAgent.build(version: '0.0.1'), 'MBox/0.0.1');
      expect(UserAgent.build(version: '0.0.1', osSection: 'Windows NT 10.0'),
          'MBox/0.0.1 (Windows NT 10.0)');
    });
  });
}
