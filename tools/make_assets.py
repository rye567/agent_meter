#!/usr/bin/env python3
"""生成 agent_meter 图标资源：
1. 从图集左侧裁出 App 图标（1024）→ 白角转透明 → iconset → AppIcon.icns
2. 从图集底部裁出黑色鲸鱼剪影 → 黑转透明 → 菜单栏图标 menubar.png（template 用）
"""
from PIL import Image, ImageDraw
import os, subprocess, sys

SHEET = os.path.expanduser(
    "~/Downloads/ChatGPT Image 2026年9月4日 15_41_49.png")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")
os.makedirs(RES, exist_ok=True)

sheet = Image.open(SHEET).convert("RGB")
W, H = sheet.size

# ── 1. App 图标：左半区内按「蓝色像素」定位（避开右侧尺寸变体与灰色标注文字）──
left = sheet.crop((0, 0, W // 2, int(H * 0.85)))
px = left.load()
w, h = left.size
bbox = None
l, t, r, b = w, h, 0, 0
for y in range(0, h, 2):
    for x in range(0, w, 2):
        r_, g_, b_ = px[x, y]
        if b_ > 150 and b_ - r_ > 60 and b_ - g_ > 60:
            l, t = min(l, x), min(t, y)
            r, b = max(r, x), max(b, y)
if r <= l or b <= t:
    sys.exit("未能定位 App 图标区域")
bbox = (l, t, r, b)
cx, cy = (l + r) / 2, (t + b) / 2
side = max(r - l, b - t) * 1.01          # 微外扩容纳软阴影
half = side / 2
l, t, r, b = int(cx - half), int(cy - half), int(cx + half), int(cy + half)
l, t = max(l, 0), max(t, 0)
r, b = min(r, w), min(b, h)
icon = left.crop((l, t, r, b)).resize((1024, 1024), Image.LANCZOS).convert("RGBA")

# 白角转透明：从四角 floodfill 相近白色区域，再映射为 alpha=0
icon_rgb = icon.convert("RGB")
MAGIC = (255, 0, 255)
for seed in [(0, 0), (1023, 0), (0, 1023), (1023, 1023)]:
    ImageDraw.floodfill(icon_rgb, seed, MAGIC, thresh=70)
px = icon_rgb.load()
pxa = icon.load()
for y in range(1024):
    for x in range(1024):
        if px[x, y] == MAGIC:
            pxa[x, y] = (0, 0, 0, 0)

icon_path = os.path.join(RES, "app_icon_1024.png")
icon.save(icon_path)
print(f"✓ App 图标裁剪 bbox={bbox} → {icon_path}")

# ── 2. iconset → icns ──────────────────────────────────────
iconset = os.path.join(RES, "AppIcon.iconset")
subprocess.run(["rm", "-rf", iconset], check=True)
os.makedirs(iconset)
for size in (16, 32, 128, 256, 512):
    icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
    icon.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(RES, "AppIcon.icns")], check=True)
print("✓ AppIcon.icns 生成")

# ── 3. 菜单栏图标：图集底部黑鲸鱼剪影 → 黑转透明（template 用）──
# 限定区域避开下方「18 × 18」标注与右侧菜单栏示意
GLYPH_BOX = (int(W * 0.50), int(H * 0.76), int(W * 0.60), int(H * 0.885))
glyph_src = sheet.crop(GLYPH_BOX)
gpx = glyph_src.load()
gw, gh = glyph_src.size
gl, gt, gr, gb = gw, gh, 0, 0
for y in range(gh):
    for x in range(gw):
        r_, g_, b_ = gpx[x, y]
        if max(r_, g_, b_) < 110:
            gl, gt = min(gl, x), min(gt, y)
            gr, gb = max(gr, x), max(gb, y)
if gr <= gl or gb <= gt:
    sys.exit("未能定位菜单栏图标剪影")
glyph_src = glyph_src.crop((gl, gt, gr + 1, gb + 1)).convert("RGBA")

# alpha = 255 - 亮度（黑=不透明），RGB 统一纯黑，交由 macOS template 渲染
gpx = glyph_src.load()
gw, gh = glyph_src.size
for y in range(gh):
    for x in range(gw):
        r_, g_, b_, _ = gpx[x, y]
        lum = max(r_, g_, b_)
        gpx[x, y] = (0, 0, 0, 255 - lum)

menubar_path = os.path.join(RES, "menubar.png")
# 保持剪影原始宽高比（以 18pt 高为基准出 2x/4x 图），禁止强行压进正方形
ratio = gw / gh
glyph_src.resize((round(36 * ratio), 36), Image.LANCZOS).save(menubar_path)
glyph_src.resize((round(72 * ratio), 72), Image.LANCZOS).save(os.path.join(RES, "menubar@2x.png"))
print(f"✓ 菜单栏图标 bbox=({gl},{gt},{gr},{gb}) 比例={ratio:.2f} → {menubar_path}")
