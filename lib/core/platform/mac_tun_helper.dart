import 'dart:convert';
import 'dart:io';


import '../services/app_log.dart';

/// macOS 的 TUN 提权（一次性授权，之后免密）。
///
/// 背景：macOS 创建 utun 网卡 + 修改路由表必须 root。Windows 可以「以管理员
/// 身份重启整个应用」，macOS 不行（整套 App 跑在 root 下会污染配置目录、
/// 而且 `open` 提权后 HOME 变成 /var/root，配置直接分叉）。
///
/// 做法（借用安装时的管理员授权思路，但不需要 pkg 安装包）：
///   1. 首次选择 TUN 时用 `osascript ... with administrator privileges` 弹一次
///      系统密码框；
///   2. 以 root 写 `/etc/sudoers.d/mbox-tun`：
///        `用户 ALL=(root) NOPASSWD: …/MBox.app/Contents/MacOS/mihomo`
///      即「只允许这个用户、免密、以 root 运行这一个内核二进制」；
///   3. 之后内核启动走 `sudo -n`，TUN 免密可用。
///
/// 安全边界：
///  - 规则只覆盖**一个**绝对路径的内核文件（在 /Applications 下，普通用户改不了）；
///  - 不用 setuid（我们的是 ad-hoc 签名，macOS 会拒绝 setuid 的非 Developer ID
///    签名二进制），也不用把整个 App 跑成 root；
///  - 内核更新（换路径/换名字）后旧规则失效 → 自动重新探测，需要时再授权一次。
class MacTunHelper {
  MacTunHelper._();

  /// 规则文件名（/etc/sudoers.d/ 下的独立文件，卸载/关闭时直接删掉即可）
  static const sudoersFile = '/etc/sudoers.d/mbox-tun';

  /// 单测注入：绕过真实 sudo 探测（测试机可能真的授权过，结果不可控）
  static bool? debugGrantedOverride;

  /// 是否已具备「免密以 root 运行该内核」的能力（bash/进程可用的探测）。
  static Future<bool> isGranted(String corePath) async {
    final override = debugGrantedOverride;
    if (override != null) return override;
    if (!Platform.isMacOS) return false;
    try {
      final r = await Process.run(
        'sudo',
        ['-n', corePath, '-v'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 8));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 一次性授权：弹管理员密码框并写入 sudoers 规则。返回 true = 已具备权限。
  ///
  /// 失败（用户取消 / 密码错）返回 false，**不改动任何状态**，调用方保持原模式。
  static Future<bool> grant(String corePath) async {
    if (!Platform.isMacOS) return false;
    final user = await _currentUser();
    if (user.isEmpty) {
      AppLog.error('macOS TUN 授权失败：拿不到当前用户名');
      return false;
    }
    // sudoers 里空格必须转义成 "\ "（.app 路径可能带空格，例如 "MBox 2.app"）
    final escapedCore = corePath.replaceAll(r'\', r'\\').replaceAll(' ', r'\ ');
    // 用 printf 写内容（避免 heredoc 与多层引号）；visudo -c 校验不过就不落地。
    final script = '''
set -e
tmp="\$(mktemp /tmp/mf-sudoers.XXXXXX)"
printf '%s\\n' '# MBox TUN —— 仅允许该用户免密以 root 运行下面这一个内核' '$user ALL=(root) NOPASSWD: $escapedCore' > "\$tmp"
VISUDO="/usr/sbin/visudo"
"\$VISUDO" -cf "\$tmp" >/dev/null
install -m 0440 -o root -g wheel "\$tmp" $sudoersFile
rm -f "\$tmp"
''';
    // 整段脚本 base64 再交给 do shell script：绕开 AppleScript 的双层转义
    final b64 = base64Encode(utf8.encode(script));
    final osascript = 'do shell script "echo $b64 | base64 -D | /bin/sh" '
        'with administrator privileges';
    try {
      final r = await Process.run(
        'osascript',
        ['-e', osascript],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(minutes: 2));
      if (r.exitCode != 0) {
        AppLog.error('macOS TUN 授权被取消/失败: ${r.stderr}');
        return false;
      }
      final ok = await isGranted(corePath);
      AppLog.log('APP', 'macOS TUN 授权完成: $ok（$corePath）');
      return ok;
    } catch (e) {
      AppLog.error('macOS TUN 授权异常: $e');
      return false;
    }
  }

  /// 撤销授权（用户关闭 TUN 且想收回权限时用；当前只在显式调用时执行）
  static Future<bool> revoke() async {
    if (!Platform.isMacOS) return false;
    try {
      final r = await Process.run('sudo', ['-n', 'rm', '-f', sudoersFile]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _currentUser() async {
    final env = Platform.environment['USER'] ?? '';
    if (env.isNotEmpty) return env;
    try {
      final r = await Process.run('id', ['-un']);
      return (r.stdout as String).trim();
    } catch (_) {
      return '';
    }
  }
}
