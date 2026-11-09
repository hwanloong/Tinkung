"""把 proot 那套可执行文件 + 它的依赖库放进 `jniLibs/`。

## 为什么不能直接从 assets 里执行

Android 10（API 29）起，应用**只能执行"原生库目录"里的可执行文件**：
`/data/app/…/lib/<abi>/`。放在 `assets/` 里解出来的文件即使
`chmod +x` 也会被拒（`CANNOT LINK EXECUTABLE` / `Permission denied`，
而且报错完全不提"是路径不允许执行"）。

## 为什么依赖库也要放进来（而不是只放 proot）

`proot` 是动态链接的，依赖 `libtalloc.so.2`（还有 shmem 垫片）。
第一次跑只放了 proot，结果就是：

    CANNOT LINK EXECUTABLE "…/libproot.so": library "libtalloc.so.2" not found

因为 Android 装包时只会把**名字匹配 `lib*.so`** 的文件解到原生库目录，
而 `libtalloc.so.2` 不匹配那个模式，压根不会被装出来。

## 于是有两个必须处理的矛盾

1. **Android 要 `lib*.so`** —— 所以库在 APK 里必须叫 `libtalloc.so`；
2. **proot 要 `libtalloc.so.2`** —— 那是它编进去的 SONAME
   （实测字符串：`SONAME = libtalloc.so.2`），动态链接器会按这个名字找。

解法：**改文件名装出来，运行时用 `LD_LIBRARY_PATH` 指回去**。
详见 `LinuxRuntime.kt` 里构造环境变量那段 —— 那里同时挂了
loader 需要的路径，两件事是一个整体。

用法（`flutter build apk` **之前**跑）：
    python tools/stage_termux_native.py
"""

from __future__ import annotations

import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "termux"
DST = ROOT / "android" / "app" / "src" / "main" / "jniLibs" / "arm64-v8a"

# 源文件 -> jniLibs 里的名字。**名字必须是 lib*.so**，见模块注释。
MAP: dict[str, str] = {
    "proot": "libproot.so",
    "loader": "libproot_loader.so",
    "loader32": "libproot_loader32.so",
    # ---- 依赖库 ----
    #
    # `libtalloc.so`：proot 的 DT_NEEDED 原本写的是 `libtalloc.so.2`，
    # 而那个名字**不符合 `lib*.so`** —— Android 装包时不会把它解到
    # 原生库目录。所以 `tools/patch_proot_needed.py` 把 proot 里那条
    # DT_NEEDED 改成了 `libtalloc.so`，这里提供同名文件即可。
    #
    # （不要去建符号链接、也不要指望 LD_LIBRARY_PATH：前者在 Android 10+
    #   的 lib/ 下会被 SELinux 拦住，后者链接器对普通应用不采信。）
    "libtalloc.so.2": "libtalloc.so",
    # `libandroid-shmem.so`：**必须保持原名**。
    #
    # 它自己**没有 SONAME**，所以链接器是按"文件名"找它的 ——
    # 也就是 proot 的 DT_NEEDED 里那个字符串（实测就是
    # `libandroid-shmem.so`，带连字符）。改名成下划线会导致找不到，
    # 而且报错会说"library libandroid-shmem.so not found"，
    # 看起来像"少带了一个库"，实际是名字被我们改坏了。
    "libandroid-shmem.so": "libandroid-shmem.so",
}


def main() -> int:
    if not SRC.exists():
        print(f"找不到 {SRC}，先跑 tools/fetch_termux_assets.py")
        return 1

    DST.mkdir(parents=True, exist_ok=True)
    missing: list[str] = []

    for src_name, dst_name in MAP.items():
        s = SRC / src_name
        if not s.exists():
            missing.append(src_name)
            continue
        d = DST / dst_name
        shutil.copy2(s, d)
        # 校验：必须是 ELF，否则拷过去也是个不能链接的垃圾
        if d.read_bytes()[:4] != b"\x7fELF":
            print(f"  警告：{src_name} 不是 ELF，跳过")
            d.unlink()
            missing.append(src_name)
            continue
        print(f"  {src_name:22} -> jniLibs/arm64-v8a/{dst_name}  "
              f"({d.stat().st_size} bytes)")

    if missing:
        print(f"\n缺：{', '.join(missing)} —— 没拷全就跑不起来，别急着构建")
        return 1

    print("\n完成。现在可以 flutter build apk 了。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
