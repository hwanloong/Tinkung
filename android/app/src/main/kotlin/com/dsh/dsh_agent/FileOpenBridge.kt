package com.dsh.dsh_agent

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 把**应用私有目录里的文件**交给外部应用打开。
 *
 * ## 为什么必须走 FileProvider
 *
 * 生成出来的图片、视频都落在 `getFilesDir()`（应用私有目录），
 * 而别的应用**读不到**那里。Android 7（API 24）起还额外**禁止**
 * 把 `file://` 形式的 URI 交给外部应用 —— 会直接抛
 * `FileUriExposedException`。
 *
 * 所以正确的做法是：
 *   1. 用 `FileProvider.getUriForFile` 把文件换成一个 `content://` URI；
 *   2. 用 `FLAG_GRANT_READ_URI_PERMISSION` 临时授权给目标应用；
 *   3. 发 `ACTION_VIEW` 意图。
 *
 * 少了任何一步都"打不开"，而且失败方式很安静（异常或没有匹配的
 * Activity），用户只看到"点了没反应"。这就是这个类存在的全部理由。
 */
class FileOpenBridge(private val activity: Activity) {

    companion object {
        const val CHANNEL = "dsh/fileopen"

        /** 定位权限请求码。取个不冲突的值即可。 */
        const val REQ_LOCATION = 4711

        /** 旧系统（Android 10 及以下）的写存储权限请求码。 */
        const val REQ_STORAGE = 4712

        /**
         * 必须和 AndroidManifest 里 provider 的 authorities **完全一致**。
         * 拼错的话 `getUriForFile` 会抛 IllegalArgumentException：
         * "Couldn't find meta-data for provider" —— 而那个报错完全
         * 不会提示你 authorities 拼错了。
         */
        fun authority(ctx: Context): String = "${ctx.packageName}.fileprovider"
    }

    private val main = Handler(Looper.getMainLooper())

    /**
     * Android 11+ 的「所有文件访问」是否已授予。
     *
     * 没有它，`File.write` 到 `/sdcard/Download/...` 会直接抛
     * `OS Error: Operation not permitted, errno = 1` —— 用户看到的
     * "工作空间改目录失败" 就是这条。
     */
    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                intent.data = Uri.parse("package:${activity.packageName}")
                activity.startActivity(intent)
            } catch (_: Exception) {
                try {
                    activity.startActivity(
                        Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    )
                } catch (_: Exception) {
                    // 极少数 ROM 两个入口都没有：用户可手动去系统设置授权。
                }
            }
        } else {
            activity.requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQ_STORAGE
            )
        }
    }

    /** 待回复的权限请求（一次只能有一个，够用） */
    private var pendingPermission: MethodChannel.Result? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> {
                val path = call.argument<String>("path") ?: ""
                val mime = call.argument<String>("mime")
                result.success(open(path, mime))
            }

            // 把界面里显示的路径解析成设备上真实存在的路径。
            //
            // 最典型的是 Termux/Linux：模型写 `/shared/报告.pdf`，真实文件在
            // `filesDir/shared/报告.pdf`。不解析就会出现“卡片上明明有文件，
            // 一点却提示找不到”。
            "resolvePath" -> {
                val path = call.argument<String>("path") ?: ""
                val deep = call.argument<Boolean>("search") == true
                result.success(resolvePath(path, deep))
            }

            "mimeOf" -> {
                result.success(mimeOf(call.argument<String>("path") ?: ""))
            }

            // 存到系统"下载"/"图片"里 —— 从应用私有目录到用户能长期找到的地方。
            "save" -> {
                val path = call.argument<String>("path") ?: ""
                val name = call.argument<String>("name")
                Thread {
                    val r = save(path, name)
                    main.post { result.success(r) }
                }.start()
            }

            // ---- 所有文件访问（工作空间切公共目录用） ----
            "hasAllFilesAccess" -> result.success(hasAllFilesAccess())

            "requestAllFilesAccess" -> {
                requestAllFilesAccess()
                result.success(true)
            }

            // ---- 定位 ----
            "hasLocationPermission" -> result.success(hasLocation())

            "requestLocationPermission" -> requestLocation(result)

            "location" -> {
                // 取位置会碰系统服务，放到后台线程；结果回主线程回复。
                Thread {
                    val r = location()
                    main.post { result.success(r) }
                }.start()
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------- 打开文件

    /**
     * 把应用私有目录里的文件**存到用户能找到的地方**。
     *
     * 图片进「图片/PrivTasker」，其它进「下载」。返回 null = 成功，
     * 否则是给用户看的错误说明。
     *
     * ## 为什么不能直接 `File(...).copyTo()`
     *
     * 私有目录（`getFilesDir()`）到公共目录在 Android 11+ 是**写不进去**的
     * （分区存储），而且 Android 10 起写公共目录还要走 **MediaStore** 登记，
     * 否则文件管理器里看不到这条记录。
     * 所以：Q 以上走 `MediaStore` 插入 + 流式写入 + 把 `IS_PENDING` 清掉；
     * 再往下才退回"直接写到公共 Download 目录"。
     */
    private fun save(path: String, nameArg: String?): String? {
        if (path.isBlank()) return "路径为空"
        val src = File(path)
        if (!src.exists()) return "文件不存在：$path"
        if (!canReadIt(src)) return "读不到这个文件（不在应用可访问的范围内）"

        val name = nameArg?.takeIf { it.isNotBlank() } ?: src.name
        val mime = mimeOf(name)
        val isImage = mime.startsWith("image/")
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val collection = if (isImage) {
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                } else {
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI
                }
                val relative = if (isImage) {
                    "${Environment.DIRECTORY_PICTURES}/PrivTasker"
                } else {
                    Environment.DIRECTORY_DOWNLOADS
                }
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val resolver = activity.contentResolver
                val uri = resolver.insert(collection, values)
                    ?: return "系统没有给出可写的位置"
                resolver.openOutputStream(uri)?.use { out ->
                    src.inputStream().use { it.copyTo(out) }
                } ?: return "打不开目标位置"
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                null
            } else {
                @Suppress("DEPRECATION")
                val dir = Environment.getExternalStoragePublicDirectory(
                    if (isImage) Environment.DIRECTORY_PICTURES
                    else Environment.DIRECTORY_DOWNLOADS
                )
                if (!dir.exists() && !dir.mkdirs()) return "建不了目标目录"
                src.copyTo(File(dir, name), overwrite = true)
                null
            }
        } catch (e: Exception) {
            "保存失败：${e.message ?: e.javaClass.simpleName}"
        }
    }

    /**
     * 把界面路径映射到真实文件。
     *
     * 顺序：
     *  1. 原路径就是真实路径；
     *  2. Linux 侧的 `/shared`、`/root`、`/tmp`、`/home` 映射回应用私有目录；
     *  3. `/sdcard` 与 `/storage/self/primary` 指向真实主存储；
     *  4. [deep] 为 true 时按文件名在常见目录里做一次兜底搜索（只用于
     *     “用户点了文件”这一下，不用于后台频繁调用）。
     */
    private fun resolvePath(path: String, deep: Boolean): String? {
        if (path.isBlank()) return null
        if (path.startsWith("content://")) return path

        if (path.startsWith("file://")) {
            try {
                Uri.parse(path).path?.let { p ->
                    if (File(p).isFile) return File(p).absolutePath
                }
            } catch (_: Exception) {
            }
        }

        val direct = File(path)
        if (direct.isFile) return direct.absolutePath

        val mappings = listOf(
            "/shared/" to File(activity.filesDir, "shared"),
            "/root/" to File(activity.filesDir, "linux/rootfs/root"),
            "/home/" to File(activity.filesDir, "linux/rootfs/home"),
            "/tmp/" to File(activity.filesDir, "linux/rootfs/tmp"),
        )
        for ((prefix, root) in mappings) {
            if (!path.startsWith(prefix)) continue
            val f = File(root, path.removePrefix(prefix))
            if (f.isFile) return f.absolutePath
        }

        val rest = when {
            path.startsWith("/sdcard/") -> path.removePrefix("/sdcard/")
            path.startsWith("/storage/self/primary/") ->
                path.removePrefix("/storage/self/primary/")
            else -> null
        }
        if (rest != null) {
            val f = File(Environment.getExternalStorageDirectory(), rest)
            if (f.isFile) return f.absolutePath
        }

        if (deep) {
            val name = File(path).name
            if (name.isNotBlank()) return findByName(name)?.absolutePath
        }
        return null
    }

    /**
     * 按文件名找一次。只搜有限深度和数量，避免用户点一下文件就扫全盘。
     */
    private fun findByName(name: String): File? {
        val roots = mutableListOf<File>()
        roots.add(File(activity.filesDir, "shared"))
        roots.add(activity.filesDir)
        roots.add(File(activity.filesDir, "linux/rootfs/root"))
        activity.getExternalFilesDir(null)?.let { roots.add(it) }
        roots.add(
            Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
        )
        roots.add(
            Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOCUMENTS
            )
        )

        var best: File? = null
        for (root in roots) {
            if (!root.isDirectory) continue
            try {
                for (f in root.walkTopDown().maxDepth(4).take(8000)) {
                    if (!f.isFile || f.name != name) continue
                    val current = best
                    if (current == null || f.lastModified() > current.lastModified()) {
                        best = f
                    }
                }
            } catch (_: Exception) {
                // 某个目录读不了就跳过，换下一个。
            }
        }
        return best
    }

    /**
     * 打开一个文件。返回 `null` 表示成功，否则是**给用户看的**错误说明。
     *
     * 为什么返回错误文本而不是布尔：这类失败的原因差别很大
     * （文件不存在 / 没有应用能打开这种类型 / 权限没配好），
     * 用户拿到一句"打开失败"完全无从下手。
     *
     * ## 三种输入要分别处理
     *
     * 1. **`content://` URI**（系统文件选择器返回的就是这个）——
     *    它本来就是可分享的，直接转发即可。
     *    以前这里当成路径去 `File(path)`，必然"文件不存在"。
     * 2. **私有目录里的路径** —— FileProvider 直接能服务，最好走这条路。
     * 3. **共享存储里的路径**（`/sdcard/Download/x.pdf`）——
     *    Android 11+ 的分区存储下应用**读不到**普通文件
     *    （`READ_EXTERNAL_STORAGE` 自 API 30 起对非媒体文件无效）。
     *    这时**复制进我们的缓存目录再分享** —— 复制这一下同时解决了
     *    "读不到"和"分享不出去"两个问题，而且不需要任何额外权限。
     */
    private fun open(path: String, mimeArg: String?): String? {
        if (path.isBlank()) return "路径为空"

        // ---- 情况 1：已经是 content:// ----
        //
        // 系统文件选择器（SAF）给的就是这种。它自带授权，
        // 我们只要原样转发 + 带上读权限标志。
        if (path.startsWith("content://")) {
            return viewUri(Uri.parse(path), mimeArg ?: "*/*")
        }

        val f = File(path)
        if (!f.exists()) return "文件不存在：$path"

        // ---- 情况 3：存在但读不到 → 复制进沙箱 ----
        //
        // `canRead()` 为 false 时，说明它在共享存储里而分区存储挡住了我们。
        // 这是最容易被误判成"文件坏了"的情况：文件明明在，
        // 一路用的都是绝对路径，但读的时候 EACCES。
        val usable: File = if (canReadIt(f)) {
            f
        } else {
            val copied = copyIntoSandbox(f)
                ?: return "读不到这个文件（它不在应用可访问的范围内）。\n" +
                        "请把它复制到应用里再试，或者先用文件工具处理它。"
            copied
        }

        val mime = mimeArg?.takeIf { it.isNotBlank() } ?: mimeOf(usable.name)

        val uri: Uri = try {
            FileProvider.getUriForFile(activity, authority(activity), usable)
        } catch (e: Exception) {
            // 最常见的原因是 authorities 拼错，或者文件不在
            // file_paths.xml 声明的目录里。
            return "无法生成可分享的地址（${e.javaClass.simpleName}）：${e.message}"
        }

        return viewUri(uri, mime)
    }

    /** 发 ACTION_VIEW。抽出来是因为 content:// 和 file 两条路都要用。 */
    private fun viewUri(uri: Uri, mime: String): String? {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            // 临时读权限。不加这个，接收方打开时会 SecurityException。
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        return try {
            activity.startActivity(intent)
            null
        } catch (e: android.content.ActivityNotFoundException) {
            // 没有应用能打开这种类型 —— 这在国内 ROM 上很常见
            // （比如没装任何视频播放器）。给一条能指导行动的提示。
            "没有应用能打开这种文件（$mime）。装一个对应的查看器再试。"
        } catch (e: Exception) {
            "打开失败（${e.javaClass.simpleName}）：${e.message}"
        }
    }

    /**
     * 真能读吗。
     *
     * `canRead()` 在分区存储下**会返回 true**（文件模式位是 r），
     * 但真正 open 的时候 EACCES —— 所以这里必须**实际读一个字节**，
     * 不能只信 `canRead()`。这个坑很隐蔽：只信 canRead 的话，
     * 会走到"能读"的分支、生成 URI、外部应用打开时读到空内容。
     */
    private fun canReadIt(f: File): Boolean {
        if (!f.isFile || !f.canRead()) return false
        return try {
            f.inputStream().use { it.read() }
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 把读不到的文件复制进应用缓存目录。
     *
     * 为什么复制到 `cacheDir`：它在 `file_paths.xml` 里声明了（`cache-path`），
     * 所以复制完就能用 FileProvider 分享出去。
     *
     * 为什么保留扩展名：MIME 判断和接收方选择打开方式都依赖扩展名，
     * 复制成 `shared` 这种无扩展名文件的话，系统会当成 octet-stream，
     * 表现就是"没有应用能打开"。
     *
     * 大小上限 200MB：这是"打开一个文件看看"的场景，不是搬数据。
     * 不设上限的话，用户点一个 4G 的视频会把缓存塞满、还要等很久
     * 却没有任何进度提示。
     */
    private fun copyIntoSandbox(src: File): File? {
        return try {
            if (src.length() > 200L * 1024 * 1024) return null
            val dir = File(activity.cacheDir, "shared")
            dir.mkdirs()
            // 用原名 + 一点前缀避免和别的东西撞名（同名文件会互相覆盖）
            val dst = File(dir, "s_${System.currentTimeMillis()}_${src.name}")
            src.inputStream().use { ins ->
                dst.outputStream().use { out -> ins.copyTo(out) }
            }
            dst
        } catch (e: Exception) {
            // 读不到就是读不到（权限），上层会给用户一句可操作的说明
            null
        }
    }

    /**
     * 按扩展名猜 MIME。猜不到用通配符让系统自己挑。
     *
     * 列表要**尽量全**：猜不到时会落到通配符，而部分 ROM 对通配符的处理
     * 是"列出所有应用"，用户得自己挑；更糟的是有些 ROM 直接不弹。
     * 明确给出 MIME 时系统会直接找对应应用，体验差很多。
     *
     * ⚠️ 这里不能直接写出那个通配符字面量：它是 `*` `/` 两个字符，
     * 而这个注释块本身以 `*` `/` 结尾 —— 写在 KDoc 里会**提前把注释
     * 关掉**，后面全部变成语法错误（编译报"Expecting member declaration"，
     * 报的位置还是下一行的函数签名，很难联想到是注释的问题）。
     */
    private fun mimeOf(path: String): String {
        return when (path.substringAfterLast('.', "").lowercase()) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "bmp" -> "image/bmp"
            "heic", "heif" -> "image/heic"
            "svg" -> "image/svg+xml"
            "tif", "tiff" -> "image/tiff"
            "mp4", "m4v" -> "video/mp4"
            "webm" -> "video/webm"
            "mkv" -> "video/x-matroska"
            "avi" -> "video/x-msvideo"
            "mov" -> "video/quicktime"
            "3gp" -> "video/3gpp"
            "flv" -> "video/x-flv"
            "wmv" -> "video/x-ms-wmv"
            "mp3" -> "audio/mpeg"
            "wav" -> "audio/wav"
            "m4a" -> "audio/mp4"
            "ogg", "oga" -> "audio/ogg"
            "flac" -> "audio/flac"
            "aac" -> "audio/aac"
            "amr" -> "audio/amr"
            "pdf" -> "application/pdf"
            // ---- Office ----
            //
            // 这几个以前落到通配符，用户点开 Word/Excel 时
            // 系统得"列所有应用"，很难找到正确的那个。
            "doc" -> "application/msword"
            "docx" ->
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xls" -> "application/vnd.ms-excel"
            "xlsx" ->
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "ppt" -> "application/vnd.ms-powerpoint"
            "pptx" ->
                "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            // ---- 文本 / 数据 ----
            "txt", "log", "md", "markdown", "ini", "cfg", "conf" -> "text/plain"
            "json" -> "application/json"
            "xml" -> "text/xml"
            "yaml", "yml" -> "text/yaml"
            "csv" -> "text/csv"
            "html", "htm" -> "text/html"
            "js" -> "text/javascript"
            "py" -> "text/x-python"
            "sh" -> "text/x-shellscript"
            "kt" -> "text/x-kotlin"
            "java" -> "text/x-java"
            "c" -> "text/x-c"
            "cpp", "cc", "h" -> "text/x-c++"
            "sql" -> "application/sql"
            // ---- 压缩 / 安装包 ----
            "zip" -> "application/zip"
            "rar" -> "application/vnd.rar"
            "7z" -> "application/x-7z-compressed"
            "tar" -> "application/x-tar"
            "gz" -> "application/gzip"
            "apk" -> "application/vnd.android.package-archive"
            "epub" -> "application/epub+zip"
            else -> "*/*"
        }
    }

    // ------------------------------------------------------------- 定位

    fun hasLocation(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        // 粗略定位也算有 —— 对"附近有什么"这类任务完全够用，
        // 而且耗电低得多。只认 FINE 会把这类用户挡在门外。
        return fine || coarse
    }

    private fun requestLocation(result: MethodChannel.Result) {
        if (hasLocation()) {
            result.success(true)
            return
        }
        pendingPermission = result
        activity.requestPermissions(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            REQ_LOCATION,
        )
    }

    /** 由 Activity 转发 `onRequestPermissionsResult`。 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_LOCATION) return
        val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    /**
     * 取当前位置。
     *
     * ## 为什么用 `getLastKnownLocation` 而不是请求持续更新
     *
     * `requestLocationUpdates` 要注册监听、等回调、再注销，
     * 在一次工具调用里既慢又容易泄漏（注册了没注销）。
     * 而 `getLastKnownLocation` 是**同步立刻返回**上一次系统记录的位置，
     * 对"我在哪 / 附近有什么"这类任务精度完全够（城区通常几秒内就更新过）。
     *
     * 拿不到时如实返回 `ok=false` 并说明原因 —— 让模型知道是
     * "还没有定位记录"（去窗边/开一下地图就会好），而不是"这个功能坏了"。
     */
    private fun location(): Map<String, Any?> {
        if (!hasLocation()) {
            return mapOf("ok" to false, "error" to "没有定位权限")
        }
        return try {
            val lm = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager

            // 按精度从高到低试。GPS 最准但室内常拿不到，
            // 所以后面几个都要试一遍。
            val providers = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
                LocationManager.PASSIVE_PROVIDER,
            )

            var best: Location? = null
            for (p in providers) {
                val l = try {
                    if (lm.isProviderEnabled(p)) lm.getLastKnownLocation(p) else null
                } catch (e: SecurityException) {
                    null
                } catch (e: Exception) {
                    null
                }
                if (l != null && (best == null || l.time > best!!.time)) best = l
            }

            if (best == null) {
                return mapOf(
                    "ok" to false,
                    "error" to "系统还没有任何定位记录。" +
                            "打开一下地图类应用（或到窗边）再试。"
                )
            }

            mapOf(
                "ok" to true,
                "latitude" to best!!.latitude,
                "longitude" to best!!.longitude,
                "accuracy" to best!!.accuracy.toDouble(),
                "provider" to best!!.provider,
                // 定位时间：太旧的话模型该知道"这个位置可能已经不准了"
                "time" to best!!.time,
            )
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to "读取定位失败：${e.message}")
        }
    }
}
