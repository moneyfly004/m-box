import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/utils/log_rotation.dart';
import 'package:mbox/core/utils/serial_executor.dart';

void main() {
  group('keepSecondHalf（日志旋转）', () {
    test('多行内容按整行截断，保留后半', () {
      expect(keepSecondHalf('a\nb\nc\nd\n'), 'd\n');
    });

    test('无换行的超长单行按中点硬截断（否则 512KB 上限失效、文件无界增长）', () {
      // 旧契约是「原样返回」，但那等于超长单行永不截断 → 上限失效 +
      // 每次写入全量读回（O(n²)）。现按中点截断，保留后半段。
      expect(keepSecondHalf('abcdefghij'), 'fghij');
    });

    test('换行在末尾时同样截断，但绝不产出空内容', () {
      final s = keepSecondHalf('abc\n');
      expect(s, 'c\n');
      expect(s.isNotEmpty, isTrue);
    });

    test('超长单行截断后长度必然减半（上限真正生效）', () {
      final big = 'x' * 100000;
      expect(keepSecondHalf(big).length, lessThanOrEqualTo(big.length ~/ 2 + 1));
    });

    test('emoji（代理对）不会被切成半个字符', () {
      final content = '😀😀😀😀😀\n😀😀😀😀😀\n';
      final s = keepSecondHalf(content);
      // 结果必须是原文后缀，且不以低代理（半个 emoji）开头
      expect(content.endsWith(s), isTrue);
      if (s.isNotEmpty) {
        final first = s.codeUnitAt(0);
        expect(first >= 0xDC00 && first <= 0xDFFF, isFalse);
      }
    });
  });

  group('SerialExecutor（串行执行）', () {
    test('任务按入队顺序串行执行', () async {
      final ex = SerialExecutor();
      final order = <String>[];
      await Future.wait([
        ex.run(() async => order.add('a')),
        ex.run(() async => order.add('b')),
        ex.run(() async => order.add('c')),
      ]);
      expect(order, ['a', 'b', 'c']);
    });

    test('单个任务失败不中断后续任务', () async {
      final ex = SerialExecutor();
      final order = <String>[];
      final failing = ex.run(() async {
        order.add('x');
        throw StateError('boom');
      });
      final ok = ex.run(() async => order.add('y'));
      await expectLater(failing, throwsStateError);
      await ok;
      expect(order, ['x', 'y']);
    });
  });
}
