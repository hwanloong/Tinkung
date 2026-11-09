import 'package:flutter/material.dart';

/// 文字标记 / 引用的**底色**。
///
/// ## 为什么存一个 id 而不是直接存颜色
///
/// 颜色要跟着**明暗主题**走：同一个"黄色标记"，在浅色底上是淡黄、
/// 在深色底上必须压暗，否则白字压在上面看不清。
/// 存 ARGB 就等于把当时那套主题的颜色冻结进数据里，
/// 换个主题标记就瞎了。
///
/// 所以存 id，取色时按当前主题算。
enum MarkColor {
  yellow('yellow', '黄'),
  green('green', '绿'),
  blue('blue', '蓝'),
  pink('pink', '粉'),
  gray('gray', '灰');

  const MarkColor(this.id, this.label);

  final String id;
  final String label;

  static MarkColor fromId(String? id) => MarkColor.values.firstWhere(
    (MarkColor c) => c.id == id,
    orElse: () => MarkColor.yellow,
  );

  /// 标记底色。**半透明**：完全不透明会把文字压住，
  /// 而这些标记是"荧光笔"的语义，笔迹本来就该透出底下的字。
  Color background({required bool dark}) {
    return switch (this) {
      MarkColor.yellow =>
        dark ? const Color(0x59FFD54F) : const Color(0x66FFE082),
      MarkColor.green =>
        dark ? const Color(0x5938D679) : const Color(0x664CD98C),
      MarkColor.blue =>
        dark ? const Color(0x593B9BFF) : const Color(0x664DA3FF),
      MarkColor.pink =>
        dark ? const Color(0x59FF6FA5) : const Color(0x66FF9BC0),
      MarkColor.gray =>
        dark ? const Color(0x59BDBDBD) : const Color(0x669E9E9E),
    };
  }
}

/// 一处**文字标记**（长按选中 → 标记）。
///
/// ## 定位方式：原文 + **第几次出现**
///
/// 标记要跨**流式输出、重新解析、消息重排**存活，而这三个都会改变
/// 字符偏移 —— 存偏移量的话，重启一次或重新渲染，标记就落到别的字上了。
/// 所以按**原文**定位。
///
/// 但光有原文不够：只标一个「的」字，正文里几百个「的」会**全被标上**。
/// 所以还要记 [occurrence]（这是第几次出现），组合起来才唯一。
///
/// 引用的锚点用同一套机制，见 [kind]。
enum MarkKind {
  /// 用户标的高亮（荧光笔）
  mark,

  /// 引用：在原文留下一道**虚线**，表示"这句话被引用过"
  quote,
}

class TextMark {
  const TextMark({
    required this.text,
    this.color = MarkColor.yellow,
    this.kind = MarkKind.mark,
    this.occurrence = 0,
  });

  /// 被标记/引用的原文。定位依据之一，见类注释。
  final String text;

  final MarkColor color;
  final MarkKind kind;

  /// 这是消息里**第几次**出现 [text]（从 0 开始）。
  ///
  /// ## 为什么必须有这个字段
  ///
  /// 只按原文定位的话，标记一个「的」字，全文几百个「的」会**全被标上** ——
  /// 这就是用户报的"标记一个字，所有相同的字都被标记了"。
  /// 加上出现次序就唯一了。
  ///
  /// 为什么不用字符偏移量：标记要跨**流式输出、重新解析、消息重排**存活，
  /// 而这些都会改变偏移 —— 存偏移量的话重启一次标记就落到别的字上了。
  ///
  /// 已知边界：内容被压缩/编辑后出现次数变少时，渲染会**跳过**这条标记
  /// （宁可少标一个，也不要标错位置）。
  final int occurrence;

  /// 两处标记是不是"同一处"。
  ///
  /// 判据是 **文本 + 出现次序 + 种类**，**不含颜色** ——
  /// 这样"给同一处换个颜色"会被识别成替换而不是新增，
  /// "取消标记"也能精确找到该删哪一条。
  bool samePlaceAs(TextMark o) =>
      text == o.text && occurrence == o.occurrence && kind == o.kind;

  TextMark copyWith({MarkColor? color}) => TextMark(
    text: text,
    color: color ?? this.color,
    kind: kind,
    occurrence: occurrence,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': text,
    'color': color.id,
    'kind': kind.name,
    'occurrence': occurrence,
  };

  static TextMark fromJson(Map<String, dynamic> j) => TextMark(
    text: j['text']?.toString() ?? '',
    color: MarkColor.fromId(j['color']?.toString()),
    kind: j['kind']?.toString() == 'quote' ? MarkKind.quote : MarkKind.mark,
    occurrence: (j['occurrence'] as num?)?.toInt() ?? 0,
  );

  static List<TextMark> decodeList(dynamic raw) {
    if (raw is! List) return <TextMark>[];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> e) =>
              TextMark.fromJson(Map<String, dynamic>.from(e)),
        )
        .where((TextMark m) => m.text.trim().isNotEmpty)
        .toList();
  }

  static List<Map<String, dynamic>> encodeList(List<TextMark> list) =>
      list.map((TextMark m) => m.toJson()).toList();
}

/// 一条消息**引用的原文**（引用回复）。
///
/// 引用分两个方向，两个都要存：
///  · [text] 是**被引用的原文**，显示在消息上（"回复 @某人：…"那个意思）；
///  · 发出去时还会在原文那条消息上留一道虚线锚点（用 [TextMark] 表达），
///    这样回头翻记录能看出"这句话被人接过"。
class MessageQuote {
  const MessageQuote({required this.text, this.color = MarkColor.blue});

  final String text;
  final MarkColor color;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': text,
    'color': color.id,
  };

  static MessageQuote? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final String t = raw['text']?.toString() ?? '';
    if (t.trim().isEmpty) return null;
    return MessageQuote(
      text: t,
      color: MarkColor.fromId(raw['color']?.toString()),
    );
  }
}
