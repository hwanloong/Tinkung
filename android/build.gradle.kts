allprojects {
    repositories {
        // Flutter 引擎制品只在 download.flutter.io 有。必须排在 Garmin 前面：
        // Garmin 的 Maven 仓库在部分网络下 DNS 都解析不了，排在前面会让
        // 每个 io.flutter:* 制品先去那里失败一次，整个 build 直接断掉。
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
        google()
        mavenCentral()
        maven { url = uri("https://maven.garmin.com/repository/maven/") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
