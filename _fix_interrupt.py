#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批量给 Observer record 字面量补 interrupt 字段（多行 complete: fn() { 格式）"""
import re
import sys

def process_file(path):
    with open(path, encoding='utf-8') as f:
        lines = f.readlines()
    out = []
    i = 0
    total = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r'^(\s*)complete: ', line)
        if m and 'interrupt:' not in line:
            # 多行格式：complete: fn() {
            if re.search(r'complete: fn\(\) \{\s*$', line):
                # 数括号深度，找到闭合行
                depth = line.count('{') - line.count('}')
                j = i
                while j < len(lines) and depth > 0:
                    j += 1
                    if j >= len(lines):
                        break
                    depth += lines[j].count('{') - lines[j].count('}')
                if j < len(lines) and re.search(r'\},\s*$', lines[j]):
                    # 闭合行行尾加 interrupt
                    out.append(line)
                    for k in range(i + 1, j):
                        out.append(lines[k])
                    out.append(lines[j].rstrip('\n') + ' interrupt: Ref::Ref(None),\n')
                    total += 1
                    i = j + 1
                    continue
            # 单行多语句格式：complete: fn() { ... },
            if re.search(r'\},\s*$', line) and 'complete: fn' in line:
                out.append(line.rstrip('\n') + ' interrupt: Ref::Ref(None),\n')
                total += 1
                i += 1
                continue
        out.append(line)
        i += 1
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.writelines(out)
    return total

if __name__ == '__main__':
    import glob
    total_all = 0
    for p in glob.glob('rx/*.mbt'):
        n = process_file(p)
        if n > 0:
            print(f'{p}: {n} updated')
            total_all += n
    print(f'total: {total_all}')
