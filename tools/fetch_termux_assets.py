"""把 Termux/proot 运行时需要的二进制抓到 assets/termux/ 下。

## 为什么需要这一步

要做"把 Termux 整合进 app"，唯一可行的路是**自带一个 Linux 环境**：
proot（用户态 chroot/模拟）+ Alpine minirootfs（约 4MB 的极简 Linux）
+ 静态 apk（用来在里面装包）。这样**不依赖用户装 Termux**，
也不需要 `allow-external-apps` 那种手工配置。

这几个都是**二进制**，我这边生成不了，只能从源仓库拿。

## 源

参考实现 JIUSIS/shiyi-agent 的 `assets/termux/`：
  · proot            —— 用户态 chroot（Termux 打包的 aarch64 版）
  · loader/loader32  —— proot 依赖的 loader（必须和 proot 配套）
  · libtalloc.so.2   —— proot 的依赖
  · libandroid-shmem —— Termux 的共享内存垫片
  · apk.static       —— 静态链接的 apk，用来在 rootfs 里装包
  · alpine-minirootfs-3.24.1-aarch64.tar.gz —— Alpine 根文件系统

## 每个文件都校验

1. **尺寸**必须和源仓库报的一致（源里给了 size，对不上就说明下错了）；
2. **magic**要像可执行文件/压缩包（ELF / gzip），不然后面跑起来才报错，
   而那时候错误信息（Exec format error）跟"下错文件"完全看不出关系。

用法：
    python tools/fetch_termux_assets.py
"""

from __future__ import annotations

import gzip
import pathlib
import ssl
import sys
import urllib.request

OUT = pathlib.Path(__file__).resolve().parent.parent / "assets" / "termux"

RAW = "https://raw.githubusercontent.com/JIUSIS/shiyi-agent/main/assets/termux/"

# 文件名 -> 期望字节数（从源仓库读到的 size）
MANIFEST: dict[str, int] = {
    "proot": 239368,
    "loader": 18136,
    "loader32": 6244,
    "libtalloc.so.2": 31440,
    "libandroid-shmem.so": 14432,
    "apk.static": 4418872,
    "alpine-minirootfs-3.24.1-aarch64.tar.gz": 4023732,
}

ELF = b"\x7fELF"
GZIP = b"\x1f\x8b"


def head(path: pathlib.Path, n: int = 4) -> bytes:
    with path.open("rb") as f:
        return f.read(n)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    ctx = ssl.create_default_context()
    ok = 0

    for name, want in MANIFEST.items():
        dst = OUT / name
        if dst.exists() and dst.stat().st_size == want:
            print(f"[skip] {name} 已存在且尺寸正确")
            ok += 1
            continue

        url = RAW + name
        print(f"[get ] {name} … ({want} bytes)", flush=True)
        try:
            with urllib.request.urlopen(url, timeout=180, context=ctx) as r:
                data = r.read()
        except Exception as e:  # noqa: BLE001
            print(f"       失败：{type(e).__name__}: {e}")
            continue

        if len(data) != want:
            print(f"       尺寸不对：拿到 {len(data)}，期望 {want} —— 丢弃")
            continue

        dst.write_bytes(data)

        # magic 校验：可执行文件必须是 ELF，压缩包必须是 gzip
        h = head(dst)
        if name.endswith(".tar.gz"):
            if h[:2] != GZIP:
                print(f"       magic 不对：期望 gzip，实际 {h!r}")
                continue
            # 再确认能解开（只读头部，不解完整包）
            try:
                with gzip.open(dst, "rb") as g:
                    g.read(1024)
            except Exception as e:  # noqa: BLE001
                print(f"       gzip 打不开：{e}")
                continue
        else:
            if h[:4] != ELF:
                print(f"       magic 不对：期望 ELF，实际 {h!r}")
                continue

        print(f"       OK  {dst.stat().st_size} bytes")
        ok += 1

    print(f"\n完成 {ok}/{len(MANIFEST)} 个")
    if ok < len(MANIFEST):
        print("有文件没拿到 —— 缺任何一个都跑不起来，先别急着改代码。")
        return 1

    # ---- 顺手把 proot 的 DT_NEEDED 补丁打上 ----
    #
    # 放在这里自动执行，而不是要求使用者记得单独跑一次：
    # 忘了跑的表现是"在手机上 proot 起不来"，而那时候根本联想不到
    # "构建前少跑了一个脚本"。补丁本身是幂等的。
    print("\n应用 proot DT_NEEDED 补丁…")
    import subprocess

    r = subprocess.run(
        [sys.executable, str(pathlib.Path(__file__).parent / "patch_proot_needed.py")],
        capture_output=True,
        text=True,
    )
    print(r.stdout.strip())
    if r.returncode != 0:
        print(r.stderr.strip())
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
