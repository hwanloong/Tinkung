"""把用户给的新图标（webp）装成 `assets/icon/source.png`。

## 为什么要过一道脚本，而不是直接拷文件

三条具体原因：
1. 附件是 **WebP**，而图标流水线（`tools/build_icon.py`）和 Android 资源
   都按 PNG 走 —— 直接改扩展名不解码，`build_icon.py` 会按 WEBP 打开成功
   但后续 `save('...png')` 依赖 PIL 的模式判断，容易出带 alpha 问题的图。
2. 源图是 **384×384**，流水线要 512×512 起。像素风放大必须选对重采样：
   用 NEAREST 会让那圈圆角变成锯齿（圆角是抗锯齿绘制的，不是硬边）；
   用 LANCZOS 保圆角、像素格也只软一点点。所以这里显式指定 LANCZOS
   并把结果对齐到 512，**不是**随手 resize。
3. 需要强制 RGBA：源图是不透明的黑底，但 Android 的自适应图标前景层
   按 alpha 处理，缺通道会在遮罩边缘出现硬切。
"""

from __future__ import annotations

import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    print("需要 Pillow：pip install Pillow")
    raise SystemExit(2)

SRC = pathlib.Path(
    r"C:\Users\lmqhw\AppData\Roaming\dsh-desktop\harness\attachments"
    r"\v1\objects\62\6257a976f88bc28961d534c90f5cf6d79ae06f5d060f4c07db48c971fc9cfc33"
)
DST = pathlib.Path("assets/icon/source.png")

if not SRC.exists():
    print(f"源图不存在：{SRC}")
    raise SystemExit(1)

im = Image.open(SRC)
print(f"源：{im.size} {im.mode} {im.format}")

# 备份旧图标，方便回滚（旧图是绿色外星人）
if DST.exists():
    old = DST.with_name("source.prev.png")
    if not old.exists():
        DST.replace(old)
        print(f"旧图标已备份到 {old}")

im = im.convert("RGBA")
if im.size != (512, 512):
    im = im.resize((512, 512), Image.Resampling.LANCZOS)
    print("已缩放到 512×512（LANCZOS：保圆角抗锯齿）")

DST.parent.mkdir(parents=True, exist_ok=True)
im.save(DST, "PNG", optimize=True)
print(f"写入 {DST}  {DST.stat().st_size} 字节")
