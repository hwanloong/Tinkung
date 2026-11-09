import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 发给视觉接口之前，把图**整理成对方一定吃得下**的样子。
///
/// ## 为什么必须做（"截图识别有时候降级成本地 OCR"的根因之一）
///
/// 一张手机截图（DPR 3，1080×2400）的 **PNG** 有 2-4 MB，base64 之后
/// 5 MB 上下。很多中转站/服务端对**单次请求体**卡得很死（1-4 MB）：
/// 超了就是 413，或者干脆 400 + 一句看不懂的错误。
/// 而 `read_image` 的约定是"模型识图失败就降级成本地 OCR" ——
/// 用户看到的现象就是"有时候只能读出文字，看不懂画面"。
///
/// 以前只用 Flutter 自带的编码器缩到长边 1600 再出 **PNG**：
/// 尺寸是变小了，但 PNG 是无损格式，截图这种内容压完还有 1.5-3 MB ✗。
/// 现在改成 **JPEG**（质量换体积），并且**逐级往下压**直到进预算。
///
/// ## 预算
///
/// 原始字节 ≤ [budgetBytes]（900 KB，base64 后约 1.2 MB）。这是个保守值：
/// 见过的中转站里最紧的一档卡在 1 MB 左右，而 900 KB 的截图对识图来说
/// 已经完全够用（长边仍有 1024-1600 像素，界面上的字看得清）。
class VisionImage {
  const VisionImage._();

  /// 长边上限（第一档）。
  static const int maxSide = 1600;

  /// 发出去之前的原始字节预算。
  static const int budgetBytes = 900 * 1024;

  /// 小到这个程度就不折腾：解码本身也要时间。
  static const int smallEnough = 400 * 1024;

  /// 整理一张图。返回值里的 [note] 是给人看的一句话（压没压、压到多大）。
  ///
  /// 解不开（少见格式）就**原样返回**：宁可发出去让服务端判断，
  /// 也不能因为"想省体积"把这次识图搞失败。
  static ({List<int> bytes, String mime, String note}) prepare(
    List<int> raw, {
    String mime = '',
  }) {
    final String fallbackMime = mime.isEmpty ? 'image/png' : mime;
    if (raw.length <= smallEnough) {
      // 小图原样发，但**格式按文件头校正**：扩展名会骗人，
      // 发错 mime 有些服务端直接 400（表现就是"降级 OCR"）。
      return (bytes: raw, mime: sniffMime(raw) ?? fallbackMime, note: '');
    }

    img.Image? src;
    try {
      src = img.decodeImage(Uint8List.fromList(raw));
    } catch (_) {
      src = null;
    }
    if (src == null) {
      // 解不开就原样发（WebP 之类这个库偶尔也认不全）
      return (
        bytes: raw,
        mime: sniffMime(raw) ?? fallbackMime,
        note: '（这张图没解开，按原样发送：${_kb(raw.length)}）',
      );
    }

    final int longSide = math.max(src.width, src.height);

    // ---- 先试**原分辨率**（只对截图这个量级）----
    //
    // 截图是最主要的识图场景，而它的内容平坦、JPEG 压得动：1080×2400
    // 的界面截图通常在预算以内。保留原分辨率能让模型看清小字，
    // 凭空缩到 1600 反而把字糊掉。大照片（>2400 长边）跳过这一步：
    // 编码本身就要几百毫秒和一大块内存，收益也有限。
    if (longSide <= 2400) {
      final List<int> jpg = img.encodeJpg(src, quality: 85);
      if (jpg.length <= budgetBytes) {
        return (
          bytes: jpg,
          mime: 'image/jpeg',
          note:
              '（原图 ${_kb(raw.length)} → ${src.width}×${src.height} '
              'JPEG ${_kb(jpg.length)}，保持原分辨率）',
        );
      }
    }

    // 逐级往下压：长边 1600、质量 85 起步；不够再降分辨率 / 降质量。
    //
    // ⚠️ 这里是按**长边**缩，而且**只缩不放**。
    // 以前是按"宽"缩到候选值：手机截图是竖的（1080×2400），
    // 长边是 2400，按宽缩到 1600 等于把图**放大**成 1600×3556 ——
    // 体积反而更大，正是"图太大被拒 → 降级 OCR"的来源之一。
    final List<int> sides = <int>[maxSide, 1280, 1024, 800, 640];
    for (final int limit in sides) {
      // 比原图还大的档位不放大（第一档保留：用来把大 PNG 重编码成 JPEG）。
      if (limit > longSide && limit != maxSide) continue;
      final double scale = limit >= longSide ? 1.0 : limit / longSide;
      final int targetW = math.max(1, (src.width * scale).round());
      final int targetH = math.max(1, (src.height * scale).round());
      final img.Image resized = targetW >= src.width && targetH >= src.height
          ? src
          : img.copyResize(
              src,
              width: targetW,
              height: targetH,
              interpolation: img.Interpolation.average,
            );
      for (final int q in <int>[85, 70]) {
        final List<int> jpg = img.encodeJpg(resized, quality: q);
        if (jpg.length <= budgetBytes) {
          return (
            bytes: jpg,
            mime: 'image/jpeg',
            note:
                '（原图 ${_kb(raw.length)} → ${resized.width}×${resized.height} '
                'JPEG ${_kb(jpg.length)}，质量 $q；太大时很多接口会直接拒绝）',
          );
        }
      }
    }
    // 理论上走不到，保险：最小尺寸 + 最低质量。
    final double scale = 640 / longSide;
    final img.Image small = longSide <= 640
        ? src
        : img.copyResize(
            src,
            width: math.max(1, (src.width * scale).round()),
            height: math.max(1, (src.height * scale).round()),
            interpolation: img.Interpolation.average,
          );
    final List<int> last = img.encodeJpg(small, quality: 60);
    return (
      bytes: last,
      mime: 'image/jpeg',
      note:
          '（压到最小：${small.width}×${small.height} '
          'JPEG ${_kb(last.length)}）',
    );
  }

  /// 按**文件头**猜真实图片格式（拿不到就返回 null）。
  static String? sniffMime(List<int> b) {
    bool at(int i, int v) => i < b.length && (b[i] & 0xFF) == v;
    if (at(0, 0x89) && at(1, 0x50) && at(2, 0x4E) && at(3, 0x47)) {
      return 'image/png';
    }
    if (at(0, 0xFF) && at(1, 0xD8)) return 'image/jpeg';
    if (at(0, 0x47) && at(1, 0x49) && at(2, 0x46)) return 'image/gif';
    if (at(0, 0x52) &&
        at(1, 0x49) &&
        at(2, 0x46) &&
        at(3, 0x46) &&
        at(8, 0x57) &&
        at(9, 0x45) &&
        at(10, 0x42) &&
        at(11, 0x50)) {
      return 'image/webp';
    }
    return null;
  }

  static String _kb(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
