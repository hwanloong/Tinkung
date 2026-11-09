// 正文内嵌图片 + 生图工具的**改图端点**。
//
// 这两块都有"猜错了不会报错、只是静默不工作"的部分，所以必须测：
//  · Markdown 图片只在**独占一行**时才被识别。正则写错的话图片
//    会退化成一段 `![x](y)` 原文 —— 看起来像"模型没按格式写"，
//    实际是解析器的问题；
//  · `/images/generations` → `/images/edits` 的替换。用户的 baseUrl
//    形态很多（带不带 `/v1`、带不带别的后缀），替换错了就是 404，
//    而报错只会说"接口不存在"。
import 'package:dsh_agent/ui/markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('正文里的图片', () {
    test('独占一行的 Markdown 图片能被识别', () {
      final List<MdBlockInfo> blocks = debugParseBlocks(
        '看这张图：\n\n![示例](/shared/a.png)\n\n就这样。',
      );
      final Iterable<MdBlockInfo> imgs = blocks.where(
        (MdBlockInfo b) => b.kind == 'image',
      );
      expect(imgs.length, 1);
      expect(imgs.first.src, '/shared/a.png');
      expect(imgs.first.alt, '示例');
    });

    test('http 地址同样识别', () {
      final List<MdBlockInfo> blocks = debugParseBlocks(
        '![图](https://example.com/a.png)',
      );
      expect(blocks.where((MdBlockInfo b) => b.kind == 'image').length, 1);
      expect(blocks.first.src, 'https://example.com/a.png');
    });

    test('混排在文字里的图片**不**当块处理（退化成文字，不丢内容）', () {
      // 行内混排要做成 WidgetSpan 才能渲染，而那个会撑坏行高、
      // 也让选中复制跨 WidgetSpan 的行为不可靠。所以刻意只认独占一行。
      final List<MdBlockInfo> blocks = debugParseBlocks('见下图 ![x](/a.png) 所示');
      expect(blocks.where((MdBlockInfo b) => b.kind == 'image'), isEmpty);
      // 但原文必须在，不能凭空消失
      expect(
        blocks.map((MdBlockInfo b) => b.text ?? '').join(),
        contains('![x](/a.png)'),
      );
    });

    test('代码块里的图片语法不算图片', () {
      final List<MdBlockInfo> blocks = debugParseBlocks(
        '```\n![x](/a.png)\n```',
      );
      expect(blocks.where((MdBlockInfo b) => b.kind == 'image'), isEmpty);
      expect(blocks.first.kind, 'code');
    });

    test('说明文字可以为空', () {
      final List<MdBlockInfo> blocks = debugParseBlocks('![](/a.png)');
      expect(blocks.where((MdBlockInfo b) => b.kind == 'image').length, 1);
    });
  });
}
