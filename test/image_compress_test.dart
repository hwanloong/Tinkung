// 上传图片的落盘压缩。
//
// 这条路径是"多文件上传闪退"的根治点：如果压缩没生效，发送时仍会把
// 原图整张解码成位图。所以这里钉住两件事：
//  1. 大图会被压到长边上限以内，且文件确实变小；
//  2. 已经足够小的图不被重编码（不损失画质、不反而变大）。
import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_agent/core/image_compress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('image_compress_test');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('大图压到长边上限以内，文件变小', () async {
    // 用**噪声**而不是渐变：规律图案的 PNG 会小到几十 KB，JPEG 反而
    // 更大，压缩会被"压完更大就保留原图"的规则正确地跳过 ——
    // 那样这条用例就测不到真正的压缩路径了。
    final math.Random rnd = math.Random(7);
    final img.Image big = img.Image(width: 3000, height: 2000);
    for (int y = 0; y < big.height; y++) {
      for (int x = 0; x < big.width; x++) {
        big.setPixelRgb(
          x,
          y,
          rnd.nextInt(256),
          rnd.nextInt(256),
          rnd.nextInt(256),
        );
      }
    }
    final File file = File('${dir.path}/big.png');
    await file.writeAsBytes(img.encodePng(big));
    final int before = await file.length();

    final ImageShrink res = await ImageCompressor.shrinkInPlace(
      file.path,
      maxSide: 1600,
    );
    expect(res.size, lessThan(before));
    // PNG 压成 JPEG 之后扩展名要跟着改 —— 否则发送时 mime 会判错。
    expect(res.path, endsWith('.jpg'));
    expect(file.existsSync(), isFalse, reason: '旧文件应该被删掉');

    final img.Image? out = img.decodeImage(
      await File(res.path).readAsBytes(),
    );
    expect(out, isNotNull);
    expect(out!.width <= 1600, isTrue);
    expect(out.height <= 1600, isTrue);
  });

  test('小图不重编码（字节完全不变）', () async {
    final img.Image small = img.Image(width: 320, height: 240);
    img.fill(small, color: img.ColorRgb8(30, 120, 200));
    final File file = File('${dir.path}/small.png');
    await file.writeAsBytes(img.encodePng(small));
    final List<int> before = await file.readAsBytes();

    final ImageShrink res = await ImageCompressor.shrinkInPlace(file.path);
    final List<int> bytes = await file.readAsBytes();

    expect(res.path, file.path);
    expect(res.size, before.length);
    expect(bytes, orderedEquals(before));
  });
}
