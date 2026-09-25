#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make-hidpi-cursor.py —— 生成"多档尺寸"的高分屏光标主题 (2026-09-25)

为什么需要: 本机四个已装光标主题(vintage/Adwaita/bloom/bloom-dark)内含图【最大只有 48px】,
  XcursorLibraryLoadImage 请求 64/96/128 一律回落 48 → XFCE「设置→鼠标→光标大小」滑块
  拖到 48 以上【毫无效果】。判据: XFIXES 实测 :1 与 :2 的当前光标都是 48x48。
做法: 读源主题每个 Xcursor 文件里最大的那一档, 用最近邻放大到若干目标尺寸, 连同原档一起
  写进新文件 → 主题内就有了 48/64/96/128 四档, 滑块拖到哪档就真按哪档显示。
  最近邻而非插值: 光标是硬边像素画, 插值会糊边; 且纯标准库实现(本机无 PIL/ImageMagick)。
落点: /root/.icons/<新主题名>/  —— 纯用户级, apt 更新冲不掉, 删目录即完全回退。

用法: make-hidpi-cursor.py <源主题名> <新主题名> [尺寸,逗号分隔, 默认 48,64,96,128]
  例: make-hidpi-cursor.py vintage vintage-hidpi
"""
import os
import struct
import sys

IMG = 0xfffd0002


def read_images(path):
    """解析 Xcursor 文件 → [{size,w,h,xhot,yhot,delay,px}]"""
    b = open(path, "rb").read()
    if len(b) < 16 or b[:4] != b"Xcur":
        return []
    _, _, _, ntoc = struct.unpack_from("<4sIII", b, 0)
    out = []
    for i in range(ntoc):
        typ, sub, pos = struct.unpack_from("<III", b, 16 + i * 12)
        if typ != IMG:
            continue
        try:
            _, _, csub, _, w, h, xh, yh, delay = struct.unpack_from("<IIIIIIIII", b, pos)
            px = struct.unpack_from("<%dI" % (w * h), b, pos + 36)
        except Exception:
            continue
        out.append(dict(size=csub, w=w, h=h, xhot=xh, yhot=yh, delay=delay, px=px))
    return out


def resize(im, target):
    """最近邻缩放到 target x target(按原图长边等比; 光标基本都是方的)。"""
    w, h, px = im["w"], im["h"], im["px"]
    base = max(w, h) or 1
    W = max(1, round(w * target / base))
    H = max(1, round(h * target / base))
    new = [0] * (W * H)
    for y in range(H):
        sy = min(h - 1, y * h // H)
        row = sy * w
        orow = y * W
        for x in range(W):
            new[orow + x] = px[row + min(w - 1, x * w // W)]
    k = target / base
    return dict(size=target, w=W, h=H,
                xhot=min(W - 1, int(im["xhot"] * k)),
                yhot=min(H - 1, int(im["yhot"] * k)),
                delay=im["delay"], px=new)


def write_cursor(path, imgs):
    n = len(imgs)
    pos = 16 + n * 12
    toc = b""
    body = b""
    for im in imgs:
        chunk = struct.pack("<IIIIIIIII", 36, IMG, im["size"], 1,
                            im["w"], im["h"], im["xhot"], im["yhot"], im["delay"])
        chunk += struct.pack("<%dI" % (im["w"] * im["h"]), *im["px"])
        toc += struct.pack("<III", IMG, im["size"], pos)
        body += chunk
        pos += len(chunk)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sIII", b"Xcur", 16, 0x10000, n) + toc + body)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    src_name, dst_name = sys.argv[1], sys.argv[2]
    sizes = sorted(int(x) for x in (sys.argv[3] if len(sys.argv) > 3 else "48,64,96,128").split(","))

    src = None
    for base in ("/usr/share/icons", os.path.expanduser("~/.icons"),
                 os.path.expanduser("~/.local/share/icons")):
        p = os.path.join(base, src_name, "cursors")
        if os.path.isdir(p):
            src = p
            break
    if not src:
        print("找不到源主题的 cursors 目录:", src_name)
        sys.exit(1)

    dst = os.path.expanduser("~/.icons/%s/cursors" % dst_name)
    os.makedirs(dst, exist_ok=True)

    made = links = skipped = 0
    # 先处理真实文件, 软链最后按原样重建(很多光标名是别名, 保持别名关系)
    for name in sorted(os.listdir(src)):
        sp = os.path.join(src, name)
        if os.path.islink(sp):
            continue
        imgs = read_images(sp)
        if not imgs:
            skipped += 1
            continue
        # 每个 nominal size 可能有多帧(动画); 按 size 分组, 取最大 size 那组做源
        groups = {}
        for im in imgs:
            groups.setdefault(im["size"], []).append(im)
        big = max(groups)
        out = []
        for t in sizes:
            if t in groups:                       # 原主题已有这档, 原样保留
                out.extend(groups[t])
            else:
                out.extend(resize(im, t) for im in groups[big])
        write_cursor(os.path.join(dst, name), out)
        made += 1

    for name in sorted(os.listdir(src)):
        sp = os.path.join(src, name)
        if not os.path.islink(sp):
            continue
        tgt = os.readlink(sp)
        dp = os.path.join(dst, name)
        if os.path.lexists(dp):
            continue
        try:
            os.symlink(tgt, dp)
            links += 1
        except OSError:
            pass

    root = os.path.dirname(dst)
    with open(os.path.join(root, "index.theme"), "w", encoding="utf-8") as f:
        f.write("[Icon Theme]\nName=%s\nComment=%s 放大版(含 %s 档), 供高分屏使用\n"
                % (dst_name, src_name, "/".join(str(s) for s in sizes)))
    with open(os.path.join(root, "cursor.theme"), "w", encoding="utf-8") as f:
        f.write("[Icon Theme]\nName=%s\nInherits=%s\n" % (dst_name, src_name))

    print("源: %s" % src)
    print("目标: %s" % root)
    print("生成 %d 个光标(各含 %s 档), 重建软链 %d 个, 跳过非 Xcursor %d 个"
          % (made, ",".join(str(s) for s in sizes), links, skipped))


main()
