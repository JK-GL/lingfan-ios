#!/usr/bin/env python3
"""解析 .a 静态库内每个 Mach-O 成员的符号表（nlist_64），
输出 defined / undefined 清单，用于回答“库里到底有什么”。

iSH 上 GNU nm 不认 Mach-O，只能自己撸。
"""
import sys, struct, os, io

MH_MAGIC_64 = 0xfeedfacf
LC_SYMTAB = 0x2


def parse_ar(data):
    """返回 [(name, bytes)]，跳过符号索引成员"""
    if not data.startswith(b'!<arch>\n'):
        raise SystemExit('not an ar archive')
    off = 8
    out = []
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[0:16].decode('ascii', 'replace').strip()
        size = int(hdr[48:58].decode('ascii', 'replace').strip() or 0)
        body = data[off + 60: off + 60 + size]
        # BSD 扩展名：'#1/<nameLen>'，真实文件名在成员体开头，占 nameLen 字节
        if name.startswith('#1/'):
            try:
                nlen = int(name[3:])
                real = body[:nlen].decode('ascii', 'replace').rstrip('\x00')
                body = body[nlen:]
                name = real
            except ValueError:
                pass
        out.append((name, body))
        off += 60 + size
        if off % 2:
            off += 1
    return out


def macho_syms(body):
    """返回 (defined, undefined) 两个 list"""
    if len(body) < 32:
        return [], []
    magic = struct.unpack('<I', body[:4])[0]
    if magic != MH_MAGIC_64:
        return [], []
    ncmds = struct.unpack('<I', body[16:20])[0]
    off = 32
    symtab = None
    for _ in range(ncmds):
        if off + 8 > len(body):
            break
        cmd, cmdsize = struct.unpack('<II', body[off:off + 8])
        if cmd == LC_SYMTAB:
            symtab = struct.unpack('<IIII', body[off + 8:off + 24])
            break
        off += cmdsize
    if not symtab:
        return [], []
    symoff, nsyms, stroff, strsize = symtab
    strtab = body[stroff:stroff + strsize]
    defined, undefined = [], []
    for i in range(nsyms):
        p = symoff + i * 16
        if p + 16 > len(body):
            break
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack('<IBBHQ', body[p:p + 16])
        if n_strx == 0 or n_strx >= len(strtab):
            continue
        end = strtab.find(b'\0', n_strx)
        name = strtab[n_strx:end if end >= 0 else len(strtab)].decode('ascii', 'replace')
        if n_type & 0x01:      # N_UNDF
            undefined.append(name)
        else:
            defined.append(name)
    return defined, undefined


def main():
    path = sys.argv[1]
    data = open(path, 'rb').read()
    members = parse_ar(data)
    print(f'archive={path} size={len(data)} members={len(members)}')
    alldef, allund = {}, {}
    parsed = 0
    for name, body in members:
        d, u = macho_syms(body)
        if not body[:4] == b'\xcf\xfa\xed\xfe':
            continue
        parsed += 1
        for s in d:
            alldef.setdefault(s, []).append(name)
        for s in u:
            allund.setdefault(s, []).append(name)
    print(f'parsed mach-o members={parsed}')
    print(f'defined symbols={len(alldef)} undefined symbols={len(allund)}')
    outdir = sys.argv[2] if len(sys.argv) > 2 else '/tmp'
    with open(os.path.join(outdir, 'defined.txt'), 'w') as f:
        for s in sorted(alldef):
            f.write(s + '\n')
    with open(os.path.join(outdir, 'undefined.txt'), 'w') as f:
        for s in sorted(allund):
            f.write(s + '\n')
    print('written to', outdir)


if __name__ == '__main__':
    main()
