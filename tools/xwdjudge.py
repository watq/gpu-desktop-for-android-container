#!/usr/bin/env python3
"""xwd 黑块/纯色判定 —— 不依赖 PIL(本机没装), 直接解析 xwd 的 ZPixmap 数据。

判据沿用账本 J31 找回的 winshot.py 思路:
    有画面 = 唯一色数 > 500 且 最多色占比 < 92%
另外按 8x8 网格统计每块的唯一色数与均值亮度, 用来区分:
    · 整屏黑/纯色  → 所有块都低
    · 局部黑块      → 少数块唯一色≤2 且亮度≈0, 其余正常  ← 用户说的"黑块"
用法: xwdjudge.py <file.xwd> [标签]
"""
import sys, struct, collections

def load(path):
    b = open(path, 'rb').read()
    # xwd header: 前 25 个 4 字节大端字段(X11WindowDump)
    hdr = struct.unpack('>25I', b[:100])
    (hsize, ver, fmt, depth, w, h, xoff, byte_order, bitmap_unit,
     bitmap_bit_order, bitmap_pad, bpp, bpl) = hdr[0:13]
    ncolors = hdr[19]
    off = hsize + ncolors * 12          # 头 + 颜色表(每项 12 字节)
    return w, h, bpp, bpl, b[off:]

def main():
    path = sys.argv[1]
    tag = sys.argv[2] if len(sys.argv) > 2 else path
    w, h, bpp, bpl, data = load(path)
    if bpp not in (24, 32):
        print(f"[{tag}] 不支持的 bpp={bpp}"); return
    step = bpp // 8
    cnt = collections.Counter()
    GRID = 8
    cells = [[[0, 0, 0] for _ in range(GRID)] for _ in range(GRID)]   # [唯一色set占位, 亮度和, 像素数]
    cellsets = [[set() for _ in range(GRID)] for _ in range(GRID)]
    ystep = max(1, h // 240)            # 抽样, 别把手机跑死
    xstep = max(1, w // 320)
    total = 0
    for y in range(0, h, ystep):
        row = y * bpl
        cy = min(GRID - 1, y * GRID // h)
        for x in range(0, w, xstep):
            p = row + x * step
            if p + 3 > len(data): continue
            bl, gr, rd = data[p], data[p+1], data[p+2]
            px = (rd << 16) | (gr << 8) | bl
            cnt[px] += 1
            total += 1
            cx = min(GRID - 1, x * GRID // w)
            cellsets[cy][cx].add(px)
            c = cells[cy][cx]
            c[1] += (rd + gr + bl) // 3
            c[2] += 1
    uniq = len(cnt)
    top, topn = cnt.most_common(1)[0]
    ratio = topn * 100.0 / max(1, total)
    verdict = "有画面" if (uniq > 500 and ratio < 92) else "疑似黑屏/纯色"
    print(f"[{tag}] {w}x{h} bpp={bpp} 采样 {total}px | 唯一色 {uniq} | 最多色 #{top:06x} 占 {ratio:.1f}% → {verdict}")
    # 局部黑块: 唯一色 <=2 且平均亮度 <8
    bad = []
    for cy in range(GRID):
        for cx in range(GRID):
            c = cells[cy][cx]
            if c[2] == 0: continue
            u = len(cellsets[cy][cx]); avg = c[1] / c[2]
            if u <= 2 and avg < 8: bad.append(f"({cy},{cx})")
    print(f"    8x8 网格里纯黑块(唯一色<=2 且亮度<8): {len(bad)} 个 {' '.join(bad[:12])}")

main()
