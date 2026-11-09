/// 应用信息。
///
/// 版本号与 `pubspec.yaml` 保持一致；这里不引 `package_info_plus`
/// 是因为它要在每个平台加原生依赖，而这一页只需要两个常量。
///
/// **改版本号时两处一起改**：`pubspec.yaml` 的 `version:` 决定
/// Android 的 versionName/versionCode（系统靠它判断能不能覆盖安装），
/// 这里的常量只决定界面上显示什么。漏改一处，用户会看到"设置里写着
/// 2.25 但安装包是 3.0"。
const String kAppName = 'Tinkung';
const String kAppVersion = '3.0.0';
const String kAppBuild = '1081';
const String kAppVersionLabel = '$kAppVersion ($kAppBuild)';
const String kAppTagline = '运行在 Android 上的本地优先 AI Agent';

/// 作者。
const String kAuthorName = 'Hwanloong';
const String kAuthorGithubName = 'hwanloong';
const String kAuthorGithubUrl = 'https://github.com/hwanloong';
