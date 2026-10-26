import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/theme/app_theme.dart';

void main() {
  test('formatPrice 去掉无意义尾零，保留真实小数', () {
    expect(formatPrice(0.02), '0.02'); // 修复：0.02 元不再显示成 0
    expect(formatPrice(200.0), '200');
    expect(formatPrice(200.5), '200.5');
    expect(formatPrice(0.0), '0');
    expect(formatPrice(57.89), '57.89');
    expect(formatPrice(0.1), '0.1');
    expect(formatPrice(277.2), '277.2');
  });
}
