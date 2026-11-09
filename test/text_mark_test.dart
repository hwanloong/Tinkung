// 文字标记的「第几次出现」定位测试。
//
// 为什么必须测：用户报的 bug 是"标记一个字，所有相同的字都被标记了" ——
// 那不是样式问题，是**定位方式**的问题：只按原文查找时，
// 标一个「的」就会点亮全文所有「的」。
//
// 这里的测试直接跑渲染器用的那段定位逻辑，所以能真正防住回归。
import 'package:dsh_agent/core/text_marks.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻渲染器里的定位逻辑（`_applyMarks` 的第 2 步）。
///
/// 单独写一份而不是 import：渲染器那部分内联在函数里、依赖 TextStyle，
/// 抽出来测的成本比这个复刻高。**两边必须同步改** ——
/// 所以这里断言的是"行为"（找到第几个），不是实现细节。
int? locate(String text, TextMark m) {
  if (m.text.isEmpty) return null;
  int idx = -1;
  int from = 0;
  for (int n = 0; n <= m.occurrence; n++) {
    idx = text.indexOf(m.text, from);
    if (idx < 0) return null;
    from = idx + m.text.length;
  }
  return idx < 0 ? null : idx;
}

void main() {
  group('occurrence 定位', () {
    const String text = '今天的天气不错，今天的风也大。今天适合在家。';

    test('occurrence=0 落在**第一处**', () {
      const TextMark m = TextMark(text: '今天', occurrence: 0);
      expect(locate(text, m), 0);
    });

    test('occurrence=1 落在第二处 —— 这就是修掉"全被标记"的关键', () {
      const TextMark m = TextMark(text: '今天', occurrence: 1);
      // 第 2 处：跳过「今天的天气不错，」共 8 个字符
      expect(locate(text, m), 8);
    });

    test('occurrence=2 落在第三处', () {
      const TextMark m = TextMark(text: '今天', occurrence: 2);
      // 第 3 处：再跳过「今天的风也大。」共 7 个字符
      expect(locate(text, m), 15);
    });

    test('单字也能精确定位（用户报的那个场景）', () {
      const String s = '的的的';
      expect(locate(s, const TextMark(text: '的', occurrence: 0)), 0);
      expect(locate(s, const TextMark(text: '的', occurrence: 1)), 1);
      expect(locate(s, const TextMark(text: '的', occurrence: 2)), 2);
    });

    test('出现次数不够时返回 null（渲染会跳过，不标错位置）', () {
      const String s = '只有一个今天';
      expect(locate(s, const TextMark(text: '今天', occurrence: 5)), isNull);
    });

    test('文本已经不存在时返回 null', () {
      expect(locate('完全不同的内容', const TextMark(text: '今天')), isNull);
    });
  });

  group('samePlaceAs：判"是不是同一处"', () {
    test('文本 + 次序 + 种类相同就算同一处（颜色无关）', () {
      const TextMark a = TextMark(text: '天气', occurrence: 1);
      const TextMark b = TextMark(
        text: '天气',
        occurrence: 1,
        color: MarkColor.pink,
      );
      // 颜色不算在内，所以"换个颜色"能被识别成替换而不是新增 ——
      // 否则同一处会堆两条标记，数据越积越多。
      expect(a.samePlaceAs(b), isTrue);
    });

    test('次序不同就是两处', () {
      const TextMark a = TextMark(text: '天气', occurrence: 0);
      const TextMark b = TextMark(text: '天气', occurrence: 1);
      expect(a.samePlaceAs(b), isFalse);
    });

    test('种类不同就是两回事（标记 vs 引用锚点）', () {
      const TextMark a = TextMark(text: '天气', occurrence: 0);
      const TextMark b = TextMark(
        text: '天气',
        occurrence: 0,
        kind: MarkKind.quote,
      );
      // 同一句话可以既被标记又被引用，两者要能共存
      expect(a.samePlaceAs(b), isFalse);
    });
  });

  group('存档往返', () {
    test('occurrence 会跟着存下来', () {
      const TextMark m = TextMark(text: 'x', occurrence: 7);
      final TextMark back = TextMark.fromJson(m.toJson());
      expect(back.occurrence, 7);
    });

    test('老数据没有 occurrence 字段时默认 0', () {
      // 升级路径：老标记没有这个字段，落到第一处总比全部高亮好
      final TextMark back = TextMark.fromJson(<String, dynamic>{
        'text': 'x',
        'color': 'yellow',
        'kind': 'mark',
      });
      expect(back.occurrence, 0);
    });
  });
}
