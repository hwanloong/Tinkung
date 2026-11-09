"""把 proot 的 `DT_NEEDED` 从 `libtalloc.so.2` 改成 `libtalloc.so`。

## 为什么必须改二进制，而不是在运行时想办法

实测两次都失败：

    CANNOT LINK EXECUTABLE "…/libproot.so":
    library "libtalloc.so.2" not found: needed by main executable

试过的两条路都不行：

1. **符号链接**（在原生库目录里建 `libtalloc.so.2` → `libtalloc.so`）：
   Android 10+ 的 SELinux 不允许在 `lib/` 下创建新文件，
   `symlink()` 直接失败 —— 而且**失败是静默的**，
   我们只能靠"链接仍然报错"反推出它没建成。
2. **`LD_LIBRARY_PATH`**：Android 的动态链接器对普通应用**不采信**
   这个变量（安全限制），所以指了也没用。

所以只能改**需求方**：让 proot 自己要的那个名字，就是我们能提供的名字。

## 为什么这样改是安全的

`DT_NEEDED` 里存的是**文件名字符串**，链接器拿它去搜索路径里找文件。
把 `libtalloc.so.2` 换成 `libtalloc.so`（**更短**）之后：

· 字符串区大小不变，只是把多出来的字节写成 `\\0` —— 不会破坏 ELF 布局；
· 我们要提供的文件就叫 `libtalloc.so`（jniLibs 里那个），
  它符合 Android 的 `lib*.so` 规则，会被正常装到原生库目录；
· `DT_SONAME` **不动** —— 那是 "这个 .so 自称叫什么"，只在别人链接它时用，
  和"proot 要找谁"是两件事。

## 用法

    python tools/patch_proot_needed.py

在 `fetch_termux_assets.py` 之后、`stage_termux_native.py` 之前跑。
"""

from __future__ import annotations

import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROOT = ROOT / "assets" / "termux" / "proot"

OLD = b"libtalloc.so.2"
NEW = b"libtalloc.so"

# ELF 常量
PT_LOAD = 1
PT_DYNAMIC = 2
DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5


def patch() -> int:
    if not PROOT.exists():
        print(f"找不到 {PROOT}，先跑 tools/fetch_termux_assets.py")
        return 1

    data = bytearray(PROOT.read_bytes())
    if data[:4] != b"\x7fELF":
        print("不是 ELF")
        return 1
    if data[4] != 2:
        print("只支持 64 位 ELF")
        return 1

    # ---- 读程序头，找 PT_DYNAMIC ----
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]

    dyn_off = dyn_size = None
    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, off)[0]
        p_offset = struct.unpack_from("<Q", data, off + 8)[0]
        p_vaddr = struct.unpack_from("<Q", data, off + 16)[0]
        p_filesz = struct.unpack_from("<Q", data, off + 32)[0]
        if p_type == PT_DYNAMIC:
            dyn_off, dyn_size = p_offset, p_filesz
        if p_type == PT_LOAD:
            loads.append((p_vaddr, p_offset, p_filesz))

    if dyn_off is None:
        print("找不到 PT_DYNAMIC")
        return 1

    def vaddr_to_off(vaddr: int) -> int | None:
        for p_vaddr, p_offset, p_filesz in loads:
            if p_vaddr <= vaddr < p_vaddr + p_filesz:
                return p_offset + (vaddr - p_vaddr)
        return None

    # ---- 读 .dynamic，找 DT_STRTAB 和所有 DT_NEEDED ----
    strtab_vaddr = None
    needed_offsets: list[int] = []   # .dynamic 里存 DT_NEEDED 的位置
    entries = []
    for k in range(0, dyn_size, 16):
        tag, val = struct.unpack_from("<QQ", data, dyn_off + k)
        entries.append((dyn_off + k, tag, val))
        if tag == DT_NULL:
            break
    for pos, tag, val in entries:
        if tag == DT_STRTAB:
            strtab_vaddr = val
        elif tag == DT_NEEDED:
            needed_offsets.append(pos)

    if strtab_vaddr is None:
        print("找不到 DT_STRTAB")
        return 1
    strtab_off = vaddr_to_off(strtab_vaddr)
    if strtab_off is None:
        print("DT_STRTAB 的虚拟地址映射不到文件偏移")
        return 1

    # ---- 找值为 libtalloc.so.2 的那条 DT_NEEDED ----
    hit = None
    for pos, tag, val in entries:
        if tag != DT_NEEDED:
            continue
        at = strtab_off + val
        end = data.index(b"\x00", at)
        name = bytes(data[at:end])
        print(f"  DT_NEEDED: {name.decode(errors='replace')}")
        if name == OLD:
            hit = at

    if hit is None:
        # 可能已经改过了
        if bytes(data).find(NEW + b"\x00") >= 0 and bytes(data).find(OLD) < 0:
            print("已经是 libtalloc.so，不用改")
            return 0
        print(f"没找到 DT_NEEDED = {OLD.decode()}")
        return 1

    if len(NEW) > len(OLD):
        print("新名字更长，无法原地替换")
        return 1

    # ---- 原地替换 + 剩余字节清零 ----
    data[hit : hit + len(NEW)] = NEW
    for i in range(len(NEW), len(OLD)):
        data[hit + i] = 0

    # ---- 校验：写回后确认那一段确实变了 ----
    end = data.index(b"\x00", hit)
    got = bytes(data[hit:end])
    if got != NEW:
        print(f"写入后校验失败：{got!r}")
        return 1

    PROOT.write_bytes(bytes(data))
    print(f"已改：{OLD.decode()} -> {NEW.decode()}（{PROOT}）")
    return 0


if __name__ == "__main__":
    sys.exit(patch())
