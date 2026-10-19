#!/usr/bin/env python3
"""检测 Store 类里引用了但未声明的属性。

CI 一轮要 2 分钟，本地能抓的先抓掉。
"""
import os
import re
import sys

STORE_RE = re.compile(r'(?:@MainActor\s*\n)?final class (\w+): ObservableObject \{')
SUSPICIOUS = ['busyMessage', 'lastMessage', 'errorMessage', 'running', 'loading',
              'isScanning', 'isDemo', 'notices']


def collect_stores(files):
    stores = []
    for path in files:
        src = open(path).read()
        for m in STORE_RE.finditer(src):
            stores.append((m.group(1), path, src[m.end():]))
    return stores


def declared_props(body):
    props = set()
    # 逐行扫描，避免多行正则吃掉 @Published 的换行
    for line in body.split('\n'):
        m = re.search(r'\b(?:let|var)\s+(\w+)\s*[:=]', line)
        if m:
            props.add(m.group(1))
    return props


def declared_funcs(body):
    return set(re.findall(r'func\s+(\w+)\s*[<(]', body))


def main():
    files = []
    for root, _, fs in os.walk('Sources'):
        for f in fs:
            if f.endswith('.swift'):
                files.append(os.path.join(root, f))

    problems = []
    for name, path, body in collect_stores(files):
        props = declared_props(body)
        funcs = declared_funcs(body)
        known = props | funcs

        for m in re.finditer(r'self\.(\w+)', body):
            attr = m.group(1)
            if attr in known:
                continue
            if attr in ('init',):
                continue
            ln = body[:m.start()].count('\n') + 1
            problems.append(f'{path}: self.{attr} 未声明')

        for token in SUSPICIOUS:
            if token in known:
                continue
            m = re.search(rf'(?<![\w.]){token}(?![\w(])', body)
            if m:
                ln = body[:m.start()].count('\n') + 1
                problems.append(f'{path}: {name} 里用了未声明的 `{token}`')

    if problems:
        for p in sorted(set(problems)):
            print('❌', p)
        return 1
    print('✅ Store 属性引用检查通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
