#!/usr/bin/env python3
"""移除包含「动态主题颜色」的 const 关键字（MBColors 由 const 改为动态 getter 后）
只处理 const 表达式（含括号/方括号平衡匹配）内含 MBColors.bg/bg2/card/card2/line/line2/txt/txt2/txt3 的情况，
不含动态颜色的 const 保持原样（不影响编译期优化）。
用法: python3 tool/fix_const_theme.py
"""
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib')
DYNAMIC = re.compile(r'MBColors\.(?:bg|bg2|card|card2|line|line2|txt|txt2|txt3)\b')


def balanced_end(text: str, start: int, open_ch: str, close_ch: str) -> int:
    """从 open_ch 之后开始做括号平衡匹配，返回 close_ch 的位置"""
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        elif c in ('"', "'"):
            # 跳过字符串（避免括号在字符串里干扰）
            quote = c
            i += 1
            while i < len(text) and text[i] != quote:
                if text[i] == '\\':
                    i += 1
                i += 1
        i += 1
    return -1


def fix_file(path: str) -> int:
    with open(path) as f:
        text = f.read()
    edits = []  # (start, end) 要删除的 "const " 范围
    i = 0
    n = len(text)
    while i < n:
        idx = text.find('const', i)
        if idx == -1:
            break
        # 排除声明语境: "static const" / 行首 "const X =" 等
        prev = text[max(0, idx - 7):idx]
        if re.search(r'(static\s*)$', prev):
            i = idx + 5
            continue
        j = idx + 5  # 跳过 "const"
        # 跳空白，必须跟标识符 + ( 或 [
        while j < n and text[j] in ' \t':
            j += 1
        if j >= n or not (text[j].isalpha() or text[j] == '_'):
            i = idx + 5
            continue
        k = j
        while k < n and (text[k].isalnum() or text[k] == '_'):
            k += 1
        while k < n and text[k] in ' \t':
            k += 1
        if k >= n or text[k] not in '([':
            i = idx + 5
            continue
        end = balanced_end(text, k, text[k], ')' if text[k] == '(' else ']')
        if end == -1:
            i = idx + 5
            continue
        if DYNAMIC.search(text, k, end + 1):
            edits.append((idx, idx + 5))
            i = end + 1
        else:
            i = idx + 5
    for start, end in reversed(edits):
        text = text[:start] + text[end:]
    with open(path, 'w') as f:
        f.write(text)
    return len(edits)


total = 0
for root, _, files in os.walk(ROOT):
    for fn in files:
        if fn.endswith('.dart'):
            p = os.path.join(root, fn)
            c = fix_file(p)
            if c:
                print(f'{os.path.relpath(p, ROOT)}: 移除 {c} 处 const')
                total += c
print(f'共 {total} 处')
