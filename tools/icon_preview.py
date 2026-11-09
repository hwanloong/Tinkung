"""把自适应图标按启动器的几种遮罩裁一遍，用于**肉眼确认**。

## 为什么需要它

自适应图标最容易出问题的地方是"安全区"：108dp 画布上真正保证可见的
只有中间 **66dp 直径的圆**，外围会被各厂商的启动器按自己的形状裁掉
（原生圆形、三星/小米的圆角方形、一加的水滴形…）。

这个裁剪**在任何预览工具里都看不到** —— 你看到的永远是那张 432×432 的方图，
装到手机上才发现某个角被切了。所以出图之后必须真的裁一遍看。

## 数据来源

直接读**已经生成好的** `mipmap-xxxhdpi/ic_launcher_photo.png`，
而不是 import 生成脚本里的绘图函数。这样它和真正打进 APK 的那张图
**必然是同一份**：生成脚本换实现（比如从"代码画"换成"缩一张成品图"）时，
这个预览工具不会跟着失效，也不会偷偷预览了别的东西。

用法：
    python tools/icon_preview.py

产物写到 `tools/icon_preview/`（不进仓库）。
"""

from __future__ import annotations

from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    print("需要 Pillow：pip install Pillow")
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_photo.png"
OUT_DIR = Path(__file__).resolve().parent / "icon_preview"

# 预览底色：模拟一张浅色壁纸，这样图标的边缘看得清楚
WALLPAPER = (0xEC, 0xE6, 0xF0)


def _mask_circle(size: int) -> Image.Image:
    """正圆遮罩（原生 Android / Pixel 的默认形状）。"""
    big = size * 4
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).ellipse((0, 0, big - 1, big - 1), fill=255)
    return m.resize((size, size), Image.LANCZOS)


def _mask_squircle(size: int) -> Image.Image:
    """圆角方形（三星 / 部分国产 ROM）。

    用大圆角近似超椭圆 —— 各家的实际曲率都不一样，
    这里只需要确认"四角被切掉多少"，不需要还原某一家的精确形状。
    """
    big = size * 4
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (0, 0, big - 1, big - 1),
        radius=int(big * 0.28),
        fill=255,
    )
    return m.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not SRC.exists():
        print(f"找不到 {SRC}\n先跑 python tools/build_icon.py 生成图标")
        return 2

    src = Image.open(SRC).convert("RGBA")
    size = src.size[0]
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for name, mask in (
        ("circle", _mask_circle(size)),
        ("squircle", _mask_squircle(size)),
    ):
        out = Image.new("RGBA", (size, size), (*WALLPAPER, 255))
        out.paste(src, (0, 0), mask)
        out.save(OUT_DIR / f"{name}.png", "PNG", optimize=True)
        print(f"tools/icon_preview/{name}.png")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
