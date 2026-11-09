"""为**测试渲染图**生成一份中文字体子集。

## 为什么要子集，而不是直接用完整字体

预览测试（`test/ui_preview_test.dart` / `markdown_preview_test.dart`）要真的
把中文画出来才能验证排版 —— 而 flutter_test 环境里**没有系统字体**，
所以必须给 `sans-serif` / `monospace` 这两个系统族名注册一份带汉字的替身。

直接用完整的 CJK 字体会带进 17MB（还要进 APK，因为 Flutter 打包时
`assets:` 里声明的东西一个都不落）。而渲染图里出现的汉字就那么多，
抽成一个几十 KB 的子集完全够用。

## 为什么不需要在字体里做"回退"

子集**只包含汉字和中文标点**，不包含拉丁字母 —— 这是有意的：
拉丁字母本来就该由 San Francisco Display 命中，子集里没有它们，
就不会出现"英文被中文字体抢走"的情况。

用法（在仓库根目录）：

    python tools/subset_font.py C:\\Windows\\Fonts\\NotoSansSC-VF.ttf \
                                assets/fonts/CJK-subset.ttf

## 源字体该用哪一个

**用系统的 `NotoSansSC-VF.ttf`（可变字体），不是 `.ttc`。**

项目文档以前写的是 `assets/fonts/NotoSansCJK-Regular.ttc`，但那份文件
**从来就不存在** —— 按那条命令跑会直接报 not found。Windows 上自带的是
`C:\\Windows\\Fonts\\NotoSansSC-VF.ttf`；Linux/macOS 上找思源黑体
（Source Han Sans SC）的同名可变字体即可。

可变字体这条路径脚本已经处理好（见下面"固化成静态实例"那段）。
换成 `.ttc` 也能跑，但 `.ttc` 是**字体集合**，`subset.load_font` 只会读
第 0 个字重 —— 想要某个特定字重还得先用 `tools/extract_ttc.py` 抽出来。

## 什么时候必须重跑

**每次往界面里加了新的汉字**之后。子集只含源码里出现过的字，
新文案里的新字在渲染图上会是一个空方块 —— 而那个方块看起来
非常像"字体没配好"，很容易查错方向。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# 除汉字之外还要保留的字符：
# · 中文标点、全角符号（界面文案里大量使用）
# · 方框绘制字符（风险分级、状态提示里会用）
# · 常用数学/箭头符号（markdown 样本里有）
EXTRA = (
    "　、。〈〉《》「」『』【】〔〕〖〗！＂＃＄％＆＇（）＊＋，－．／"
    "０１２３４５６７８９：；＜＝＞？＠ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ"
    "［＼］＾＿｀ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ｛｜｝～"
    "·—…‘’“”※←→↑↓↔⇒✓✗✕●○◆◇■□▪▫★☆"
    "±×÷≠≤≥∞√∑∏∫≈≡∈∉⊂⊃∪∩∧∨¬∀∃"
)


def collect_chars(root: Path) -> set[str]:
    """扫描 lib/ 和 test/ 的 .dart 源码，收集里面出现的所有非 ASCII 字符。

    按源码扫而不是"猜常用字"：渲染图里出现的字，必然在源码或测试样本里
    以字面量的形式出现过（界面文案、测试数据）。扫一遍就够了，
    不会因为漏了一个字而在图上留下一个空方块。
    """
    chars: set[str] = set()
    for sub in ("lib", "test"):
        for path in (root / sub).rglob("*.dart"):
            for ch in path.read_text(encoding="utf-8", errors="ignore"):
                if ord(ch) > 0x7F:
                    chars.add(ch)
    # 字体自带的 .md 说明里也有中文（README 里贴了界面文案）
    for path in (root / "assets").rglob("*.md"):
        for ch in path.read_text(encoding="utf-8", errors="ignore"):
            if ord(ch) > 0x7F:
                chars.add(ch)
    return chars


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2

    src, dst = Path(argv[1]), Path(argv[2])
    root = Path(__file__).resolve().parent.parent

    chars = collect_chars(root)
    chars.update(EXTRA)
    # 空白和换行不需要字形
    chars.discard("\n")
    chars.discard("\r")
    chars.discard("\t")

    from fontTools import subset  # 延迟导入：只有真的要用才要求装了它
    from fontTools.varLib import instancer

    text = "".join(sorted(chars))
    print(f"源码里出现的非 ASCII 字符：{len(chars)} 个")

    options = subset.Options()
    # 保留 OpenType 布局表：否则字距、连字全没了，排版看着会怪
    options.layout_features = ["*"]
    options.drop_tables = ["BASE", "vhea", "vmtx", "VORG"]
    # 不做"只留用到的字形"之外的裁剪，保留 name 表以便排查
    options.name_IDs = ["*"]
    options.notdef_outline = True
    options.recalc_bounds = True

    font = subset.load_font(str(src), options)

    # ---- 把可变字体**固化**成一个静态实例 ----
    #
    # 这一步不是优化，是**必须的**。源字体是可变字体（带 `fvar` / `gvar`），
    # 而子集化只裁 `glyf` 的字形，`gvar` 里的增量数据仍然指着原字体的
    # 字形集。结果是一份自相矛盾的字体：cmap 和轮廓都在、字宽也对，
    # 但 Flutter 的字体后端（Skia）光栅化时画不出字形 ——
    # **在渲染图上表现为每个汉字都是一个空心方块**，而同一个字用系统
    # 字体渲染又完全正常，非常容易误判成"字体没加载"。
    #
    # 固化之后 `fvar` / `gvar` / `HVAR` / `avar` / `STAT` 都不再需要，
    # 字体变成普通的静态 TTF，任何环境都能画。
    if "fvar" in font:
        # 按**Regular**固化，而不是按字体的默认轴值。
        #
        # 默认值不一定是 400：这份 Noto Sans SC 可变字体的 `wght` 默认值是
        # **100（Thin）** —— 直接用默认值固化出来的替身会是极细的笔画，
        # 在预览图上看起来"字很虚"，很容易被当成渲染有问题。
        wanted = {"wght": 400.0, "opsz": None}
        axes: dict[str, float] = {}
        for axis in font["fvar"].axes:
            want = wanted.get(axis.axisTag)
            if want is None:
                # 其余轴（比如 opsz 光学尺寸）取默认值就好
                axes[axis.axisTag] = axis.defaultValue
            else:
                axes[axis.axisTag] = min(max(want, axis.minValue), axis.maxValue)
        print(f"可变字体，按 {axes} 固化成静态实例")
        font = instancer.instantiateVariableFont(font, axes, inplace=False)

    subsetter = subset.Subsetter(options=options)
    subsetter.populate(text=text)
    subsetter.subset(font)
    subset.save_font(font, str(dst), options)
    font.close()

    print(f"{dst}  {dst.stat().st_size // 1024} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
