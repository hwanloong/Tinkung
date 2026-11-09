plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.dsh.privtasker.sandbox"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.dsh.privtasker.sandbox"
        minSdk = 26
        // 28 是 Termux 长期使用的档位：允许在应用私有目录执行 rootfs 里的程序，
        // 不受 targetSdk 29+ 的 W^X 限制影响。这个插件只走侧载，不上架。
        targetSdk = 28
        versionCode = 2
        versionName = "1.1"
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    // 这是侧载插件，不上架 Google Play。保留 targetSdk 28 是为了
    // 让 rootfs 内的可执行文件在旧版 Android 上也能正常运行；
    // Play 的 targetSdk 时效检查在这里没有意义。
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
