"""从一张 512×512 的成品图生成 Android 启动图标。

## 为什么这个脚本和 `gen_icon.py` 不一样

`gen_icon.py`（已删除）是**用代码画**图标：气泡、眼睛都是几何图元拼的。
这一版换成了**一张画好的像素图**（绿外星人）—— 那种手绘的像素画没法
用几行几何代码还原，硬画只会得到一个"意思差不多但不是它"的东西。

所以这里做的事就是 **缩放 + 摆放**：
  · 生成 5 个密度的方形 / 圆形图标；
  · 生成自适应图标的全幅图（整张图当背景层，见下）。

## 为什么源图不进仓库

它是别人的作品（经典像素外星人）。把它提交到公开仓库等于替原作者决定
分发范围。所以和字体一样：**源图放本地、不进仓库**，
仓库里只有这个脚本和 `.gitignore` 里那行规则。

## 源图放哪

    assets/icon/source.png        512×512（或更大，方形）

## 自适应图标为什么要缩到 56%

Android 8+ 的画布是 108dp，但外围一圈会被启动器按自己的形状裁掉，
**只有中间 66dp 直径的圆**保证可见。源图已经是"满幅 + 圆角"的成品，
正方形四角本来就在安全圆之外 —— 直接铺满的话，圆形启动器会把它裁成
一个比源图圆角更大的圆，看起来"被啃了一口"。

缩到 56% 之后整张图（连圆角）都落在安全圆内，任何遮罩下都完整。

用法：
    python tools/build_icon.py
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print("需要 Pillow：pip install Pillow")
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "icon" / "source.png"
RES = ROOT / "android" / "app" / "src" / "main" / "res"

# 自适应图标画布（108dp × 4 = xxxhdpi）
ADAPTIVE = 432

# 主体在自适应画布里的比例。
#
# ## 为什么是 0.68 而不是 0.56
#
# 0.56 是"整张图（含它自带的圆角）都落在 66dp 安全圆内"的理论值。
# 但那样出来**明显偏小**：安全圆是给**图形本身**定的，而源图是一张
# 已经带好内边距的成品 —— 圆角方块外面还有一圈它自己的留白。
# 按 0.56 缩完，外星人的实际视觉大小只有传统图标的一半左右，
# 放在桌面上比旁边的图标小一圈。
#
# 0.68 是实测的折中：
#  · 深色底是一张大圆角方块，即使四角被圆形遮罩切掉一点也**看不出来**
#    （它本来就是圆角，切掉的是弧边外侧）；
#  · 外星人主体（深色底里那 68% 左右）仍然完整落在安全圆内，
#    任何遮罩下都不会被切。
ADAPTIVE_CONTENT = 0.68

# 传统图标（方形，API < 26）里图案占多少。
#
# 0.88：满幅源图（底色铺到画布边缘、图案本身约占 63%）按原样缩小一档。
# 不缩的话图案在 48dp 的桌面上显得过于顶格 —— 用户的反馈是"图标铺太满了"。
LEGACY_CONTENT = 0.88

# 传统图标（API < 26）的每个密度
DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# 预览底色（和 gen_icon 的预览工具保持一致，方便对比）
WALLPAPER = (0xEC, 0xE6, 0xF0)


def _flatten(img: Image.Image) -> Image.Image:
    """把透明像素填成图里的主色调，做成一张**满幅方图**。

    ## 为什么必须填

    源图是"圆角方块 + 四角透明"。而：
    · 传统图标（API < 26）**没有遮罩**，四角透明就是四个洞 ——
      在浅色桌面上看着像图标缺了四个角；
    · 自适应图标要求背景层是满幅的，留透明会露出一块不是我们控制的底色。

    ## 填什么颜色

    取图里**占比最大的不透明颜色**，而不是写死 `#232A31`：
    换个配色的源图时不用改代码。同一个色填进去之后，
    圆角和方角在视觉上无缝 —— 因为本来就是同一个深色底。
    """
    rgba = img.convert("RGBA")
    # 统计不透明像素的颜色，取最多的那个（量化到 8 级，避免噪声分裂）
    counts: dict[tuple[int, int, int], int] = {}
    for r, g, b, a in rgba.getdata():
        if a < 250:
            continue
        key = (r // 8 * 8, g // 8 * 8, b // 8 * 8)
        counts[key] = counts.get(key, 0) + 1
    if not counts:
        return rgba, (0, 0, 0)
    bg = max(counts.items(), key=lambda kv: kv[1])[0]

    flat = Image.new("RGBA", rgba.size, (*bg, 255))
    flat.paste(rgba, (0, 0), rgba)
    print(f"背景色（源图主色）: rgb{bg}")
    return flat, bg


def _resize(img: Image.Image, size: int) -> Image.Image:
    """等比缩放到 size×size，用 LANCZOS。

    源图是**像素画**，所以缩放方式很要紧：
    · `NEAREST` 在小尺寸下会把像素格子切得七零八落（有的格子 2px、
      有的 3px），外星人的轮廓会变得不匀；
    · `LANCZOS` 平滑降采样，48px 下虽然像素边界糊了一点，
      但**整体形状是对的** —— 而图标在桌面上第一眼看的是形状。
    """
    return img.convert("RGBA").resize((size, size), Image.LANCZOS)


def _center_on_canvas(
    img: Image.Image,
    canvas: int,
    content: float,
    bleed: tuple[int, int, int] | None = None,
) -> Image.Image:
    """把图按 content 比例缩到 canvas 上并居中。

    [bleed] 是**铺满整个画布的底色**（`None` = 四周留透明）。

    ## 为什么自适应图标必须给 bleed

    自适应图标会被启动器按**任意形状**裁切。如果画布四周是透明的、
    只中间放一块"深色圆角方块"，那么：
      · 圆形遮罩 → 方块四角被切掉，露出的正好是**透明/浅色**的四个角，
        图标看起来像被啃了一口；
      · 圆角方形遮罩 → 反而没事。

    所以让深色底**铺满画布**：任何形状裁出来都是"一整块深色 + 中间的外星人"，
    圆形就是标准圆形图标，圆角方形就是标准圆角方形图标 —— 两种都成立。

    主体仍然按 content 缩放居中，保证不会被裁到。
    """
    side = max(1, int(round(canvas * content)))
    scaled = img.convert("RGBA").resize((side, side), Image.LANCZOS)
    out = Image.new(
        "RGBA",
        (canvas, canvas),
        (*(bleed or (0, 0, 0)), 255) if bleed else (0, 0, 0, 0),
    )
    off = (canvas - side) // 2
    out.paste(scaled, (off, off), scaled)
    return out


def _edge_extend(img: Image.Image, content: float, canvas: int) -> Image.Image:
    """把图缩到 [content] 比例居中，四周用**边缘延展**补满。

    这是给"满幅底色 + 中间一个图案"这类源图用的。

    ## 为什么不直接铺一块纯色

    底色其实带一点渐变（`#DF6A40` 到 `#E5653E`，四角和中心差几个色阶）。
    铺纯色会在图案外围留下一圈**方框接缝** —— 放大看不清，缩到 48px
    反而最明显，因为那一圈会被平均成一条硬边。

    边缘延展是把缩放后图片的**最外一行/一列像素**向外重复，
    渐变在每个方向上继续延伸，接缝不可见。

    ## 为什么不能简单地把整张图缩小

    缩小时图案和底色是一起缩的 —— 底色就不再铺满画布了，
    遮罩外面露出透明角。所以必须"图案缩小 + 底色补齐"两步分开。
    """
    side = max(1, int(round(canvas * content)))
    scaled = img.convert("RGBA").resize((side, side), Image.LANCZOS)
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    off = (canvas - side) // 2

    # 先把中间那块放好，再按四个方向拉边缘。
    out.paste(scaled, (off, off))

    left = scaled.crop((0, 0, 1, side)).resize((off, side), Image.NEAREST)
    right = scaled.crop((side - 1, 0, side, side)).resize(
        (canvas - side - off, side), Image.NEAREST
    )
    out.paste(left, (0, off))
    out.paste(right, (side + off, off))

    # 上下的延展要**覆盖到新补出来的左右两翼**，所以宽度取整幅。
    top_row = out.crop((0, off, canvas, off + 1)).resize(
        (canvas, off), Image.NEAREST
    )
    bot_row = out.crop((0, side + off - 1, canvas, side + off)).resize(
        (canvas, canvas - side - off), Image.NEAREST
    )
    out.paste(top_row, (0, 0))
    out.paste(bot_row, (0, side + off))
    return out


def main() -> int:
    if not SOURCE.exists():
        print(f"找不到源图：{SOURCE}")
        print("把一张方形 PNG 放到那里（512×512 或更大），再跑一次。")
        return 2

    src = Image.open(SOURCE)
    print(f"源图 {src.size[0]}×{src.size[1]} {src.mode}")
    # 先判断源图是不是**满幅不透明**（四角没有透明像素）。
    #
    # 两种源图在自适应图标里的处理是相反方向的：
    #  · 满幅（四角不透明）：整张图直接铺满 108dp 画布（content = 1.0），
    #    启动器裁成圆形时切掉的只是底色，不会露出透明角；
    #  · 带圆角留白（四角透明）：必须缩到 ADAPTIVE_CONTENT 以内，
    #    再垫一层主色铺满，否则四角就是四个洞。
    #
    # 不判断的话，满幅图会被按 0.68 缩一次 —— 图案缩进安全区之后，
    # 外围那圈透明正好落在遮罩以外，圆形启动器上看到的是
    # "一个橙色圆 + 中间有个更小的 T"，四周还有一圈透明边。
    corners = src.convert("RGBA").load()
    w, h = src.size
    full_bleed = all(
        corners[x, y][3] >= 250
        for x, y in ((2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3))
    )
    print(f"满幅不透明: {full_bleed}")
    src, bg = _flatten(src)

    # ---- 传统方形 / 圆形图标 ----
    #
    # 满幅源图缩到 LEGACY_CONTENT（四周用边缘延展补底色）：图案离边的
    # 留白和自适应图标一致，桌面上两个图标看起来才是同一个"重量"。
    for name, size in DENSITIES.items():
        if full_bleed:
            out = _edge_extend(src, LEGACY_CONTENT, size)
        else:
            out = _resize(src, size)
        for suffix in ("ic_launcher", "ic_launcher_round"):
            dst = RES / f"mipmap-{name}" / f"{suffix}.png"
            dst.parent.mkdir(parents=True, exist_ok=True)
            out.save(dst, "PNG", optimize=True)
        print(f"mipmap-{name}: {size}×{size} ×2")

    # ---- 自适应图标 ----
    #
    # 背景层铺满 108dp 画布，前景层留空。
    #
    # 满幅源图（底色到边）走 [_edge_extend]：图案缩到 [ADAPTIVE_CONTENT]
    # 以内，底色靠边缘延展铺满。**content 必须让图案落在 66dp 安全圆里** ——
    # 这张图的白色 T 半径是画布半径的 86%，直接铺满时圆形启动器会切掉
    # 它上面和右边的尖角（用户报的"超过遮罩"就是这个）。
    for name, size in DENSITIES.items():
        canvas = max(24, int(round(ADAPTIVE * size / 192)))
        if full_bleed:
            out = _edge_extend(src, ADAPTIVE_CONTENT, canvas)
        else:
            out = _center_on_canvas(src, canvas, ADAPTIVE_CONTENT)
        out.save(
            RES / f"mipmap-{name}" / "ic_launcher_photo.png",
            "PNG",
            optimize=True,
        )
    print(f"adaptive: {ADAPTIVE}×{ADAPTIVE} + 4 个降采样密度")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
