#!/usr/bin/env python3
"""把手写 pbxproj 里缺失的源文件补进去。

手写 pbxproj（objectVersion 56）没有 Xcode 的自动同步，
每加一个 .swift 必须在三处登记：
  1. PBXBuildFile   —— 编译条目
  2. PBXFileReference —— 文件引用
  3. PBXGroup children + PBXSourcesBuildPhase files

本脚本幂等：已存在的条目会跳过。
"""
import hashlib
import re
import sys

PROJ = 'LingFan.xcodeproj/project.pbxproj'


def uid(seed: str) -> str:
    """生成 24 位十六进制 ID，与 Xcode 格式一致且对同一文件稳定"""
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def main(paths):
    src = open(PROJ).read()

    added, skipped = [], []

    for rel in paths:
        name = rel.rsplit('/', 1)[-1]
        if f'{name} in Sources' in src:
            skipped.append(name)
            continue

        file_ref = uid('ref:' + rel)
        build_id = uid('build:' + rel)

        # 1. PBXBuildFile：插到 "/* Begin PBXBuildFile section */" 之后第一行前
        anchor = '/* Begin PBXBuildFile section */\n'
        idx = src.index(anchor) + len(anchor)
        src = (src[:idx]
               + f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; '
                 f'fileRef = {file_ref} /* {name} */; }};\n'
               + src[idx:])

        # 2. PBXFileReference
        anchor = '/* Begin PBXFileReference section */\n'
        idx = src.index(anchor) + len(anchor)
        src = (src[:idx]
               + f'\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; '
                 f'lastKnownFileType = sourcecode.swift; name = {name}; '
                 f'path = {rel}; sourceTree = "<group>"; }};\n'
               + src[idx:])

        # 3a. 加到 Home 组的 children（找 HomeView.swift 那条）
        line_re = re.compile(r'([ \t]*)([0-9A-F]{24}) /\* HomeView\.swift \*/,\n')
        m = line_re.search(src)
        if not m:
            raise SystemExit('找不到 HomeView.swift 在 group 里的条目')
        indent = m.group(1)
        pos = m.end()
        src = src[:pos] + f'{indent}{file_ref} /* {name} */,\n' + src[pos:]

        # 3b. 加到 Sources build phase
        line_re = re.compile(r'([ \t]*)([0-9A-F]{24}) /\* HomeView\.swift in Sources \*/,\n')
        m = line_re.search(src)
        if not m:
            raise SystemExit('找不到 HomeView.swift 在 Sources phase 里的条目')
        indent = m.group(1)
        pos = m.end()
        src = src[:pos] + f'{indent}{build_id} /* {name} in Sources */,\n' + src[pos:]

        added.append(name)

    open(PROJ, 'w').write(src)
    print(f'added   : {added}')
    print(f'skipped : {skipped}')


if __name__ == '__main__':
    main(sys.argv[1:])
