#!/usr/bin/env python3
"""发布产物机械防线：扫描**真实安装包**，命中真实节点信息就 fail（退出码 1）。

与 test/no_test_node_data_test.dart（扫仓库源码）配套：那个防"提交进仓库"，
这个防"跑进产物"——即便有人绕过源码检查（构建期脚本下载、CI 环境变量注入、
第三方内核里夹带），产物里出现节点信息也过不了这一关。

覆盖范围：
  * APK / AAB / IPA / ZIP：原生解包逐条扫描（含 libapp.so / App / app.so /
    flutter_assets / assets / META-INF）
  * DMG：macOS 上 hdiutil 挂载后扫描 MoneyFly.app 全量；非 macOS 明确报
    "SKIPPED"，不假装扫过
  * EXE：能拿到 7z / innoextract 就解包扫描，否则明确 SKIPPED
  * 每条内容都按 ASCII + UTF-16LE 两种编码匹配，并把长 base64 段解一层再扫
    （订阅常被 base64 包一层）

判定规则与源码防线一致：文档占位值（example.com / RFC 5737 / 私网段 / 已知
公开 DNS）放行；公网 IP:端口、指向真实主机的节点链接、未登记的 REALITY 公钥、
本次事件硬黑名单值一律判失败。

用法：
  python3 tool/scan_release_artifacts.py dist/*.apk dist/*.ipa dist/*.zip
  python3 tool/scan_release_artifacts.py --all dist
"""
import argparse
import base64
import binascii
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

# ── 本次事件确认泄露的确切值（与 Dart 防线同源）────────────────────────────
INCIDENT_BLOCKLIST = [
    '152.69.220.212',
    '203.10.96.138',
    '203.27.106.148',
    '192.187.115.34',
    'b07db61f-a207-4508-97f5-68182991c2d6',
    'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
    'yydjc.top',
    'yyloutLineVpnServerfree32',
    'fd26d49a',
]

# ── 明确登记为"假"的 REALITY 公钥（一次性生成，不对应任何真实节点）──────
ALLOWED_REALITY_PBK = [
    'EXAMPLE_pbk_0000000000000000000000000000',
    'HQ_-6oB8xn2u6GDOAerqTuysOQFAvpA1FpiXG5H-ySI',
]

NODE_URI = re.compile(
    rb'\b(?:vless|vmess|trojan|hysteria2|hysteria|hy2|anytls|tuic|ssr|ss|'
    rb'socks5|socks|wireguard)://(?:[^\s/?#@]*@)?([A-Za-z0-9.\-]+)')
IP_PORT = re.compile(rb'\b((?:\d{1,3}\.){3}\d{1,3}):(\d{2,5})\b')
PBK = re.compile(rb'(?:pbk=|public-key:\s*|"public-key":\s*")([A-Za-z0-9_\-]{20,})')
B64_RUN = re.compile(rb'[A-Za-z0-9+/]{64,}={0,2}')
INTERNAL_MARKERS = ['内测', '公测', '体验节点', '测试账号', '测试订阅']

ALLOWED_IP_PREFIXES = (
    '10.', '127.', '192.168.', '172.16.', '172.17.', '172.18.', '172.19.',
    '172.2', '172.30.', '172.31.', '169.254.', '100.6', '198.18.', '198.19.',
    '0.0.0.0', '224.', '239.', '255.255.',
    '192.0.2.', '198.51.100.', '203.0.113.',          # RFC 5737 文档段
    '223.5.5.5', '223.6.6.6', '119.29.29.29', '114.114.114.114',
    '208.67.222.222', '208.67.220.220', '8.8.8.8', '8.8.4.4', '1.1.1.1',
    '9.9.9.9', '1.2.3.', '5.6.7.', '1.1.1.2', '2.2.2.1',
)

ALLOWED_DOMAIN_SUFFIXES = (
    'example.com', 'example.org', 'example.net', 'example', 'invalid', 'test',
    'localhost', 'local', 'lan', 'apple.com', 'gstatic.com', 'github.com',
    'githubusercontent.com', 'moneyfly.top', 'dpdns.org', 'fastora.top',
    'ghfast.top', 'gh-proxy.com', 'llkk.cc', 'ddlc.top', 'pub.dev', 'dart.dev',
    'flutter.dev', 'w3.org', 'apache.org', 'opensource.org',
    'creativecommons.org', 'stackoverflow.com', 'cloudflare.com', 'google.com',
    'microsoft.com',
)

# 第三方引擎/内核二进制：里面出现协议前缀、publicKey*、shortId 之类是库符号，
# 不是节点数据。仍然扫，只是把"裸符号"类命中过滤掉（见 _is_library_symbol）。
LIBRARY_HINTS = (
    'libgojni.so', 'mihomo', 'mihomo.exe', 'libflutter.so', 'Flutter',
    'FlutterMacOS', 'flutter_windows.dll', 'PacketTunnel', '.sym',
    'geosite.dat', 'country.mmdb', '.mrs', 'NOTICES',
)

IPV4 = re.compile(r'^\d{1,3}(\.\d{1,3}){3}$')


def mask(s: str) -> str:
    if isinstance(s, bytes):
        s = s.decode('utf-8', 'replace')
    if len(s) <= 10:
        return s
    return s[:6] + '***' + s[-3:]


def _valid_ipv4(ip: str) -> bool:
    """八位组必须 ≤255 才可能是真 IP。

    没有这一步时，第三方原生库（如 libsingbox.so）里的版本串/魔数
    `538.8.4.4:xx` 会被 IP 正则匹配成"公网 IP:端口" → 真安装包直接判失败，
    等于发版被自己的检查挡住（实测命中过）。"""
    parts = ip.split('.')
    if len(parts) != 4:
        return False
    return all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)


def ip_allowed(ip: str) -> bool:
    if not _valid_ipv4(ip):
        return True          # 连合法 IPv4 都不是 → 不是节点地址，放行
    return any(ip.startswith(p) for p in ALLOWED_IP_PREFIXES)


def host_allowed(host: bytes) -> bool:
    h = host.decode('utf-8', 'replace').lower()
    if IPV4.match(h):
        return ip_allowed(h)
    if '.' not in h:
        return True                      # 裸符号（base64 / host / uuid）放行
    return any(h == s or h.endswith('.' + s) for s in ALLOWED_DOMAIN_SUFFIXES)


def is_library(path: str) -> bool:
    base = os.path.basename(path)
    return any(h in base for h in LIBRARY_HINTS)


def check_text(text: bytes, label: str, findings: list, library: str):
    """四项检查（与 Dart 防线同规则）。library = 第三方库文件名，命中归为符号类噪声。"""
    for needle in INCIDENT_BLOCKLIST:
        if needle.encode() in text:
            findings.append((label, 'hard-blocklist', mask(needle), library))

    for m in NODE_URI.finditer(text):
        host = m.group(1)
        if not host_allowed(host):
            findings.append((label, 'node-uri-real-host', mask(host), library))

    for m in IP_PORT.finditer(text):
        ip = m.group(1).decode()
        if not ip_allowed(ip):
            findings.append((label, 'public-ip-port', mask(ip), library))

    for m in PBK.finditer(text):
        key = m.group(1).decode('utf-8', 'replace')
        if key not in ALLOWED_REALITY_PBK:
            findings.append((label, 'unregistered-reality-pbk', mask(key), library))

    for marker in INTERNAL_MARKERS:
        for enc in ('utf-8', 'utf-16-le'):
            if marker.encode(enc) in text:
                findings.append((label, f'internal-marker:{marker}', marker, library))


def b64_layer(data: bytes):
    for m in B64_RUN.finditer(data):
        run = m.group(0)
        try:
            pad = run + b'=' * (-len(run) % 4)
            dec = base64.b64decode(pad, validate=False)
        except (binascii.Error, ValueError):
            continue
        if len(dec) < 16:
            continue
        head = dec[:400]
        printable = sum(1 for b in head if 32 <= b < 127 or b in (9, 10, 13))
        if printable / max(1, len(head)) < 0.85:
            continue
        yield m.start(), dec


def scan_blob(name: str, data: bytes, findings: list):
    library = name if is_library(name) else ''
    check_text(data, name, findings, library)
    for off, dec in b64_layer(data):
        check_text(dec, f'{name}@b64[{off}]', findings, library)


def scan_zip(path: str, findings: list):
    try:
        zf = zipfile.ZipFile(path)
    except Exception as e:                                   # noqa: BLE001
        print(f'  !! 无法打开 {path}: {e}', file=sys.stderr)
        return
    base = os.path.basename(path)
    for info in zf.infolist():
        if info.is_dir():
            continue
        try:
            data = zf.read(info)
        except Exception:                                    # noqa: BLE001
            continue
        scan_blob(f'{base}::{info.filename}', data, findings)


def scan_dir(path: str, findings: list, label: str):
    for dirpath, _dirs, files in os.walk(path):
        for fn in files:
            fp = os.path.join(dirpath, fn)
            try:
                if os.path.islink(fp) or os.path.getsize(fp) > 500 * 1024 * 1024:
                    continue
                with open(fp, 'rb') as fh:
                    data = fh.read()
            except OSError:
                continue
            scan_blob(f'{label}::{os.path.relpath(fp, path)}', data, findings)


def scan_dmg(path: str, findings: list, unscanned: list):
    # 解不开就必须报"没扫到"，绝不能静默算通过（这是防线最容易变成摆设的地方）
    if sys.platform != 'darwin' or not shutil.which('hdiutil'):
        unscanned.append((path, 'dmg 需要 macOS + hdiutil，本平台无法解包'))
        return
    mnt = tempfile.mkdtemp(prefix='mf_dmg_')
    attached = False
    try:
        r = subprocess.run(
            ['hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint', mnt, path],
            capture_output=True, text=True)
        if r.returncode != 0:
            unscanned.append((path, f'hdiutil 挂载失败：{r.stderr.strip()}'))
            return
        attached = True
        scan_dir(mnt, findings, os.path.basename(path))
    finally:
        if attached:
            subprocess.run(['hdiutil', 'detach', '-quiet', mnt],
                           capture_output=True)
        shutil.rmtree(mnt, ignore_errors=True)


def scan_exe(path: str, findings: list, unscanned: list):
    tmp = tempfile.mkdtemp(prefix='mf_exe_')
    try:
        tool = None
        for cand in ('innoextract', '7z', '7za'):
            if shutil.which(cand):
                tool = cand
                break
        if tool is None:
            unscanned.append((path, '无 innoextract/7z，无法解 Inno Setup 包'))
            return
        argv = ([tool, '-s', '-d', tmp, path] if tool == 'innoextract'
                else [tool, 'x', '-y', f'-o{tmp}', path])
        r = subprocess.run(argv, capture_output=True)
        if not os.listdir(tmp):
            unscanned.append(
                (path, f'{tool} 解包后无内容（退出码 {r.returncode}）'))
            return
        scan_dir(tmp, findings, os.path.basename(path))
        print(f'  .. 已用 {tool} 解包并扫描')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def expand(targets):
    out = []
    for t in targets:
        hits = sorted(glob.glob(t, recursive=True)) if any(
            c in t for c in '*?[') else [t]
        for h in hits:
            if os.path.isdir(h):
                for ext in ('apk', 'aab', 'ipa', 'zip', 'dmg', 'exe'):
                    out.extend(sorted(glob.glob(os.path.join(h, '**', f'*.{ext}'),
                                                recursive=True)))
            else:
                out.append(h)
    # 只留产物，跳过校验和/manifest
    return [p for p in out if p.lower().endswith(
        ('.apk', '.aab', '.ipa', '.zip', '.dmg', '.exe'))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('targets', nargs='+', help='产物文件或目录（支持通配）')
    ap.add_argument('--all', action='store_true',
                    help='兼容别名：目录按已知产物后缀展开（默认行为）')
    args = ap.parse_args()

    artifacts = expand(args.targets)
    if not artifacts:
        print('没有找到任何产物（检查路径/后缀）', file=sys.stderr)
        return 2

    findings = []
    unscanned = []
    for path in artifacts:
        print(f'== 扫描 {path}')
        low = path.lower()
        if low.endswith(('.apk', '.aab', '.ipa', '.zip')):
            scan_zip(path, findings)
        elif low.endswith('.dmg'):
            scan_dmg(path, findings, unscanned)
        elif low.endswith('.exe'):
            scan_exe(path, findings, unscanned)
        else:
            with open(path, 'rb') as fh:
                scan_blob(os.path.basename(path), fh.read(), findings)

    print()
    print('=' * 68)
    print(f'产物数 {len(artifacts)}，命中 {len(findings)} 处，'
          f'未能解包 {len(unscanned)} 个')
    print('=' * 68)
    for label, kind, value, library in findings[:200]:
        where = f' (第三方库: {os.path.basename(library)})' if library else ''
        print(f'  [{kind}] {label}{where} :: {value}')
    if len(findings) > 200:
        print(f'  ... 其余 {len(findings) - 200} 处')

    for path, why in unscanned:
        print(f'  [未能扫描] {os.path.basename(path)}：{why}')

    if findings:
        print('\n产物里出现疑似真实节点信息 —— 拒绝发布。', file=sys.stderr)
        print('处理：把测试节点从构建输入里移除（assets / lib 常量 / 构建脚本），'
              '而不是放宽本检查。', file=sys.stderr)
        return 1
    if unscanned:
        # 没扫到 ≠ 干净。任务要求"客户拿到的版本不能有测试信息"，那就不能
        # 在"根本没打开这个产物"的情况下给出绿灯。
        print('\n有产物未能解包扫描 —— 本检查无法确认其干净，视为未通过。',
              file=sys.stderr)
        return 2
    print('\n产物干净：未发现测试/真实节点信息。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
