import 'package:flutter/services.dart';

/// 一页渲染好的 PDF。
class RenderedPdfPage {
  const RenderedPdfPage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.pageCount,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int pageCount;

  double get aspect => height <= 0 ? 0.7 : width / height;
}

class PdfRenderException implements Exception {
  const PdfRenderException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// PDF → 位图。走 Android 自带的 PdfRenderer（见 PdfBridge.kt）。
class PdfRender {
  const PdfRender._();

  static const MethodChannel _channel = MethodChannel('dsh/pdf');

  static Future<int> pageCount(String path) async {
    try {
      final int? n = await _channel.invokeMethod<int>(
        'pageCount',
        <String, dynamic>{'path': path},
      );
      if (n == null || n <= 0) {
        throw const PdfRenderException('PDF 没有页面');
      }
      return n;
    } on PlatformException catch (e) {
      throw PdfRenderException(e.message ?? '打不开 PDF');
    } on MissingPluginException {
      throw const PdfRenderException('当前平台不支持 PDF 预览');
    }
  }

  static Future<RenderedPdfPage> renderPage(
    String path,
    int index, {
    int maxWidth = 1400,
  }) async {
    try {
      final Map<dynamic, dynamic>? raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('renderPage', <String, dynamic>{
            'path': path,
            'index': index,
            'maxWidth': maxWidth,
          });
      if (raw == null) throw const PdfRenderException('PDF 渲染没有返回内容');
      final dynamic bytes = raw['bytes'];
      final Uint8List data = bytes is Uint8List
          ? bytes
          : Uint8List.fromList((bytes as List<dynamic>).cast<int>());
      return RenderedPdfPage(
        bytes: data,
        width: (raw['width'] as num?)?.toInt() ?? 0,
        height: (raw['height'] as num?)?.toInt() ?? 0,
        pageCount: (raw['pageCount'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      throw PdfRenderException(e.message ?? 'PDF 渲染失败');
    } on MissingPluginException {
      throw const PdfRenderException('当前平台不支持 PDF 预览');
    }
  }
}
