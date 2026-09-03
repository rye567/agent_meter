#!/usr/bin/env python3
"""生成 agent_meter 图标资源：
1. 从图集裁出 App 图标（1024）→ iconset → AppIcon.icns
2. 从黑底图裁 logo、黑转透明 → 菜单栏图标 menubar.png (36x36)
"""
from PIL import Image, ImageChops
import os, subprocess, sys

DOWNLOADS = os.path.expanduser("~/Downloads")
SHEET = os.path.join(DOWNLOADS, "ChatGPT Image 2026年9月3日 11_15_10.png")
DARK = os.path.join(DOWNLOADS, "ChatGPT Image 2026年9月3日 11_17_43.png")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")
os.makedirs(RES, exist_ok=True)

# ── 1. App 图标：定位图集顶部大图标（0.63H 以内，避开底部标注文字）──
sheet = Image.open(SHEET).convert("RGB")
W, H = sheet.size
top = sheet.crop((0, 0, W, int(H * 0.63)))
bg = Image.new("RGB", top.size, top.getpixel((5, 5)))
diff = ImageChops.difference(top, bg).convert("L")
mask = diff.point(lambda p: 255 if p > 12 else 0)
bbox = mask.getbbox()
if not bbox:
    sys.exit("未能定位 App 图标区域")
l, t, r, b = bbox
# 外扩 1.5% 容纳软阴影，取正方形
cx, cy = (l + r) / 2, (t + b) / 2
side = max(r - l, b - t) * 1.03
half = side / 2
l, t, r, b = int(cx - half), int(cy - half), int(cx + half), int(cy + half)
l, t = max(l, 0), max(t, 0)
r, b = min(r, W), min(b, int(H * 0.70))
side = min(r - l, b - t)
icon = sheet.crop((l, t, l + side, t + side)).resize((1024, 1024), Image.LANCZOS)
icon_path = os.path.join(RES, "app_icon_1024.png")
icon.save(icon_path)
print(f"✓ App 图标裁剪 bbox=({l},{t},{r},{b}) → {icon_path}")

# ── 2. iconset → icns ──────────────────────────────────────
iconset = os.path.join(RES, "AppIcon.iconset")
subprocess.run(["rm", "-rf", iconset], check=True)
os.makedirs(iconset)
for size in (16, 32, 128, 256, 512):
    icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
    icon.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(RES, "AppIcon.icns")], check=True)
print("✓ AppIcon.icns 生成")

# ── 3. 菜单栏图标：裁圆环 logo + 黑转透明 ────────────────────
dark = Image.open(DARK).convert("RGB")
W2, H2 = dark.size
bg2 = dark.getpixel((5, 5))
top2 = dark  # 整图找亮区
diff2 = ImageChops.difference(top2, Image.new("RGB", top2.size, bg2)).convert("L")
mask2 = diff2.point(lambda p: 255 if p > 18 else 0)
bbox2 = mask2.getbbox()
l2, t2, r2, b2 = bbox2
cx2, cy2 = (l2 + r2) / 2, (t2 + b2) / 2
side2 = max(r2 - l2, b2 - t2) * 1.02
half2 = side2 / 2
crop = dark.crop((int(cx2 - half2), int(cy2 - half2), int(cx2 + half2), int(cy2 + half2))).convert("RGBA")

# 逐像素：max(r,g,b) <12 → 全透明；12~50 渐变；>50 不透明
px = crop.load()
w2, h2 = crop.size
for y in range(h2):
    for x in range(w2):
        r, g, b, a = px[x, y]
        m = max(r, g, b)
        if m < 12:
            px[x, y] = (r, g, b, 0)
        elif m < 50:
            px[x, y] = (r, g, b, int((m - 12) * 255 / 38))
menubar_path = os.path.join(RES, "menubar.png")
crop.resize((36, 36), Image.LANCZOS).save(menubar_path)
crop.resize((64, 64), Image.LANCZOS).save(os.path.join(RES, "menubar@2x.png"))
print(f"✓ 菜单栏图标 bbox={bbox2} → {menubar_path}")
