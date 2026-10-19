#!/usr/bin/env python3
"""生成深浅双主题色板对照图，用于装包前肉眼验收配色。"""
from PIL import Image, ImageDraw, ImageFont

W, H = 1100, 1180

# 浅色 / 深色 定义（与 MDColor.swift 完全一致）
ROLES = [
    ("background",      0xF8F9FB, 0x0E1116),
    ("surface",         0xFFFFFF, 0x1A1F27),
    ("surfaceHigh",     0xF2F4F8, 0x222A35),
    ("surfaceHighest",  0xE9EDF3, 0x2B3441),
    ("textPrimary",     0x333333, 0xE8EBEF),
    ("textSecondary",   0x888888, 0xA8B0BC),
    ("textTertiary",    0xCDCDCD, 0x5C6570),
    ("outline",         0xCDCDCD, 0x6B7480),
    ("outlineVariant",  0xE6E8EC, 0x2E3742),
    ("brand",           0x4A7FE8, 0x7BA6F5),
    ("info",            0x2196F3, 0x64B5F6),
    ("shell",           0x607D8B, 0x90A4AE),
    ("file",            0x26A59A, 0x4DB6AC),
    ("app",             0x4CB050, 0x81C784),
    ("process",         0xFF5252, 0xFF8A80),
    ("remote",          0x9C27B0, 0xCE93D8),
    ("tool",            0xFF9800, 0xFFB74D),
    ("success",         0x34C759, 0x30D158),
    ("warning",         0xFF9500, 0xFFB340),
    ("danger",          0xFF3B30, 0xFF6961),
]


def hexc(v, a=255):
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF, a)


def load_font(size):
    for p in [
        "/usr/share/fonts/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto/NotoSansCJKsc-Regular.otf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    ]:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()


def contrast(fg, bg):
    def lum(v):
        r, g, b = (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF
        def c(x):
            x /= 255.0
            return x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
        return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
    l1, l2 = lum(fg), lum(bg)
    if l1 < l2:
        l1, l2 = l2, l1
    return (l1 + 0.05) / (l2 + 0.05)


def main():
    img = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)
    f_title = load_font(30)
    f_lab = load_font(19)
    f_small = load_font(15)

    col_x = {"light": 40, "dark": 580}
    col_w = 480

    d.text((40, 22), "MDColor 双主题色板对照", font=f_title, fill=(20, 20, 20))
    d.text((40, 62), "浅色取自原版截图逐像素采样 · 深色按 Material 3 规范推导", font=f_small, fill=(110, 110, 110))

    # 两栏大底
    for name, x in col_x.items():
        bg = 0xF8F9FB if name == "light" else 0x0E1116
        d.rounded_rectangle([x, 100, x + col_w, H - 30], radius=20, fill=hexc(bg)[:3])
        label = "LIGHT 浅色" if name == "light" else "DARK 深色"
        d.text((x + 20, 112), label, font=f_lab,
               fill=(60, 60, 60) if name == "light" else (220, 224, 230))

    y = 155
    for role, light, dark in ROLES:
        for name in ("light", "dark"):
            x = col_x[name]
            val = light if name == "light" else dark
            # 色块
            d.rounded_rectangle([x + 20, y, x + 74, y + 34], radius=8, fill=hexc(val)[:3],
                                outline=(200, 200, 200) if name == "light" else (60, 66, 74))
            # 角色名 + 色值
            label_col = (70, 70, 70) if name == "light" else (200, 205, 212)
            d.text((x + 86, y + 6), f"{role}", font=f_small, fill=label_col)
            d.text((x + 300, y + 7), f"#{val:06X}", font=f_small,
                   fill=(130, 130, 130) if name == "light" else (140, 148, 158))
        y += 38

    # 对比度校验表
    y += 10
    d.text((40, y), "对比度校验（WCAG 正文要求 ≥ 4.5:1）", font=f_lab, fill=(30, 30, 30))
    y += 36
    checks = [
        ("textPrimary / background", 0x333333, 0xF8F9FB, 0xE8EBEF, 0x0E1116),
        ("textPrimary / surface",    0x333333, 0xFFFFFF, 0xE8EBEF, 0x1A1F27),
        ("textSecondary / surface",  0x888888, 0xFFFFFF, 0xA8B0BC, 0x1A1F27),
        ("brand / surface",          0x4A7FE8, 0xFFFFFF, 0x7BA6F5, 0x1A1F27),
        ("process / surface",        0xFF5252, 0xFFFFFF, 0xFF8A80, 0x1A1F27),
    ]
    for label, lfg, lbg, dfg, dbg in checks:
        c1 = contrast(lfg, lbg)
        c2 = contrast(dfg, dbg)
        ok1 = "OK " if c1 >= 4.5 else "低 "
        ok2 = "OK " if c2 >= 4.5 else "低 "
        d.text((44, y), label, font=f_small, fill=(80, 80, 80))
        d.text((430, y), f"浅 {c1:4.1f}:1 {ok1}", font=f_small,
               fill=(30, 130, 60) if c1 >= 4.5 else (190, 50, 40))
        d.text((640, y), f"深 {c2:4.1f}:1 {ok2}", font=f_small,
               fill=(30, 130, 60) if c2 >= 4.5 else (190, 50, 40))
        y += 26

    img.save("/var/minis/attachments/mdcolor_dark_light.png")
    print("saved")


if __name__ == "__main__":
    main()
