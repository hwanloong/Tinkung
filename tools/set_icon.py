"""把一张新图装成 `assets/icon/source.png`，并立刻生成全套 Android 图标。

## 用法

    python tools/set_icon.py D:\\path\\to\\new_icon.png

不给路径时，会去几个常见位置找（见 CANDIDATES），找到就用。

## 为什么要过一道脚本

三条具体原因，都是踩过的：

1. **源图尺寸不一定是 512**。`build_icon.py` 从 512 起，小了会被放大糊掉。
   这里统一用 LANCZOS 缩到 512（保抗锯齿，不会像 NEAREST 那样把圆角变锯齿）。
2. **必须强制 RGBA**。自适应图标的前景层按 alpha 处理，缺通道会在
   遮罩边缘出现硬切。
3. **旧图标要备份**。换图标之后如果用户说"还是原来那个好"，
   没有备份就只能重画。

## 和 build_icon.py 的分工

  · 这个脚本：**取图 + 归一化**（任何尺寸/格式 → 512×512 RGBA PNG）
  · build_icon.py：**分发**（512 PNG → 5 个密度的方形/圆形/自适应）

分开是因为两者的触发条件不同：换图才需要跑第一个，改了布局参数
只需要重跑第二个。
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys

try:
    from PIL import Image
except ImportError:
    print("需要 Pillow：pip install Pillow")
    raise SystemExit(2)

ROOT = pathlib.Path(__file__).resolve().parent.parent
DST = ROOT / "assets" / "icon" / "source.png"
PREV = ROOT / "assets" / "icon" / "source.prev.png"

# 不给参数时按这些位置找。都是"用户可能把图放这儿"的合理位置。
CANDIDATES = [
    pathlib.Path.home() / "Downloads",
    pathlib.Path.home() / "Desktop",
    pathlib.Path.home() / "Pictures",
    ROOT / "assets" / "icon",
]


def find_source() -> pathlib.Path | None:
    """在常见目录里找最近改过的图片。"""
    newest: pathlib.Path | None = None
    newest_mtime = 0.0
    for d in CANDIDATES:
        if not d.is_dir():
            continue
        for ext in ("*.png", "*.jpg", "*.jpeg", "*.webp"):
            for p in d.glob(ext):
                # 跳过我们自己生成的产物，否则会反复把自己当新图
                if p.name.startswith("ic_launcher"):
                    continue
                if p.resolve() == DST.resolve():
                    continue
                if p.resolve() == PREV.resolve():
                    continue
                m = p.stat().st_mtime
                if m > newest_mtime:
                    newest = p
                    newest_mtime = m
    return newest


def main() -> int:
    if len(sys.argv) > 1:
        src = pathlib.Path(sys.argv[1])
        if not src.is_absolute():
            src = (pathlib.Path.cwd() / src).resolve()
    else:
        src = find_source()
        if src is None:
            print("没找到源图。用法：python tools/set_icon.py <图片路径>")
            print("（也会自动在 下载 / 桌面 / 图片 目录里找最近改过的那张）")
            return 1
        print(f"自动选中最新的图：{src}")

    if not src.exists():
        print(f"源图不存在：{src}")
        return 1

    im = Image.open(src)
    print(f"源：{src.name}  {im.size} {im.mode} {im.format}")

    # 备份旧图：换错了能立刻退回去
    if DST.exists():
        shutil.copy2(DST, PREV)
        print(f"旧图标已备份到 {PREV.name}")

    im = im.convert("RGBA")
    if im.size != (512, 512):
        # 先等比缩到能盖住 512 的最小尺寸，再居中裁切 ——
        # 直接拉伸会把非正方形的图压扁（新图标是正方形，但别人给的不一定）。
        w, h = im.size
        scale = max(512 / w, 512 / h)
        im = im.resize((max(512, round(w * scale)), max(512, round(h * scale))),
                       Image.Resampling.LANCZOS)
        left = (im.width - 512) // 2
        top = (im.height - 512) // 2
        im = im.crop((left, top, left + 512, top + 512))
        print("已归一化到 512×512（等比缩放 + 居中裁切，LANCZOS）")

    DST.parent.mkdir(parents=True, exist_ok=True)
    im.save(DST, "PNG", optimize=True)
    print(f"写入 {DST.relative_to(ROOT)}  {DST.stat().st_size} 字节")

    # 立刻分发到各密度
    print("\n生成 Android 图标...")
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "build_icon.py")],
        cwd=ROOT,
    )
    if r.returncode != 0:
        print("build_icon.py 失败，图标没换全。")
        return r.returncode

    print("\n完成。下次构建 APK 就会用新图标。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
