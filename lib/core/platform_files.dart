import 'dart:io';

import 'package:flutter/services.dart';

/// 打开文件和取定位 —— 都走原生（见 `FileOpenBridge.kt`）。
///
/// ## 为什么"打开自己生成的文件"需要原生代码
///
/// 生成出来的图片、视频落在**应用私有目录**（`getFilesDir()`），
/// 别的应用读不到；而 Android 7 起还禁止把 `file://` URI 交给外部应用
/// （`FileUriExposedException`）。所以必须由原生侧用 FileProvider
/// 换一个 `content://` URI 并临时授权 —— Dart 层做不到这件事。
///
/// 之前的表现就是"点生成的文件没反应"：路径是对的、文件也在，
/// 但**没有任何应用能打开它**，因为那个路径对外不存在。
class PlatformFiles {
  const PlatformFiles._();

  static const MethodChannel _ch = MethodChannel('dsh/fileopen');

  /// 把界面里显示的路径解析成设备上真实存在的路径。
  ///
  /// Termux/Linux 里写 `/shared/a.pdf` 时，真实文件在
  /// `filesDir/shared/a.pdf`；`/sdcard` 也可能和真实主存储路径不完全一样。
  /// 不解析就会“卡片上有文件、点开说找不到”。
  ///
  /// [search] 为 true 时，原生侧会按文件名在常见目录里做一次有限搜索，
  /// 用于用户主动点文件那一下；后台批量调用不要开。
  static Future<String?> resolve(String path, {bool search = false}) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<String>('resolvePath', <String, dynamic>{
        'path': path,
        'search': search,
      });
    } catch (_) {
      return null;
    }
  }

  /// 打开一个文件。
  ///
  /// 返回 `null` 表示成功，否则是**给用户看的**错误说明
  /// （"文件不存在"/"没有应用能打开这种文件"…）。
  /// 返回错误文本而不是布尔，是因为这些失败的处理方式完全不同，
  /// 一句"打开失败"帮不到用户。
  static Future<String?> open(String path) async {
    if (!Platform.isAndroid) {
      return '当前平台不支持直接打开文件（需要文件管理器手动打开）。';
    }
    try {
      return await _ch.invokeMethod<String>('open', <String, dynamic>{
        'path': path,
      });
    } on PlatformException catch (e) {
      return '打开失败：${e.message ?? e.code}';
    } catch (e) {
      return '打开失败：$e';
    }
  }

  /// 把文件**存进用户能找到的地方**（图片进「图片/Zeus」，其它进「下载」）。
  ///
  /// 返回 `null` = 成功，否则是给用户看的错误说明。
  /// 私有目录 → 公共目录在 Android 11+ 写不进去，必须由原生走 MediaStore，
  /// 所以这一条和 [open] 一样只能在原生侧做。
  static Future<String?> save(String path, {String name = ''}) async {
    if (!Platform.isAndroid) {
      return '当前平台不支持保存到系统目录。';
    }
    try {
      return await _ch.invokeMethod<String>('save', <String, dynamic>{
        'path': path,
        'name': name,
      });
    } on PlatformException catch (e) {
      return '保存失败：${e.message ?? e.code}';
    } catch (e) {
      return '保存失败：$e';
    }
  }

  static Future<bool> hasLocationPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('hasLocationPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求定位权限。返回用户是否给了（精确或粗略任一）。
  static Future<bool> requestLocationPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('requestLocationPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 取当前位置。失败时 [LocationFix.error] 里是原因。
  static Future<LocationFix> location() async {
    if (!Platform.isAndroid) {
      return const LocationFix(error: '当前平台不支持定位');
    }
    try {
      final Map<dynamic, dynamic>? m = await _ch
          .invokeMethod<Map<dynamic, dynamic>>('location');
      if (m == null) return const LocationFix(error: '没有返回定位数据');
      if (m['ok'] != true) {
        return LocationFix(error: m['error']?.toString() ?? '取定位失败');
      }
      return LocationFix(
        latitude: (m['latitude'] as num?)?.toDouble(),
        longitude: (m['longitude'] as num?)?.toDouble(),
        accuracy: (m['accuracy'] as num?)?.toDouble(),
        provider: m['provider']?.toString(),
        time: (m['time'] as num?)?.toInt(),
      );
    } on PlatformException catch (e) {
      return LocationFix(error: e.message ?? e.code);
    } catch (e) {
      return LocationFix(error: '$e');
    }
  }
}

/// 一次定位结果。
class LocationFix {
  const LocationFix({
    this.latitude,
    this.longitude,
    this.accuracy,
    this.provider,
    this.time,
    this.error,
  });

  final double? latitude;
  final double? longitude;

  /// 精度（米）。用来判断"这个坐标能干什么" ——
  /// 几百米精度定位不了具体店铺，但足够说清在哪个区。
  final double? accuracy;

  final String? provider;

  /// 定位时间（毫秒时间戳）。太旧说明位置可能已经不准。
  final int? time;

  /// 失败原因。非空即失败。
  final String? error;

  bool get ok => error == null && latitude != null && longitude != null;

  /// 给模型看的一行描述。
  String describe() {
    if (!ok) return error ?? '取定位失败';
    final String acc = accuracy == null ? '' : '（精度约 ${accuracy!.round()} 米）';
    final String age = _ageText();
    return '纬度 ${latitude!.toStringAsFixed(6)}，'
        '经度 ${longitude!.toStringAsFixed(6)}，'
        '来源 ${provider ?? "未知"}$acc$age';
  }

  /// 定位时间的"多久以前"。数据太旧时模型应该知道这一点。
  String _ageText() {
    final int? t = time;
    if (t == null) return '';
    final Duration d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(t),
    );
    if (d.inMinutes < 1) return '，刚刚';
    if (d.inHours < 1) return '，${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '，${d.inHours} 小时前';
    return '，${d.inDays} 天前（可能已经不准）';
  }
}
