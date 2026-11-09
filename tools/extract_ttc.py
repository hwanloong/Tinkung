"""从 simsun.ttc 里抽出第 N 个字体，写成独立的 .ttf。

## 为什么需要它

`pubspec.yaml` 里声明了 `assets/fonts/simsun.ttf`，而微软分发的宋体是
**TrueType 集合**（`simsun.ttc`：一个文件装 SimSun + NSimSun 两个字族）。
Flutter 对 `.ttc` 的支持不明确 —— 最坏的情况是加载失败后**静默回退**到
系统默认字体：界面上中文变成黑体，而这种问题在手机上不容易当场发现。

所以构建前必须把集合里的 SimSun 抽成一个普通 sfnt 文件。

## 为什么是"重写表目录 + 截断"而不是原样搬运

TTC 里的每个字体共用一整块表数据区，各表的 `offset` 是**相对整个 .ttc 文件**
的绝对偏移。要抽出来必须：

1. 把该字体的 sfnt 头 + 表目录原样抄到新文件开头（偏移 0 处），
   这样表目录里的 `offset` 依然指向正确的位置；
2. **保留 0 到"该字体所有表的末尾"这一整段**（中间可能夹杂另一个字体的表，
   那些字节会被一起带上，但不影响解析 —— 表目录不会引用它们）；
3. 截掉末尾用不到的部分。

第 3 步是必须的：不截断的话，抽出来的"simsun.ttf"和 `.ttc` 一样大（17.8MB），
而真正的 SimSun 表只占其中一部分。

用法：
    python tools/extract_ttc.py assets/fonts/simsun.ttc assets/fonts/simsun.ttf 0
    python tools/extract_ttc.py assets/fonts/simsun.ttc --list
"""

import struct
import sys


def _read_u32(data: bytes, off: int) -> int:
    return struct.unpack_from(">I", data, off)[0]


def _prefix_length(data: bytes) -> int:
    """TTC 头部长度 —— 也就是表数据区从哪个字节开始。

    这是最容易搞错的一处：**TTC 1.0 和 2.0 的头部不一样长**。

    · 1.0：`ttcf` + major(2) + minor(2) + numFonts(4) + offsets[N] = 12 + 4N
    · 2.0：在上面之后**还有 12 字节**的 DSIG 字段
      （ulDsigTag / ulDsigLength / ulDsigOffset）

    宋体用的正是 2.0（版本号 00 02 00 00），头部是 32 字节而不是 20。
    按 1.0 算的话，抄进新文件的"头部"会**少 12 字节**，
    于是整个表目录错位 12 字节 —— 解析器读出来的第一个四字节标签是 0x00000000，
    字体直接无效（而文件大小看起来还挺正常，很难发现）。
    """
    major = struct.unpack_from(">H", data, 4)[0]
    num = _read_u32(data, 8)
    base = 12 + 4 * num
    return base + 12 if major >= 2 else base


def parse(data: bytes):
    """返回 [(index, family_name, max_table_end)]。"""
    if data[:4] != b"ttcf":
        raise SystemExit("这不是 TTC 文件（开头不是 ttcf）")
    num = _read_u32(data, 8)
    offsets = [_read_u32(data, 12 + 4 * i) for i in range(num)]

    out = []
    for idx, off in enumerate(offsets):
        num_tables = struct.unpack_from(">H", data, off + 4)[0]
        family = "?"
        max_end = 0
        for t in range(num_tables):
            rec = off + 12 + 16 * t
            tag = data[rec : rec + 4]
            table_off = _read_u32(data, rec + 8)
            table_len = _read_u32(data, rec + 12)
            max_end = max(max_end, table_off + table_len)
            if tag == b"name":
                family = _read_family(data, table_off, table_len) or family
        out.append((idx, family, max_end))
    return out


def _read_family(data: bytes, off: int, length: int) -> str | None:
    """从 name 表里读 nameID=1（family）。

    优先取 Windows 平台的 UTF-16BE 记录（nameID 1，platformID 3），
    否则退回第一个 nameID=1 的记录。
    """
    try:
        count = struct.unpack_from(">H", data, off + 2)[0]
        string_off = struct.unpack_from(">H", data, off + 4)[0]
    except struct.error:
        return None

    fallback = None
    for i in range(count):
        rec = off + 6 + 12 * i
        if rec + 12 > off + length:
            break
        platform, encoding, _lang, name_id, slen, soff = struct.unpack_from(
            ">HHHHHH", data, rec
        )
        if name_id != 1:
            continue
        start = off + string_off + soff
        raw = data[start : start + slen]
        if platform == 3:
            return raw.decode("utf-16-be", "ignore")
        if fallback is None:
            fallback = raw.decode("latin-1", "ignore")
    return fallback


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2

    src = argv[1]
    with open(src, "rb") as fh:
        data = fh.read()

    fonts = parse(data)

    if argv[2] == "--list":
        for idx, family, end in fonts:
            print(f'[{idx}] family="{family}"  表数据到 {end} 字节')
        return 0

    dst = argv[2]
    want = int(argv[3]) if len(argv) > 3 else 0
    match = [f for f in fonts if f[0] == want]
    if not match:
        raise SystemExit(f"集合里没有第 {want} 个字体（共 {len(fonts)} 个）")

    _idx, family, end = match[0]

    font_off = _read_u32(data, 12 + 4 * want)
    num_tables = struct.unpack_from(">H", data, font_off + 4)[0]
    prefix = _prefix_length(data)

    # ---- 拼出新文件 ----
    #
    # 1) 该字体自己的 sfnt 头 + 表目录（从它的 offset 开始，12 + 16*numTables 字节）。
    #    表目录里的 offset 是相对**整个 .ttc** 的绝对偏移，
    #    所以下面必须从 0 开始把数据区原样铺满，不能只从 prefix 之后抄。
    # 2) 从文件开头到"该字体所有表的末尾"的全部字节。
    #    中间可能夹着另一个字体的表 —— 一起带上，反正表目录不引用它们。
    header = data[font_off : font_off + 12 + 16 * num_tables]
    body = data[:end]

    out = header + body

    with open(dst, "wb") as fh:
        fh.write(out)

    magic = out[:4].hex(" ")
    print(
        f'抽出 [{want}] family="{family}" -> {dst}  '
        f"{len(out)} 字节（源文件 {len(data)} 字节）  sfnt 头: {magic}"
    )
    if out[:4] != b"\x00\x01\x00\x00" and out[:4] != b"OTTO" and out[:4] != b"true":
        print("警告：抽出来的文件开头不是合法的 sfnt 标签，字体可能无法加载")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
