// 更新地址归一化：确保应用内更新永远指向**新仓库**（moneyfly004/m-box）
// 与**新产物名**（MBox-*），不会被面板里残留的旧配置带回老 release。
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/services/update_service.dart';

void main() {
  group('normalizeReleaseUrl', () {
    test('旧仓库地址 → 新仓库（同版本/同产物名改写）', () {
      expect(
        UpdateService.normalizeReleaseUrl(
            'https://github.com/moneyfly004/moneyfly/releases/download/v0.0.1/MBox-macos-arm64-0.0.1.dmg'),
        'https://github.com/moneyfly004/m-box/releases/download/v0.0.1/MBox-macos-arm64-0.0.1.dmg',
      );
    });

    test('旧仓库 + 旧产物名 → 新仓库 + 新产物名', () {
      expect(
        UpdateService.normalizeReleaseUrl(
            'https://github.com/moneyfly004/moneyfly/releases/download/v2.2.33/MoneyFly-setup-2.2.33.exe'),
        'https://github.com/moneyfly004/m-box/releases/download/v2.2.33/MBox-setup-2.2.33.exe',
      );
    });

    test('已是新仓库/新产物名 → 原样返回（幂等）', () {
      const ok =
          'https://github.com/moneyfly004/m-box/releases/download/v0.0.1/MBox-setup-0.0.1.exe';
      expect(UpdateService.normalizeReleaseUrl(ok), ok);
    });

    test('非 GitHub 地址（面板自建 CDN）只归一化产物名', () {
      expect(
        UpdateService.normalizeReleaseUrl('https://dl.example.com/pkgs/MoneyFly-android-arm64-v8a-1.0.0.apk'),
        'https://dl.example.com/pkgs/MBox-android-arm64-v8a-1.0.0.apk',
      );
      expect(UpdateService.normalizeReleaseUrl('https://dl.example.com/pkgs/app.apk'),
          'https://dl.example.com/pkgs/app.apk');
    });

    test('空串/异常输入不崩', () {
      expect(UpdateService.normalizeReleaseUrl(''), '');
      expect(UpdateService.normalizeReleaseUrl('   '), '');
    });
  });

  group('normalizeAssetName', () {
    test('MoneyFly-* → MBox-*，其余不动', () {
      expect(UpdateService.normalizeAssetName('MoneyFly-ios-0.0.1.ipa'),
          'MBox-ios-0.0.1.ipa');
      expect(UpdateService.normalizeAssetName('MBox-ios-0.0.1.ipa'),
          'MBox-ios-0.0.1.ipa');
      expect(UpdateService.normalizeAssetName('SHA256SUMS-windows.txt'),
          'SHA256SUMS-windows.txt');
    });
  });

  test('githubRepo 指向新仓库，不是老地址', () {
    expect(UpdateService.githubRepo, 'moneyfly004/m-box');
    expect(UpdateService.githubRepo.contains('moneyfly004/moneyfly'), isFalse);
  });
}
