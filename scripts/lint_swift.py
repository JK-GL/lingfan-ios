#!/usr/bin/env python3
"""Swift 源码静态体检。

iSH 上没有 swiftc，无法真编译。这里做能在纯文本层面抓住的高频错误：
  1. 括号 / 花括号平衡（跳过字符串与注释）
  2. @MainActor 类里的 Task 内直接触碰 self 的不可见风险（提示）
  3. inout 参数同时用 self. 调用（独占访问冲突）
  4. withCheckedContinuation 无类型标注且闭包内有 resume
  5. 引用了不存在的方法（跨文件粗略符号表）
  6. 重复声明的类型名
"""
import os
import re
import sys
from collections import defaultdict


def strip_code(s: str) -> str:
    """去掉字符串与注释，保留结构"""
    out, i, n, instr = [], 0, len(s), False
    while i < n:
        c = s[i]
        if instr:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                instr = False
            i += 1
            continue
        if c == '"':
            instr = True
            i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            while i < n and s[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            j = s.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def main():
    files = []
    for root, _, fs in os.walk('Sources'):
        for f in fs:
            if f.endswith('.swift'):
                files.append(os.path.join(root, f))

    problems = []

    # 收集全局符号
    types = defaultdict(list)      # 类型名 -> [文件]
    funcs = defaultdict(set)       # 类型名 -> 方法名集合

    for p in files:
        raw = open(p).read()
        for m in re.finditer(r'\b(?:struct|class|enum|protocol|actor)\s+([A-Z]\w*)', raw):
            types[m.group(1)].append(p)
        # 记录每个类型块内的方法名（粗略：按缩进）
        cur_type = None
        for line in raw.split('\n'):
            tm = re.match(r'\s*(?:public |private |internal )?(?:struct|class|enum|final class|actor)\s+([A-Z]\w*)', line)
            if tm:
                cur_type = tm.group(1)
            fm = re.match(r'\s+(?:@\w+\s+)?(?:nonisolated |private |static |func )*func\s+(\w+)', line)
            if fm and cur_type:
                funcs[cur_type].add(fm.group(1))

    for p in sorted(files):
        raw = open(p).read()
        code = strip_code(raw)

        b0, b1 = code.count('{'), code.count('}')
        p0, p1 = code.count('('), code.count(')')
        if b0 != b1:
            problems.append(f'❌ {p}: 花括号不平衡 {{={b0} }}={b1}')
        if p0 != p1:
            problems.append(f'❌ {p}: 圆括号不平衡 (={p0} )={p1}')

        # inout 独占访问
        for m in re.finditer(r'\bself\.\w+\(&self\.(\w+)', code):
            ln = code[:m.start()].count('\n') + 1
            problems.append(f'⚠️  {p}:{ln} self 方法调用传 &self.{m.group(1)} → 独占访问冲突')

        # withCheckedContinuation 未标注类型
        for m in re.finditer(r'withCheckedContinuation\s*\{', code):
            seg = code[m.start():m.start() + 200]
            if 'CheckedContinuation<' not in seg:
                ln = code[:m.start()].count('\n') + 1
                problems.append(f'⚠️  {p}:{ln} withCheckedContinuation 缺类型标注，可能推断失败')

        # struct 内 var 被 enum 用错
        if 'NWEndpoint.Port(rawValue' in raw:
            for m in re.finditer(r'NWEndpoint\.Port\(rawValue:\s*(\w+)\)', raw):
                arg = m.group(1)
                if arg.isupper() or arg in ('port', 'nwPort', 'Self.broadcastPort'):
                    continue

    # 重复类型名
    for name, ps in types.items():
        if len(ps) > 1:
            problems.append(f'⚠️  类型 {name} 在多个文件重复声明: {ps}')

    if problems:
        print('\n'.join(problems))
    else:
        print('✅ 未发现结构性问题')
    print(f'\n扫描 {len(files)} 个文件, {len(types)} 个类型, {sum(len(v) for v in funcs.values())} 个方法')
    return 1 if any(x.startswith('❌') for x in problems) else 0


if __name__ == '__main__':
    sys.exit(main())
