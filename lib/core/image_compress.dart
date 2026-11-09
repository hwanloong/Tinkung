import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// 压缩结果：**路径可能变**（PNG/WebP 压完写成 JPEG，扩展名要跟着改，
/// 否则发送时按扩展名判断 mime 会把 JPEG 标成 PNG，服务端可能直接 400）。
class ImageShrink {
  const ImageShrink(this.path, this.size);

  final String path;
  final int size;
}

/// 上传图片的**落盘压缩**。
///
/// ## 为什么必须在落盘时做
///
/// 之前是在发送前（`ImageDataCache.dataUrlFor`）才用 `package:image`
/// 把原图解码成完整位图再缩放。问题是解码那一步的内存和**原始像素数**
/// 成正比：一张 8000×6000 的照片解出来就是 192 MB RGBA。多选十几张时，
/// 一张接一张地分配，GC 根本来不及回收 —— 这就是"多文件上传闪退"
/// 最直接的那一刀。
///
/// 这里改用 Flutter 引擎的 `ImageDescriptor`：它先只读文件头拿到尺寸，
/// 再用 `instantiateCodec(targetWidth/targetHeight)` **按目标尺寸解码**。
/// 解码器不会先生成完整位图，峰值内存只和 1600px 的缩略图有关（几 MB），
/// 和原图多大无关。
///
/// 落盘时压过一次之后，后面所有环节（缩略图、发送、多轮重发）拿到的
/// 都是小图，不再有第二次数百 MB 的解码。
class ImageCompressor {
  const ImageCompressor._();

  /// 长边上限。1600 对模型识图足够（文字、界面元素都还清楚），
  /// 同时把常见手机照片压到 200–500 KB。
  static const int defaultMaxSide = 1600;

  /// 质量。80 对"看清文字/界面元素"足够，比 85 小约 25%：
  /// 20 张图一起发时，这点体积差就是"能不能全部内联"的分界线。
  static const int defaultQuality = 80;

  /// 超过这个体积的图片直接不尝试解码。
  ///
  /// 不是"压缩上限"，而是**防呆**：真正的图片极少超过 40 MB，
  /// 到这个量级多半是扩展名骗人的二进制文件，读进内存只会徒增风险。
  static const int skipAboveBytes = 40 * 1024 * 1024;

  /// 已经足够小就不重编码（重编码会让小图反而变大、还损失画质）。
  static const int smallEnoughBytes = 900 * 1024;

  /// 原地压缩 [path]。
  ///
  /// 返回**压缩后的路径和大小**：
  ///  · 不需要压 / 解不开 / 压完更大 → 原路径、原大小；
  ///  · 压成功 → 可能是新的 `.jpg` 路径（原文件会被删掉）。
  ///
  /// 任何失败都**不抛异常** —— 调用方保留原文件即可。
  static Future<ImageShrink> shrinkInPlace(
    String path, {
    int maxSide = defaultMaxSide,
    int quality = defaultQuality,
  }) async {
    final File f = File(path);
    int original;
    try {
      original = await f.length();
    } catch (_) {
      return ImageShrink(path, 0);
    }
    if (original <= 0 || original > skipAboveBytes) {
      return ImageShrink(path, original);
    }

    // 动图压成 JPEG 会丢帧，直接保留原样（GIF 一般也不大）。
    final String ext = path.split('.').last.toLowerCase();
    if (ext == 'gif') return ImageShrink(path, original);

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      // ---- 直接从文件建 buffer，不经过 Dart 堆 ----
      //
      // 之前是 `f.readAsBytes()` → `ImmutableBuffer.fromUint8List(raw)`：
      // 一份 40 MB 的图会在 Dart 堆上占 40 MB，再往引擎复制一份又是 40 MB。
      // 20 张图连续处理时，GC 来不及回收这两份临时内存，就是"20 个以上
      // 闪退"的另一刀。
      //
      // `fromFilePath` 由引擎直接按文件映射读取，Dart 堆里一份都不留。
      buffer = await ui.ImmutableBuffer.fromFilePath(path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);

      final int w = descriptor.width;
      final int h = descriptor.height;
      if (w <= 0 || h <= 0) return ImageShrink(path, original);

      final int longSide = w > h ? w : h;
      if (longSide <= maxSide && original <= smallEnoughBytes) {
        return ImageShrink(path, original);
      }

      final double scale = longSide > maxSide ? maxSide / longSide : 1.0;
      final int tw = (w * scale).round().clamp(1, maxSide);
      final int th = (h * scale).round().clamp(1, maxSide);

      codec = await descriptor.instantiateCodec(
        targetWidth: tw,
        targetHeight: th,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;

      final ByteData? rgba = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (rgba == null) return ImageShrink(path, original);

      final img.Image out = img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: rgba.buffer,
        numChannels: 4,
      );
      final Uint8List jpg = img.encodeJpg(out, quality: quality);
      if (jpg.length >= original) return ImageShrink(path, original);

      // ---- 写成 JPEG，扩展名必须跟着改 ----
      //
      // 字节已经是 JPEG 了，文件名还叫 `.png` 会让别的环节（相册预览、
      // 用户自己导出、按扩展名挑查看器的工具）认错格式。发送时虽然按
      // 文件头判 mime，但**文件本身应该自洽** —— 内容是什么，后缀就是什么。
      String target = path;
      final String lower = path.toLowerCase();
      if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg')) {
        final int dot = path.lastIndexOf('.');
        target = '${dot > 0 ? path.substring(0, dot) : path}.jpg';
      }
      await File(target).writeAsBytes(jpg, flush: true);
      if (target != path) {
        try {
          await f.delete();
        } catch (_) {}
      }
      return ImageShrink(target, jpg.length);
    } catch (_) {
      // 解码失败（少见格式 / 文件损坏）就原样留着，让发送端去判断。
      return ImageShrink(path, original);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
