import java.util.Properties

plugins {
    id("com.android.application")
    // 必须有这一行：下面的 `kotlin { compilerOptions { ... } }` 依赖 Kotlin 插件提供的
    // 扩展，漏掉就会报 "Unresolved reference 'compilerOptions'"。
    // 版本在 settings.gradle.kts 的 plugins 块里声明。
    id("org.jetbrains.kotlin.android")
    // Chaquopy 要放在 Android 插件之后、Flutter 插件之前
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- 发布签名 ----
//
// 从 `android/key.properties` 读密钥库位置和口令。文件不在时**回退到调试
// 签名**，这样别人 clone 下来不配密钥也能构建（只是出的包不能互相升级）。
//
// 为什么必须换成固定密钥：调试密钥由 `~/.android/debug.keystore` 生成，
// 那东西会随机器/重建而变。而 Android 安装更新要求**签名完全一致**，
// 变了就 `INSTALL_FAILED_UPDATE_INCOMPATIBLE` —— 表现正是"新版本装不上"。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}
val hasReleaseKey = keystorePropsFile.exists() &&
    !keystoreProps.getProperty("storeFile").isNullOrBlank()

android {
    namespace = "com.dsh.dsh_agent"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dsh.dsh_agent"
        // Shizuku 需要 API 23+；这里抬到 26 (Android 8.0)，因为用到了
        // foreground service 与 MediaProjection 相关的新行为。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只出 64 位。**刻意砍掉 armeabi-v7a**：
        // Chaquopy 从 Python 3.12 起不再支持 32 位 ABI，而我们要用 3.13 ——
        // 它对 16KB 页设备（Android 15+ 新机）的 wheel 兼容性最好。
        // 二者不可兼得，32 位设备在 2026 年已无保留价值。
        //
        // ⚠️ **不要试图用 splits 出分架构包**。AGP 9 默认启用新 DSL
        // （android.newDsl=true），`splits` 在这个层级已不被支持 ——
        // 用它会让整个 build.gradle.kts 脚本编译失败
        // （报 "android{} is deprecated" 然后连锁失败）。
        // 所以只能用 ndk.abiFilters，代价是产出一个含两个 ABI 的包。
        ndk {
            abiFilters.clear()
            abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
        }
    }

    // 发布密钥。只在 `key.properties` 存在时创建 —— 否则
    // `signingConfigs.getByName("release")` 会在上面那个三元里抛
    // "SigningConfig with name 'release' not found"。
    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(
                    keystoreProps.getProperty("storeFile")
                )
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有 `key.properties` 就用项目自带的固定发布密钥；
            // 没有就退回调试签名（保证 clone 下来能构建，但出的包不能升级）。
            //
            // 之前这里写死成调试签名 —— 那是"签名不一致装不上"的根源：
            // 调试密钥随机器/重建而变，Android 要求更新包的签名与已装包
            // 完全一致，一变就拒装。
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 自用包，不做混淆/裁剪：Shizuku 用反射拿 API，混淆反而容易出玄学问题。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // ---- 打包原生库时**必须解压** ----
    //
    // 内嵌 Linux 环境里的 `proot` 是放在 `jniLibs` 里当"原生库"带进来的
    // （见 tools/stage_termux_native.py 说明为什么必须这么放）。
    // 而 Android 10+ **只允许执行真实存在于文件系统上的文件** ——
    // 如果原生库留在 APK 里不落地（`extractNativeLibs=false`，AGP 的默认），
    // 我们拿不到一个可执行的路径，`proot` 根本起不来。
    //
    // 代价：APK 里这些 .so 会以未压缩/独立文件形式存在，安装时多占几 MB。
    // 换来的是一整个能跑的 Linux 环境，值。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// ============================================================ Chaquopy
//
// 把 CPython 嵌进应用 —— 用户零配置就有完整的 Python。
//
// 版本选 3.13 而不是更高的 3.14，原因是 **wheel 供给**：
// Chaquopy 明确说 3.14 目前 "very few Android wheels available"，
// 而我们要用的 python-docx / python-pptx **都依赖 lxml（C 扩展）**——
// 没有 wheel 就装不上，Word 和 PPT 功能直接废掉。
// 3.13 是目前 wheel 覆盖最好的版本，而且对 16KB 页设备兼容性也好。
//
// buildPython 必须写**绝对路径**：
// 本机默认的 `python` 是 3.14，版本对不上会直接构建失败；
// 而 `py` launcher 在 WindowsApps 里，Gradle 的 PATH 看不到它
// （实测报 "Couldn't find 'py' on the PATH"）。所以只能写死路径。
// 这台机器的工具链本来就是固定位置，写在注释里说明来源即可。
chaquopy {
    defaultConfig {
        version = "3.13"
        buildPython("C:\\Users\\lmqhw\\AppData\\Local\\Programs\\Python\\Python313\\python.exe")
        pip {
            // ⚠️ **Chaquopy 没有运行时的 pip。**
            // 这里列的包在**构建时**装进 APK，用户装不了任何东西 ——
            // 想加包必须改这里 + 重新构建。所以一次装够。
            //
            // 分工：
            // · 固定能力（Office、数据处理）→ 在这里烤进去，用户零配置
            // · 任意/临时需求 → termux 工具，用户随时 pkg install
            // · 把能力组合成新工具 → 插件（shell/HTTP/python），运行时加
            install("openpyxl")        // Excel（纯 Python，已验证）
            install("python-docx")     // Word
            install("python-pptx")     // PPT
            install("lxml")            // 上面两个的依赖，C 扩展 —— 关键考验
            install("pillow")          // 图像处理
            install("requests")        // HTTP
            install("beautifulsoup4")  // 网页解析
        }
    }
}

dependencies {
    // Shizuku：api 提供 Shizuku 类与权限/监听 API，provider 负责跨进程权限传递。
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    // aidl 提供 IShizukuService —— 必须显式依赖：
    // Shizuku.newProcess 在 13.1.5 里是 private，执行命令只能走这层 AIDL 接口。
    implementation("dev.rikka.shizuku:aidl:13.1.5")
    implementation("androidx.core:core-ktx:1.13.1")

    // ---- ML Kit 的中文文本识别器（离线 OCR 用）----
    //
    // **这个依赖必须由「应用」来加，插件自己不带任何语种的模型。**
    // `google_mlkit_text_recognition` 只是按 script 去实例化
    // `ChineseTextRecognizerOptions`，而那个类属于 `text-recognition-chinese`
    // 这个 artifact（它连带把中文识别模型打进 APK）。
    //
    // 不加的后果**不是"识别不出来"，而是直接崩溃**：
    //
    //   java.lang.NoClassDefFoundError: Failed resolution of:
    //     Lcom/google/mlkit/vision/text/chinese/ChineseTextRecognizerOptions$Builder;
    //     at com.google_mlkit_text_recognition.TextRecognizer.initialize(…)
    //
    // 而且它崩在插件的 MethodChannel 回调里 —— 那条路径上没有 Dart 侧的
    // try/catch 能拦住，用户看到的就是"点一下识图，应用没了"。
    // （2026-10-15 拿到的真机崩溃日志，就是这一条。）
    //
    // 选 **bundled**（打进 APK）而不是 play-services 那个 unbundled 版本：
    // 后者体积小，但模型要首次使用时从 Play 服务下载 —— 在没有 GMS 的
    // 国产 ROM 上直接不可用，而"离线 OCR"正是这个工具的卖点。
    // 代价是 APK 变大几 MB；换成 unbundled 只需替换这一行。
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

flutter {
    source = "../.."
}
