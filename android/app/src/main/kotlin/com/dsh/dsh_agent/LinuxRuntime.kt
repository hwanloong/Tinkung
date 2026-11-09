package com.dsh.dsh_agent

import android.content.Context
import android.system.Os
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.concurrent.TimeUnit

/**
 * **自带的 Linux 环境**：proot + Alpine minirootfs。
 *
 * ## 它解决什么问题
 *
 * 之前终端走的是 Termux 的 `RUN_COMMAND` 广播，那有三个绕不过去的毛病：
 *  1. 用户**必须先装 Termux**；
 *  2. 还得手工打开 `allow-external-apps`（一个连查都查不到的设置）；
 *  3. 广播**只在命令跑完时回一次结果** —— 没有 stdout 流、没有 stdin，
 *     所以 `vim` / REPL / `apt` 的 y-n 提示全都用不了。
 *
 * 现在这一套是**完全自带**的：APK 里就带着 proot 和 Alpine，
 * 首次使用时把 rootfs 解到应用私有目录，之后直接在里面跑命令。
 * 不依赖任何外部应用，也不需要任何手工配置。
 *
 * ## 为什么要 proot
 *
 * Android 不允许普通应用 `chroot`（需要 root）。proot 用 **ptrace**
 * 在用户态拦截路径解析，模拟出一个 chroot —— 不需要 root，
 * 代价是系统调用多一层转发（慢一些，但跑 shell/包管理完全够）。
 *
 * ## 关键的一个坑：可执行文件必须在原生库目录
 *
 * Android 10（API 29）起只允许执行 `/data/app/…/lib/<abi>/` 下的文件。
 * 把 proot 放在 assets 或 filesDir 里解出来**即使 chmod +x 也不能执行**
 * （报 `Permission denied`，而且完全不提示原因）。
 *
 * 所以 proot / loader 是通过 `jniLibs` 当"原生库"带进来的
 * （见 tools/stage_termux_native.py），运行时从
 * `applicationInfo.nativeLibraryDir` 取路径。
 */
class LinuxRuntime(private val ctx: Context) {

    companion object {
        const val CHANNEL = "dsh/linux"

        /** 环境根目录（rootfs、proot 的临时目录都在它下面）。 */
        private fun linuxDir(ctx: Context) = File(ctx.filesDir, "linux")

        /** rootfs 解压到哪。放私有目录，卸载时一起清掉。 */
        private fun rootfsDir(ctx: Context) = File(linuxDir(ctx), "rootfs")

        /** 安装标记。有它就跳过解压 —— 解压 4MB 的 tar.gz 要几秒。 */
        private fun marker(ctx: Context) = File(linuxDir(ctx), ".installed")

        /**
         * **proot 自己的临时目录。**
         *
         * 这个目录不是可有可无的：proot 启动时要在里面建一个 "glue rootfs"
         * （承载绑定挂载的挂载点），建不出来就**当场退出**。
         *
         * 而这份 proot 是 **Termux 编译的**，默认临时目录被编死成
         * `/data/data/com.termux/files/usr/tmp/` —— 那个路径只有 Termux
         * 应用有，我们这个包名下根本不存在。不显式指定的表现是：
         *
         *     proot warning: can't canonicalize /data/data/com.termux/files/usr/tmp/
         *     proot error:   can't create temporary directory: No such file or directory
         *     proot info:    Please set PROOT_TMP_DIR env. variable to an alternate location
         *     proot error:   can't create glue rootfs
         *
         * 也就是**一条命令都跑不起来**。而它跟我们自己的目录、权限、
         * 绑定都没关系 —— 纯粹是"那个临时目录不存在"。书上说要放
         * "可写的目录"，那就用应用私有目录里自己的一个。
         */
        private fun tmpDir(ctx: Context) = File(linuxDir(ctx), "tmp")

        /**
         * 把每条 `-b host:guest` 的 **guest 侧挂载点**在 rootfs 里建出来。
         *
         * 为什么必须建：proot 启动时会把 guest 路径放进 rootfs 里做一次
         * canonicalize，**中途任何一级目录缺失就丢弃整条绑定**，
         * 而且在 stderr 里只留一行 warning：
         *
         *     proot warning: sanitizing the guest path (binding)
         *         "/data/user/0/com.dsh.dsh_agent/files": No such file or directory
         *
         * 一个空白的 Alpine 里当然没有 `/sdcard`、`/storage/emulated/0`，
         * 更没有应用自己的 `/data/user/0/<包名>/files` —— 所以这些绑定
         * 原本是**被静默丢掉的**："手机上已经有 /sdcard"、"/shared 是交换目录"
         * 这两句话当时其实是假的，只是没人看得出来（Linux 里看到的
         * 是个空目录，而空目录最容易让人以为是"文件没生成"）。
         *
         * 没有中间目录、只有最后一级不存在的情况 proot 是允许的，
         * 但这里不区分，**全都建出来** —— 少一条规则就少一个坑。
         */
        private fun ensureGuestMounts(
            ctx: Context,
            rootfs: File,
            extraBinds: List<String> = emptyList(),
        ) {
            val guests = mutableListOf(
                "/sdcard",
                "/storage",
                "/storage/emulated/0",
                "/dev/shm",
                "/shared",
            )
            // 应用自己的目录是按**绝对路径原样**绑进去的
            // （这样 rootfs 内外同一个路径指向同一个文件），
            // 所以挂载点也要照原样建，不能换个短名字。
            for (d in listOf(ctx.filesDir, ctx.cacheDir, sharedDir(ctx))) {
                guests += d.absolutePath
            }
            // 调用方会额外传入自己的目录（例如 app_flutter 下的工作目录）。
            // proot 只有在 guest 挂载点存在时才会保留这条绑定，
            // 所以这里也要把它的父目录建出来。
            for (p in extraBinds) {
                if (p.isNotBlank() && p !in guests) guests += p
            }
            for (g in guests) {
                try {
                    File(rootfs, g.removePrefix("/")).mkdirs()
                } catch (_: Throwable) {
                    // 建不出来就跳过：比让整次执行失败好
                }
            }
        }

        /**
         * proot 需要的绑定挂载。
         *
         * 少了任何一个都会出现很怪的现象，所以逐个说明：
         *  · `/dev`  —— 没有它 `/dev/null` 不存在，很多程序直接就崩；
         *  · `/proc` —— `ps`、`top`、以及一堆读取 /proc/self 的程序；
         *  · `/sys`  —— 读硬件信息；
         *  · `/dev/shm` —— 共享内存。**Android 上 /dev/shm 不可用**，
         *    所以要单独绑到 rootfs 里的一个普通目录，并靠
         *    libandroid-shmem 垫片顶上（这也是那个 .so 存在的原因）；
         *  · `/sdcard` 等 —— **设备存储**。没有它们，Linux 里完全看不到
         *    用户的文件，`ls /sdcard` 是空的。而"用 Linux 工具处理
         *    手机上的文件"正是这个环境最主要的用途之一。
         *
         * ⚠️ 绑定挂载**只影响路径可见性**，不绕过 Android 的存储权限。
         * 应用本身读不到的东西，绑进去同样读不到 —— 那是系统层面的限制，
         * 不是绑得不够多。所以这里不追求"绑得越多越好"。
         */
        private fun binds(
            ctx: Context,
            rootfs: File,
            extraBinds: List<String>,
        ): List<String> {
            val out = mutableListOf(
                "/dev:/dev",
                "/proc:/proc",
                "/sys:/sys",
                "/dev/urandom:/dev/urandom",
                "${rootfs.absolutePath}/tmp/shm:/dev/shm",
            )

            // ---- 设备存储 ----
            //
            // 只绑**真实存在**的路径：proot 遇到绑不上的源会直接报错退出，
            // 而不是"那个目录空着"。有些设备没有 /mnt/media_rw，
            // 硬写进去会让整个环境起不来。
            for (p in listOf(
                "/sdcard",
                "/storage/emulated/0",
                "/storage",
            )) {
                if (File(p).exists()) out += "$p:$p"
            }

            // ---- 应用自己的目录 ----
            //
            // 工作目录（模型生成的文件都在这）和缓存目录。
            // 绑进 Linux 之后，`file_op` 生成的脚本 Linux 能直接跑，
            // Linux 生成的文件 Android 侧也能直接读。
            for (p in listOf(ctx.filesDir.absolutePath, ctx.cacheDir.absolutePath)) {
                if (File(p).exists()) out += "$p:$p"
            }

            // ---- 共享目录 ----
            //
            // 额外多绑一个短名字 `/shared`：rootfs 里的长绝对路径又难记
            // 又容易写错，而模型要能在提示词里被明确告知一个**简单的**
            // 落脚点（见系统提示词里关于 /shared 的说明）。
            val sh = sharedDir(ctx)
            sh.mkdirs()
            out += "${sh.absolutePath}:/shared"

            // ---- 调用方指定的额外目录 ----
            //
            // 调用方的工作目录可能在 app_flutter 下，不在 filesDir/cacheDir
            // 里；不绑进来的话 `python3 scripts/x.py` 在 Alpine 里找不到
            // 文件。只绑调用方明确要的那一个目录，不把整个应用数据目录
            // 暴露给 shell。
            for (p in extraBinds) {
                if (p.isBlank()) continue
                if (!File(p).exists()) continue
                val binding = "$p:$p"
                if (binding !in out) out += binding
            }

            return out
        }

        /**
         * **共享目录**：Linux 环境和外部应用之间的交换区。
         *
         * ## 为什么需要它
         *
         * rootfs 里的文件（比如 `/root/report.pdf`）躺在
         * `filesDir/linux/rootfs/root/` 下 —— 用户从文件管理器
         * 根本找不到，别的应用也打不开（应用私有目录）。
         * 也就是说"在 Linux 里生成了一个文件"之后**拿不出来**。
         *
         * 有了这个目录：
         *  · Linux 里直接写 `/shared/report.pdf`（或 `cp` 过去）；
         *  · Android 侧它就是 `filesDir/shared/`，
         *    而 FileProvider 已声明 `files-path`，
         *    所以能一键打开、也能发给别的应用。
         */
        private fun sharedDir(ctx: Context) = File(ctx.filesDir, "shared")
    }

    // ------------------------------------------------------------ 安装

    /** 环境装好了没有。 */
    fun isInstalled(): Boolean =
        marker(ctx).exists() && rootfsDir(ctx).isDirectory

    /**
     * 首次安装：把 rootfs 解到私有目录，并把 apk.static 放进去。
     *
     * 为什么用纯 Java 解 gzip+tar 而不是调 `tar`：Android 上没有
     * 保证存在的 `tar` 命令（Toybox 的 tar 在旧版本上不一定有），
     * 而"解压自己带的包"这件事不该依赖系统工具。
     */
    fun install(): Map<String, Any?> {
        val rootfs = rootfsDir(ctx)
        return try {
            if (isInstalled()) {
                // 已经装过的（老版本装的）在这里补一次挂载点和临时目录 ——
                // 否则"重装一遍"修不好它，而那正是用户会做的第一件事。
                ensureLayout()
                return mapOf("ok" to true, "alreadyInstalled" to true)
            }

            rootfs.deleteRecursively()
            rootfs.mkdirs()
            File(rootfs, "tmp/shm").mkdirs()
            File(rootfs, "root").mkdirs()
            // 绑定挂载的挂载点（见 ensureGuestMounts 的说明）
            ensureGuestMounts(ctx, rootfs)
            tmpDir(ctx).mkdirs()

            // ---- 解 rootfs ----
            //
            // Alpine 的 minirootfs 里带了 `dev/`、`proc/` 这些空目录，
            // 但 `tmp/shm` 是我们自己加的（见 binds 的说明）。
            ctx.assets.open("flutter_assets/assets/termux/" +
                    "alpine-minirootfs-3.24.1-aarch64.tar.gz").use { raw ->
                java.util.zip.GZIPInputStream(raw).use { gz ->
                    extractTar(gz, rootfs)
                }
            }

            // ---- apk.static 放进 rootfs ----
            //
            // 放 `/usr/bin/apk`：Alpine 里 `apk` 本来就在这个位置，
            // 这样用户 `apk add curl` 用的就是我们带进去的那个静态版，
            // 不需要先自己安装 apk-tools。
            val apk = File(rootfs, "usr/bin/apk")
            apk.parentFile?.mkdirs()
            ctx.assets.open("flutter_assets/assets/termux/apk.static").use { ins ->
                FileOutputStream(apk).use { out -> ins.copyTo(out) }
            }
            Os.chmod(apk.absolutePath, 0b111101101) // 0755

            // ---- 补 resolv.conf ----
            //
            // rootfs 里没有它，而 `apk add` 要解析域名。
            // 不写这个的话装包会报 "temporary error"，很难联想到是 DNS。
            File(rootfs, "etc/resolv.conf").writeText(
                "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" +
                        "nameserver 223.5.5.5\n"
            )

            marker(ctx).parentFile?.mkdirs()
            marker(ctx).writeText(System.currentTimeMillis().toString())
            mapOf("ok" to true, "alreadyInstalled" to false)
        } catch (e: Throwable) {
            // 失败就把标记清掉，下次还能重试（留着一个坏 rootfs 更糟）
            marker(ctx).delete()
            mapOf("ok" to false, "error" to "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * 每次执行前把环境"补齐"两样东西：proot 的临时目录 + 各条绑定的挂载点。
     *
     * 为什么不放在 [install] 里就完事：`.installed` 标记还在的老用户
     * 不会再走 install —— 而他们恰恰是最需要补这一次的人。
     * 这里只做几次 mkdir，代价可以忽略。
     */
    private fun ensureLayout(extraBinds: List<String> = emptyList()) {
        try {
            tmpDir(ctx).mkdirs()
        } catch (_: Throwable) {
        }
        ensureGuestMounts(ctx, rootfsDir(ctx), extraBinds)
    }

    /**
     * 极简 tar 解包（只处理普通文件 + 目录 + 符号链接）。
     *
     * Alpine 的 minirootfs 是标准的 ustar，用不到 GNU 的那些扩展，
     * 所以不需要完整实现 —— 而且**必须**是这里自己解，
     * 见 [install] 的说明。
     */
    private fun extractTar(input: InputStream, dest: File) {
        val header = ByteArray(512)
        var longName: String? = null

        while (true) {
            if (!readFully(input, header, 512)) break
            // 全零块 = 归档结束
            if (header.all { it == 0.toByte() }) break

            var name = readString(header, 0, 100)
            val size = readOctal(header, 124, 12)
            val typeFlag = header[156].toInt().toChar()
            val linkName = readString(header, 157, 100)
            val prefix = readString(header, 345, 155)
            if (prefix.isNotEmpty()) name = "$prefix/$name"

            // GNU long name：上一条记录了真实名字
            if (typeFlag == 'L') {
                // 长名字的 size 理论上可能很大，取个上限防止坏包撑爆内存
                val n = size.coerceAtMost(8192L).toInt()
                val buf = ByteArray(n)
                readFully(input, buf, n)
                longName = String(buf).trimEnd('\u0000')
                skipPadding(input, size)
                continue
            }
            val realName = longName ?: name
            longName = null

            val target = File(dest, realName)
            // 防目录穿越：tar 里可能有 ../ 这种条目
            if (!target.canonicalPath.startsWith(dest.canonicalPath)) {
                skipData(input, size)
                continue
            }

            when (typeFlag) {
                '5' -> target.mkdirs()
                '2' -> {
                    // 符号链接：先删掉旧的，再建。Alpine 里大量用到
                    // （/usr/bin 下一堆 busybox 的软链），漏掉的话
                    // 解出来的系统连 `sh` 都没有。
                    target.parentFile?.mkdirs()
                    target.delete()
                    try {
                        Os.symlink(linkName, target.absolutePath)
                    } catch (_: Throwable) {
                        // 建不了就跳过 —— 比整个安装失败好
                    }
                }
                else -> {
                    target.parentFile?.mkdirs()
                    FileOutputStream(target).use { out ->
                        val buf = ByteArray(64 * 1024)
                        var left = size
                        while (left > 0) {
                            val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                            if (n < 0) break
                            out.write(buf, 0, n)
                            left -= n
                        }
                    }
                    // 权限位：可执行文件必须保住，否则解出来全是 644，
                    // 整个 rootfs 里连 `sh` 都跑不起来。
                    val mode = readOctal(header, 100, 8)
                    try {
                        Os.chmod(target.absolutePath, (mode and 0x1FF).toInt())
                    } catch (_: Throwable) {
                    }
                }
            }
            skipPadding(input, size)
        }
    }

    private fun skipData(input: InputStream, size: Long) {
        var left = size
        val buf = ByteArray(8192)
        while (left > 0) {
            val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (n < 0) break
            left -= n
        }
    }

    /** tar 的数据段按 512 对齐，size 后面的填充也要读掉。 */
    private fun skipPadding(input: InputStream, size: Long) {
        val pad = ((512 - (size % 512)) % 512).toInt()
        if (pad > 0) readFully(input, ByteArray(pad), pad)
    }

    private fun readFully(input: InputStream, buf: ByteArray, len: Int): Boolean {
        var off = 0
        while (off < len) {
            val n = input.read(buf, off, len - off)
            if (n < 0) return off == 0
            off += n
        }
        return true
    }

    private fun readString(b: ByteArray, off: Int, len: Int): String {
        var end = off
        while (end < off + len && b[end] != 0.toByte()) end++
        return String(b, off, end - off, Charsets.UTF_8)
    }

    private fun readOctal(b: ByteArray, off: Int, len: Int): Long {
        val s = readString(b, off, len).trim().trimEnd(' ')
        if (s.isEmpty()) return 0
        return try {
            s.toLong(8)
        } catch (_: NumberFormatException) {
            0
        }
    }

    // ------------------------------------------------------------ 执行

    /** proot 可执行文件的绝对路径（在原生库目录里）。 */
    private fun prootPath(): String =
        File(ctx.applicationInfo.nativeLibraryDir, "libproot.so").absolutePath

    /**
     * 交给 proot 的环境变量（宿主侧直接设，guest 侧经 `env -i` 再给一遍）。
     *
     * 五个都有明确用途，不是照抄：
     *  · `PROOT_LOADER` / `PROOT_LOADER_32` —— proot 要另起一个 loader
     *    进程做 ptrace 跟踪，而它默认按 **Termux 的目录布局**去猜 loader
     *    在哪 —— 在我们的 APK 里那个位置是空的。所以必须显式告诉它，
     *    少了它 proot 直接报错退出；
     *  · `PROOT_TMP_DIR` —— 见 [tmpDir]。**这个是"能不能用"的分界线**：
     *    不设它，proot 连 glue rootfs 都建不出来，一条命令都跑不起来；
     *  · `PROOT_NO_SECCOMP` —— 关掉 proot 的 seccomp 加速。ptrace 那条路
     *    慢一点，但 seccomp 在部分 Android 内核上会把 apk 内部 libfetch 的
     *    `connect()` 判成 EACCES，表现是**所有软件源都 Permission denied**
     *    —— 而包管理（`apk add`）正是这套环境最主要的用途之一；
     *  · `LD_LIBRARY_PATH` —— proot 的 `DT_NEEDED` 里写的是
     *    `libtalloc.so` / `libandroid-shmem.so`（前者是构建期改过的名字，
     *    见 `tools/patch_proot_needed.py`），它们就躺在原生库目录里，
     *    这里指过去让链接器找得到。
     */
    private fun prootEnv(libDir: String, tmp: String): List<String> = listOf(
        "LD_LIBRARY_PATH=$libDir",
        "PROOT_LOADER=$libDir/libproot_loader.so",
        "PROOT_LOADER_32=$libDir/libproot_loader32.so",
        "PROOT_TMP_DIR=$tmp",
        "PROOT_NO_SECCOMP=1",
    )

    /**
     * 每个流**最多收多少字节**。
     *
     * ## 为什么必须有这个上限（用户报的"跑着跑着突然闪退"）
     *
     * 输出是一边读一边往 `StringBuilder` 里堆的，而命令是模型给的 ——
     * 一条 `find /`、`cat` 一个大文件、或者某个程序刷屏打日志，就能吐出
     * 几百 MB；这些都被原样堆进内存，进程直接被撑爆。Android 上那是
     * **原地闪退**，没有异常可以捕获，日志里也看不出是我们的错。
     *
     * 而这么多输出对谁都没用：模型看的是截断后的前几千字，
     * 用户真正需要的是"把完整输出重定向到文件再看"。
     *
     * 1 MB 足够装下任何给人看的输出；超了就在末尾写明已截断 + 给出去处。
     */
    private val MAX_STREAM_BYTES = 1 shl 20

    /**
     * 读干净一个流，但**只累积前 [MAX_STREAM_BYTES] 字节**。
     *
     * 注意超限之后仍然继续读（只是不累积）—— 停了的话子进程会阻塞在写管道上，
     * 表现成"命令卡住不结束"，那和闪退一样糟。
     */
    private fun readCapped(input: InputStream, into: StringBuilder) {
        val buf = ByteArray(8192)
        var total = 0
        var truncated = false
        try {
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                if (total >= MAX_STREAM_BYTES) {
                    truncated = true
                    continue
                }
                val room = MAX_STREAM_BYTES - total
                val take = if (n <= room) n else room
                into.append(String(buf, 0, take, Charsets.UTF_8))
                total += take
                if (total >= MAX_STREAM_BYTES) truncated = true
            }
        } catch (_: Throwable) {
            // 进程被杀时读会抛 —— 已经读到的东西照样返回
        }
        if (truncated) {
            into.append(
                "\n[输出超过 1 MB 已截断。要看完整输出，把命令重定向到文件再读，"
                    + "例如 > /shared/out.log 2>&1，然后用 file_op 读它]"
            )
        }
    }

    /**
     * 在 Linux 环境里跑一条命令。
     *
     * [stdin] 非空时作为标准输入喂进去 —— 这是**比 Termux 广播强的地方**：
     * `apk add` 的 y/n 确认、`python` 的 REPL 都能用（配合 `-i`）。
     */
    fun exec(
        command: String,
        workdir: String?,
        timeoutMs: Long,
        stdin: String?,
        keepAlive: Boolean = false,
        extraBinds: List<String> = emptyList(),
    ): Map<String, Any?> {
        if (!isInstalled()) {
            return mapOf(
                "ok" to false,
                "error" to "Linux 环境还没安装。先调用 install。",
                "errorKind" to "NOT_INSTALLED",
            )
        }

        // 补齐临时目录和挂载点（老安装也会被这一次补上，见 ensureLayout）
        ensureLayout(extraBinds)

        // proot 只给 arm64-v8a 打包了（见 build.gradle.kts 的 abiFilters）。
        // 别的架构上原生库目录里没有它，起手就报一句人话，
        // 而不是让用户看到一个和"文件不存在"无关的玄学错误。
        val proot = prootPath()
        if (!File(proot).exists()) {
            return mapOf(
                "ok" to false,
                "error" to "这个设备的 CPU 架构是 " +
                        "${android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: "未知"}，" +
                        "而 APK 里只打包了 arm64-v8a 的 proot —— 内置 Linux 在这台" +
                        "设备上跑不起来。这是打包取舍，不是环境装坏了。",
                "errorKind" to "NO_PROOT",
            )
        }

        val rootfs = rootfsDir(ctx)
        val libDir = ctx.applicationInfo.nativeLibraryDir
        val tmp = tmpDir(ctx)

        val args = mutableListOf<String>()

        args += proot
        // --kill-on-exit：proot 退出时把被跟踪的子进程一起带走。
        // 少了它，超时后我们 destroyForcibly() 只杀掉 proot，
        // 里面正在跑的编译 / 下载会变成孤儿继续跑 —— 用户看到的是
        // "已经失败了，但手机还在跑东西、还在耗电"。
        //
        // 但**后台/守护进程**正好相反：nohup、setsid、显式 `&` 启动的
        // 进程本来就要在本次 shell 结束后继续活着。调用方传 keepAlive
        // 时不能加这个参数，否则刚启动的守护进程会被 proot 当场收走。
        if (!keepAlive) {
            args += listOf("--kill-on-exit")
        }
        args += listOf("-r", rootfs.absolutePath)
        args += listOf("-0")                      // 假装是 root（rootfs 内）
        args += listOf("-w", workdir ?: "/root")
        for (b in binds(ctx, rootfs, extraBinds)) {
            args += listOf("-b", b)
        }
        // `env -i` 干净起步，然后我们逐个给需要的变量 ——
        // 不继承应用自己的环境（那里面有一堆 Android 的东西，
        // 进了 rootfs 只会干扰）。
        args += listOf("/usr/bin/env", "-i")
        args += prootEnv(libDir, tmp.absolutePath)
        args += listOf(
            "HOME=/root",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            // PATH 要给全：Alpine 的 apk 在 /usr/bin，busybox 在 /bin；
            // TMPDIR 指到 rootfs 内的 /tmp（已经挂进来了）。
            "TERM=xterm-256color",
            "LANG=C.UTF-8",
            "TMPDIR=/tmp",
        )
        args += listOf("/bin/sh", "-c", command)

        return try {
            val pb = ProcessBuilder(args)
            pb.directory(File(ctx.filesDir, "linux"))
            pb.redirectErrorStream(false)

            // proot **自己**（在进 rootfs 之前）也需要 loader 的位置，
            // 因为那是它在启动阶段就要读的，`env -i` 还没执行到。
            val env = pb.environment()
            env["PROOT_LOADER"] = "$libDir/libproot_loader.so"
            env["PROOT_LOADER_32"] = "$libDir/libproot_loader32.so"
            env["LD_LIBRARY_PATH"] = libDir
            // proot 的临时目录和 seccomp 开关是**宿主侧**就要生效的，
            // 见 prootEnv 的说明。
            env["PROOT_TMP_DIR"] = tmp.absolutePath
            env["PROOT_NO_SECCOMP"] = "1"
            // 不继承宿主的环境：Android 那些变量进了 rootfs 只会干扰
            env.remove("ANDROID_ROOT")
            env.remove("ANDROID_DATA")

            val p = pb.start()

            // 喂 stdin（如果给了）
            if (!stdin.isNullOrEmpty()) {
                try {
                    p.outputStream.use { it.write(stdin.toByteArray()) }
                } catch (_: Throwable) {
                }
            } else {
                try {
                    p.outputStream.close()
                } catch (_: Throwable) {
                }
            }

            // 读输出要放在**独立线程**：管道缓冲区满了之后
            // 子进程会阻塞在写上面，而我们如果先 waitFor 就死锁了。
            val outBuf = StringBuilder()
            val errBuf = StringBuilder()
            val tOut = Thread { readCapped(p.inputStream, outBuf) }
            val tErr = Thread { readCapped(p.errorStream, errBuf) }
            tOut.start()
            tErr.start()

            val finished = p.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                p.destroyForcibly()
                tOut.join(1000)
                tErr.join(1000)
                return mapOf(
                    "ok" to false,
                    "error" to "执行超时（${timeoutMs / 1000} 秒）",
                    "errorKind" to "TIMEOUT",
                    "stdout" to outBuf.toString(),
                    "stderr" to errBuf.toString(),
                    "exitCode" to -1,
                )
            }
            tOut.join(2000)
            tErr.join(2000)

            mapOf(
                "ok" to true,
                "stdout" to outBuf.toString(),
                "stderr" to errBuf.toString(),
                "exitCode" to p.exitValue(),
            )
        } catch (e: Throwable) {
            mapOf(
                "ok" to false,
                "error" to "${e.javaClass.simpleName}: ${e.message}",
                "errorKind" to "EXCEPTION",
            )
        }
    }

    /** 环境信息，给设置页显示用。 */
    fun info(): Map<String, Any?> {
        val rootfs = rootfsDir(ctx)
        var size = 0L
        if (rootfs.isDirectory) {
            rootfs.walkTopDown().forEach { if (it.isFile) size += it.length() }
        }
        return mapOf(
            "installed" to isInstalled(),
            "rootfs" to rootfs.absolutePath,
            "rootfsBytes" to size,
            "proot" to prootPath(),
            "prootExists" to File(prootPath()).exists(),
            "abi" to android.os.Build.SUPPORTED_ABIS.firstOrNull(),
        )
    }

    // ------------------------------------------------------------ 通道

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isInstalled" -> result.success(isInstalled())
            "info" -> result.success(info())

            // 安装会解 4MB 的包，**不能在主线程**做
            "install" -> Thread {
                val r = install()
                android.os.Handler(android.os.Looper.getMainLooper())
                    .post { result.success(r) }
            }.start()

            "exec" -> Thread {
                val cmd = call.argument<String>("command") ?: ""
                val wd = call.argument<String>("workdir")
                val timeout = call.argument<Number>("timeoutMs")?.toLong() ?: 60_000L
                val stdin = call.argument<String>("stdin")
                val keepAlive = call.argument<Boolean>("keepAlive") ?: false
                val extraBinds = call.argument<List<String>>("extraBinds")
                    ?: emptyList()
                val r = if (cmd.isBlank()) {
                    mapOf("ok" to false, "error" to "命令为空")
                } else {
                    exec(cmd, wd, timeout, stdin, keepAlive, extraBinds)
                }
                android.os.Handler(android.os.Looper.getMainLooper())
                    .post { result.success(r) }
            }.start()

            else -> result.notImplemented()
        }
    }
}
