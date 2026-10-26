// 内核日志级别解析（sing-box 格式）回归测试。
//
// 背景：换成 sing-box 后，内核日志行形如
//   `+0800 2026-10-26 18:06:04 INFO [3230225162 0ms] inbound/mixed[mixed-in]: ...`
// 级别是行内的大写单词；旧内核才是 `time="…" level=info …`。
// 旧实现只认 `level=xxx`，于是 sing-box 的每一行都被当成 info ——
// 日志页的「级别」过滤（debug/info/warning/error）完全失效，
// 用户切到 error 仍然满屏，切到 debug 也看不到更多（实测反馈「没区别」）。
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/pages/settings/log_center_page.dart';

void main() {
  group('sing-box 日志行级别解析', () {
    test('行内大写级别（INFO / DEBUG / WARN / ERROR / FATAL）', () {
      expect(
          kernelLogLineLevel(
              '+0800 2026-10-26 18:06:04 INFO [3230225162 0ms] inbound/mixed: x'),
          'info');
      expect(
          kernelLogLineLevel(
              '+0800 2026-10-26 18:06:04 DEBUG [3230225162 1ms] router: match[0] => sniff'),
          'debug');
      expect(
          kernelLogLineLevel(
              '+0800 2026-10-26 18:06:04 WARN inbound/mixed[tun-in]: slow'),
          'warn');
      expect(
          kernelLogLineLevel(
              '+0800 2026-10-26 18:06:04 ERROR outbound/vless[n1]: dial failed'),
          'error');
      expect(
          kernelLogLineLevel(
              '+0800 2026-10-26 18:06:04 FATAL start service: start inbound/tun'),
          'fatal');
    });

    test('旧内核 level= 格式仍然兼容', () {
      expect(kernelLogLineLevel('time="2026-10-26T10:00:00Z" level=warning msg="x"'),
          'warning');
      expect(kernelLogLineLevel('level=debug msg=y'), 'debug');
    });

    test('app 自己写的提示行 → info（不参与过滤误杀）', () {
      expect(kernelLogLineLevel('[app] sing-box 已启动：/Applications/MBox.app/Contents/MacOS/sing-box'),
          'info');
      expect(kernelLogLineLevel(''), 'info');
    });

    test('级别不会误匹配节点名/路径里的单词', () {
      // 只在两侧是空白时才算级别标记
      expect(kernelLogLineLevel('+0800 18:06:04 INFO [1 0ms] outbound to API.example.com:443'),
          'info');
      expect(
          kernelLogLineLevel('+0800 18:06:04 DEBUG [1 0ms] outbound/ERROR-HANDLER[x]'),
          'debug',
          reason: '行内多个候选时取第一个（级别在最前面）');
    });
  });

  group('级别排序与过滤', () {
    test('排序：trace/debug < info < warn < error/fatal', () {
      expect(kernelLogLevelRank('trace') < kernelLogLevelRank('info'), isTrue);
      expect(kernelLogLevelRank('debug') < kernelLogLevelRank('info'), isTrue);
      expect(kernelLogLevelRank('info') < kernelLogLevelRank('warn'), isTrue);
      expect(kernelLogLevelRank('warn') < kernelLogLevelRank('error'), isTrue);
      expect(kernelLogLevelRank('error'), kernelLogLevelRank('fatal'));
      expect(kernelLogLevelRank('warning'), kernelLogLevelRank('warn'));
    });

    test('过滤语义：选 error 只留 error/fatal；选 debug 全留', () {
      final lines = [
        '+0800 18:06:04 DEBUG [1 0ms] router: match[0] => sniff',
        '+0800 18:06:04 INFO [1 0ms] inbound/mixed: inbound connection',
        '+0800 18:06:04 WARN inbound/mixed: slow',
        '+0800 18:06:04 ERROR outbound/vless: dial failed',
        '+0800 18:06:04 FATAL start service: boom',
      ];
      List<String> visible(String level) => lines
          .where((l) =>
              kernelLogLevelRank(kernelLogLineLevel(l)) >=
              kernelLogLevelRank(level))
          .toList();

      expect(visible('debug').length, 5);
      expect(visible('info').length, 4);
      expect(visible('warn').length, 3);
      expect(visible('error').length, 2);
      expect(visible('error').every((l) => l.contains('ERROR') || l.contains('FATAL')),
          isTrue);
    });
  });
}
