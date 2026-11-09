"""一次性脚本：把各页面左上角的返回按钮统一成单一图标样式。

## 背景

从前每个二级页面都在 `AppHeader(leading:)` 里塞一个 `GlassIconButton`
（液态玻璃圆片 + `arrow_back_ios_new_rounded`）。转 Material You 之后：

· 玻璃圆片在这个位置是多余的装饰 —— 顶栏已经没有背板了，
  一个孤零零的玻璃圆钮反而成了新的"小块"；
· `arrow_back_ios_new_rounded` 是 iOS 的细箭头，中文界面下显得小气。

统一成 Flutter 自带的 `BackButton`：系统标准图标（`Icons.arrow_back`）、
尺寸和点击区域由框架按平台给、颜色自动跟 `IconTheme` / `AppBarTheme` 走。
一处定义、全项目一致，也不会再有人"顺手"给某一个页面换成玻璃样式。

用法（放在 tools/ 下，一次性）：
    python tools/unify_back_buttons.py
"""

from __future__ import annotations

import pathlib
import re

# 匹配 GlassIconButton( ... icon: arrow_back_ios_new_rounded ... )
# 两个变体：多行（AppHeader 里那种）和单行。用宽松的 DOTALL 匹配，
# 再靠"必须含 arrow_back_ios_new_rounded"把它和别的 GlassIconButton 区分开。
PATTERN = re.compile(
    r"GlassIconButton\(\s*"
    r"icon:\s*Icons\.arrow_back_ios_new_rounded,\s*"
    r"tooltip:\s*'返回',\s*"
    r"size:\s*\d+,\s*"
    r"iconSize:\s*\d+,\s*"
    r"onTap:\s*(?P<cb>[^,]+?),\s*"
    r"\)",
    re.S,
)

# 浏览器页那个是"能返回就返回，否则关页面"，回调名和提示都不一样，单独处理
BROWSER = re.compile(
    r"GlassIconButton\(\s*"
    r"icon:\s*Icons\.arrow_back_ios_new_rounded,\s*"
    r"tooltip:\s*'后退',\s*"
    r"size:\s*\d+,\s*"
    r"iconSize:\s*\d+,\s*"
    r"onTap:\s*(?P<cb>[^,]+?),\s*"
    r"\)",
    re.S,
)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent / "lib" / "ui"
    total = 0

    for path in sorted(root.rglob("*.dart")):
        text = path.read_text(encoding="utf-8")

        def replace(m: re.Match[str]) -> str:
            cb = " ".join(m.group("cb").split())
            return f"BackButton(onPressed: {cb})"

        new = PATTERN.sub(replace, text)
        new = BROWSER.sub(replace, new)

        if new != text:
            n = len(PATTERN.findall(text)) + len(BROWSER.findall(text))
            total += n
            path.write_text(new, encoding="utf-8", newline="")
            print(f"{path.name}: {n} 处")

    print(f"共替换 {total} 处")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
