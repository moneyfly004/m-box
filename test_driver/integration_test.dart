// `flutter drive` 的驱动入口（配合 integration_test 使用）。
//
// 用途：`flutter drive --profile` 才能拿到真实性能数字（debug 模式的帧耗时
// 会被 JIT + 断言放大 2~3 倍，无法用来判断「卡不卡」）。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
