import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/api/user_agent.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/services/device_fingerprint.dart';
import 'package:mbox/core/services/local_paths.dart';
import 'package:mbox/pages/devices/devices_page.dart';

/// 硬件指纹（X-MF-Device-Fp）——「同一台机器重装/升级后不再多占设备名额」的客户端半边。
///
/// 生产背景：老站用户 susanzhang1230 只有 iPhone + 一台 Windows，后台显示 3 台；
/// 根因是 Windows 安装包升级时旧卸载程序删了应用数据，install_id 丢失，
/// 同一台电脑被后端当成新设备。硬件指纹跨安装实例不变，后端据此认回老行。
void main() {
  setUp(() {
    DeviceFingerprint.resetCache();
    DeviceFingerprint.debugRawValue = null;
    UserAgent.deviceHeaders = {};
  });

  tearDown(() {
    DeviceFingerprint.debugRawValue = null;
    DeviceFingerprint.resetCache();
    LocalPaths.debugSupportDir = null;
    UserAgent.deviceHeaders = {};
  });

  group('DeviceFingerprint', () {
    test('同一硬件值 → 摘要稳定；不同硬件值 → 不同摘要', () async {
      DeviceFingerprint.debugRawValue = () async => 'win:11111111-2222-3333-4444-555555555555';
      final a = await DeviceFingerprint.resolve();
      DeviceFingerprint.resetCache();
      final a2 = await DeviceFingerprint.resolve();
      expect(a, isNotEmpty);
      expect(a2, a, reason: '同一台机器每次算出的指纹必须一致');

      DeviceFingerprint.resetCache();
      DeviceFingerprint.debugRawValue = () async => 'win:99999999-2222-3333-4444-555555555555';
      final b = await DeviceFingerprint.resolve();
      expect(b, isNot(a), reason: '不同机器必须得到不同指纹');
    });

    test('摘要长度固定且为十六进制（后端字段 varchar(64)）', () async {
      DeviceFingerprint.debugRawValue = () async => 'mac:AAAA-BBBB';
      final fp = await DeviceFingerprint.resolve();
      expect(fp.length, 32);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(fp), isTrue);
    });

    test('读不到硬件值 → 空串（不加请求头，后端行为不变）', () async {
      DeviceFingerprint.debugRawValue = () async => '';
      expect(await DeviceFingerprint.resolve(), '');
    });

    test('读取抛异常 → 空串而不是崩溃', () async {
      DeviceFingerprint.debugRawValue = () async => throw StateError('no permission');
      expect(await DeviceFingerprint.resolve(), '');
    });

    test('同一进程内只读取一次（缓存）', () async {
      var calls = 0;
      DeviceFingerprint.debugRawValue = () async {
        calls++;
        return 'win:fixed';
      };
      await DeviceFingerprint.resolve();
      await DeviceFingerprint.resolve();
      expect(calls, 1);
    });
  });

  group('请求头注入', () {
    test('安装 ID 与硬件指纹都随请求发出', () async {
      final dir = await Directory.systemTemp.createTemp('mf_hwfp');
      addTearDown(() => dir.delete(recursive: true));
      LocalPaths.debugSupportDir = () async => dir;
      DeviceFingerprint.debugRawValue = () async => 'win:pc-1';

      await UserAgent.resolve(version: '2.2.29');

      expect(UserAgent.deviceHeaders['X-MF-Device-Id'], isNotEmpty,
          reason: '安装实例 ID 必须继续上报（后端首选的精确身份）');
      final fp = UserAgent.deviceHeaders['X-MF-Device-Fp'];
      expect(fp, isNotNull, reason: '硬件指纹必须上报，否则重装后仍会多出设备行');
      expect(fp, isNotEmpty);
    });

    test('硬件指纹读不到时只少一个头，安装 ID 照发', () async {
      final dir = await Directory.systemTemp.createTemp('mf_hwfp2');
      addTearDown(() => dir.delete(recursive: true));
      LocalPaths.debugSupportDir = () async => dir;
      DeviceFingerprint.debugRawValue = () async => '';

      await UserAgent.resolve(version: '2.2.29');

      expect(UserAgent.deviceHeaders['X-MF-Device-Id'], isNotEmpty);
      expect(UserAgent.deviceHeaders.containsKey('X-MF-Device-Fp'), isFalse);
    });
  });

  group('本机识别（设备列表）', () {
    DeviceInfo dev({String fp = '', String model = '', String brand = ''}) => DeviceInfo(
          id: 1,
          deviceName: 'PC',
          deviceType: 'desktop',
          deviceModel: model,
          deviceBrand: brand,
          deviceHwFp: fp,
          ipAddress: '',
          location: '',
          osName: 'Windows',
          osVersion: '10',
          softwareName: 'MBox',
          softwareVersion: '2.2.29',
          isActive: true,
          isAllowed: true,
          lastSeen: '',
          lastAccess: '',
          firstSeen: '',
          accessCount: 1,
          remark: '',
        );

    test('后端下发硬件指纹时按指纹精确判定（同型号别人的机器不算本机）', () {
      final headers = {
        'X-MF-Device-Model': 'Windows 10 Pro',
        'X-MF-Device-Brand': 'PC',
        'X-MF-Device-Fp': 'aaaa1111',
      };
      expect(isCurrentDeviceEntry(dev(fp: 'aaaa1111', model: 'Windows 10 Pro', brand: 'PC'), headers), isTrue);
      expect(isCurrentDeviceEntry(dev(fp: 'bbbb2222', model: 'Windows 10 Pro', brand: 'PC'), headers), isFalse,
          reason: '同型号的另一台电脑不能被标成「本机」（否则删本机的引导会走错）');
    });

    test('缺硬件指纹（旧后端/读不到）时退回机型品牌启发式', () {
      final headers = {'X-MF-Device-Model': 'Windows 10 Pro', 'X-MF-Device-Brand': 'PC'};
      expect(isCurrentDeviceEntry(dev(model: 'Windows 10 Pro', brand: 'PC'), headers), isTrue);
      expect(isCurrentDeviceEntry(dev(model: 'iPhone14,3', brand: 'Apple'), headers), isFalse);
    });

    test('设备行有指纹但本机没上报时仍可用机型兜底', () {
      final headers = {'X-MF-Device-Model': 'Windows 10 Pro', 'X-MF-Device-Brand': 'PC'};
      expect(isCurrentDeviceEntry(dev(fp: 'cccc3333', model: 'Windows 10 Pro', brand: 'PC'), headers), isTrue);
    });

    test('解析后端 device_hw_fp 字段', () {
      final d = DeviceInfo.fromJson({
        'id': 7,
        'device_name': 'PC',
        'device_type': 'desktop',
        'device_model': 'Windows 10 Pro',
        'device_brand': 'PC',
        'device_hw_fp': 'abcd1234',
        'is_active': true,
        'is_allowed': true,
      });
      expect(d.deviceHwFp, 'abcd1234');
    });
  });
}
