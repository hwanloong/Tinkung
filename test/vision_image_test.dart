import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_agent/tools/vision_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 「截图识别有时候降级成本地 OCR」的根因回归。
///
/// 现象：同一张截图，有时模型能看懂画面，有时只剩本地 OCR 读出来的文字。
/// 根因之一在**体积**：手机截图是 PNG（无损），2-4 MB，base64 之后 5 MB
/// 上下 —— 而不少中转站按请求体大小卡（1-4 MB），超了直接 413/400。
/// `read_image` 的约定是"识图失败就降级 OCR"，于是用户看到的就是识别退化。
///
/// 修法：发之前**压成 JPEG**，并逐级降到进预算为止。
void main() {
  /// 造一张"手机截图大小"的图：1080×2400、带点噪音（纯色压得太狠，不真实）。
  Uint8List phonePng() {
    final img.Image im = img.Image(width: 1080, height: 2400);
    for (int y = 0; y < im.height; y += 3) {
      for (int x = 0; x < im.width; x += 3) {
        im.setPixelRgb(
          x,
          y,
          (x * 7 + y) % 256,
          (x + y * 3) % 256,
          (x * 2 + y) % 256,
        );
      }
    }
    return img.encodePng(im);
  }

  test('大图压成 JPEG，而且体积进预算（这条不修就会降级 OCR）', () {
    final Uint8List png = phonePng();
    expect(
      png.length,
      greaterThan(VisionImage.budgetBytes),
      reason: '造出来的样例图本身得是超预算的量级',
    );

    final ({List<int> bytes, String mime, String note}) r = VisionImage.prepare(
      png,
      mime: 'image/png',
    );

    expect(r.mime, 'image/jpeg');
    expect(r.bytes.length, lessThanOrEqualTo(VisionImage.budgetBytes));
    expect(r.bytes.length, lessThan(png.length ~/ 2));
    expect(r.note, contains('JPEG'));
    // 压完还是能解码的合法 JPEG（0xFF 0xD8 开头）
    expect(r.bytes[0], 0xFF);
    expect(r.bytes[1], 0xD8);
    expect(img.decodeImage(Uint8List.fromList(r.bytes)), isNotNull);
  });

  test('小图原样发出（不为省几百 KB 白解码一遍）', () {
    final img.Image im = img.Image(width: 40, height: 40);
    img.fill(im, color: img.ColorRgb8(10, 20, 30));
    final Uint8List png = img.encodePng(im);

    final ({List<int> bytes, String mime, String note}) r = VisionImage.prepare(
      png,
      mime: 'image/png',
    );
    expect(r.bytes, png);
    expect(r.mime, 'image/png');
    expect(r.note, isEmpty);
  });

  test('解不开的字节：原样返回，绝不因为想省体积把识图搞失败', () {
    final Uint8List junk = Uint8List.fromList(
      List<int>.generate(500 * 1024, (int i) => i % 251),
    );
    final ({List<int> bytes, String mime, String note}) r = VisionImage.prepare(
      junk,
      mime: 'image/webp',
    );
    expect(r.bytes, junk);
    expect(r.mime, 'image/webp');
    expect(r.note, contains('原样'));
  });

  // 竖屏截图（1080×2400）曾经被**按宽**缩到 1600 → 1600×3556，
  // 等于放大：体积更大、更容易被中转站按请求体拒掉 → 降级 OCR。
  // 现在只缩不放：要么原分辨率，要么按长边缩到 1600 以内。
  test('竖屏截图绝不放大', () {
    final Uint8List png = phonePng();
    final ({List<int> bytes, String mime, String note}) r = VisionImage.prepare(
      png,
      mime: 'image/png',
    );

    final img.Image? out = img.decodeImage(Uint8List.fromList(r.bytes));
    expect(out, isNotNull);
    expect(out!.width, lessThanOrEqualTo(1080), reason: '只能缩不能放：宽度不能超过原图');
    expect(out.height, lessThanOrEqualTo(2400), reason: '只能缩不能放：高度不能超过原图');
    expect(r.bytes.length, lessThanOrEqualTo(VisionImage.budgetBytes));
  });

  // 内容嘈杂的图会一路压到预算内；长边此时必须已降到 1600 以内。
  test('超预算的大图按长边缩到预算内', () {
    final Uint8List png = phonePng();
    final ({List<int> bytes, String mime, String note}) r = VisionImage.prepare(
      png,
      mime: 'image/png',
    );
    final img.Image? out = img.decodeImage(Uint8List.fromList(r.bytes));
    final int longSide = math.max(out!.width, out.height);
    if (longSide > VisionImage.maxSide) {
      // 只有"保持原分辨率"这一条路允许超过 1600，那必须是原图尺寸。
      expect(out.width, 1080);
    }
    expect(r.bytes.length, lessThanOrEqualTo(VisionImage.budgetBytes));
  });

  // 截图压得动时应当**保留原分辨率**，而不是凭空缩一半 ——
  // UI 上的小字全靠这个。
  test('能压进预算的截图保留原分辨率（不再无谓地缩小）', () {
    // 轻微随机噪点：PNG 压不动（>400KB，会进压缩流程），
    // 而 JPEG q85 能压到预算内 —— 正是"截图保留原分辨率"这条分支。
    int seed = 987654321;
    int rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed;
    }

    final img.Image im = img.Image(width: 1080, height: 2400);
    for (int y = 0; y < im.height; y++) {
      for (int x = 0; x < im.width; x++) {
        final int n = (rnd() % 17) - 8;
        int c(int base) => (base + n).clamp(0, 255);
        im.setPixelRgb(x, y, c(232), c(236), c(241));
      }
    }
    final Uint8List png = img.encodePng(im);
    expect(png.length, greaterThan(VisionImage.smallEnough));

    final ({List<int> bytes, String mime, String note}) r = VisionImage.prepare(
      png,
      mime: 'image/png',
    );
    final img.Image? out = img.decodeImage(Uint8List.fromList(r.bytes));
    expect(out, isNotNull);
    expect(out!.width, 1080);
    expect(out.height, 2400);
    expect(r.note, contains('保持原分辨率'));
  });

  // 扩展名会骗人：文件头是 PNG、名字叫 .jpg 时，按名字发 mime 会被服务端 400。
  test('按文件头校正 mime，而不是信扩展名', () {
    final img.Image im = img.Image(width: 8, height: 8);
    img.fill(im, color: img.ColorRgb8(1, 2, 3));
    final Uint8List png = img.encodePng(im);

    final ({List<int> bytes, String mime, String note}) r = VisionImage.prepare(
      png,
      mime: 'image/jpeg',
    );
    expect(r.mime, 'image/png');
    expect(VisionImage.sniffMime(png), 'image/png');
  });
}
