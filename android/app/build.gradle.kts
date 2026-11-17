import java.util.Properties

plugins {
    id("com.android.application")
    // 必须有这一行：下面的 `kotlin { compilerOptions { ... } }` 依赖 Kotlin 插件提供的
    // 扩展，漏掉就会报 "Unresolved reference 'compilerOptions'"。
    // 版本在 settings.gradle.kts 的 plugins 块里声明。
    id("org.jetbrains.kotlin.android")
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
    namespace = "com.agt.tk.hwl"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.agt.tk.hwl"
        // 抬到 26 (Android 8.0)：用到了 foreground service 与
        // MediaProjection 相关的新行为。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只出 64 位。32 位设备在 2026 年已无保留价值。
        //
        // ⚠️ **不要试图用 splits 出分架构包**。AGP 9 默认启用新 DSL
        // （android.newDsl=true），`splits` 在这个层级已不被支持 ——
        // 用它会让整个 build.gradle.kts 脚本编译失败
        // （报 "android{} is deprecated" 然后连锁失败）。
        // 所以只能用 ndk.abiFilters。
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
            // 自用包，不做混淆/裁剪。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // ---- 打包原生库时**必须解压** ----
    //
    // 内嵌 Linux 环境里的 `proot` 是放在 `jniLibs` 里当"原生库"带进来的
    // （见 tools/stage_alpine_native.py 说明为什么必须这么放）。
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

dependencies {
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
    implementation("com.garmin.connectiq:ciq-companion-app-sdk:2.4.0@aar")
}

flutter {
    source = "../.."
}

