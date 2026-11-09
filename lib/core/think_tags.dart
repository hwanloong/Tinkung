/// 把正文里"包在标签里的思考"拆出来。
///
/// ## 为什么需要它
///
/// 正规的推理模型走 `reasoning_content` 字段，我们直接放进「思考」卡片。
/// 但**有些模型和大部分中转站不走这个字段**：它们把思维链直接写进正文，
/// 外面包一层 ` thinking…`（也有 `<thinking>` / `<reasoning>` / `<thought>`）。
///
/// 不拆的话，用户看到的就是一整段思考过程**混在回答里**，
/// 而且开头那个 `{"<"}think{">"}` 会明晃晃地出现在正文第一行。
///
/// ## 三种形态都要认（实测都出现过）
///
///  1. 成对的 `think_a…`；
///  2. **只有开标签**（还在流式输出，或者服务端把闭合标签吞了）——
///     后面全部算思考，正文里不留残渣；
///  3. **只有闭标签**（有些中转站会把开标签吃掉）—— 第一个闭标签之前
///     的那段算思考。
///
/// 顺带把标签本身**从正文里彻底删掉**：哪怕这段没被识别成思考，
/// 一个孤零零的 `think_b` 留在正文里也是垃圾。
class ThinkSplit {
  const ThinkSplit({required this.content, required this.reasoning});

  final String content;
  final String reasoning;

  bool get changed => reasoning.trim().isNotEmpty;
}

/// 标签名统一成这几个。`think` 是最常见的那一个（DeepSeek 系）。
const String _kTagNames = 'think|thinking|reasoning|thought';

final RegExp _pairPattern = RegExp(
  '<($_kTagNames)(?:\\s[^>]*)?>([\\s\\S]*?)(?:</\\1\\s*>|\$)',
  caseSensitive: false,
);

final RegExp _strayClose = RegExp(
  '</(?:$_kTagNames)\\s*>',
  caseSensitive: false,
);

/// 拆一次。**不改变原文里的其它内容**（缩进、空行都留着）。
ThinkSplit splitThinkTags(String raw) {
  if (raw.trim().isEmpty) {
    return ThinkSplit(content: raw, reasoning: '');
  }
  final StringBuffer reasoning = StringBuffer();
  String content = raw;

  // ---- 1 / 2：成对、以及"只有开标签" ----
  content = content.replaceAllMapped(_pairPattern, (Match m) {
    final String body = (m.group(2) ?? '').trim();
    if (body.isNotEmpty) {
      if (reasoning.isNotEmpty) reasoning.write('\n\n');
      reasoning.write(body);
    }
    // 整段替换成空（标签本身一起删）
    return '';
  });

  // ---- 3：只有闭标签 ----
  //
  // 走到这里如果还剩一个 `</think>`，说明开标签被谁吃了。
  // 它前面那段几乎一定是思考（模型都是"先想再答"）。
  final RegExpMatch? close = _strayClose.firstMatch(content);
  if (close != null) {
    final String head = content.substring(0, close.start).trim();
    if (head.isNotEmpty) {
      if (reasoning.isNotEmpty) reasoning.write('\n\n');
      reasoning.write(head);
    }
    content = content.substring(close.end);
    // 后面可能还有零星的闭标签，一并清掉
    content = content.replaceAll(_strayClose, '');
  }

  // 剩下的零散标签（比如 `think_c` 重复出现）也删掉 —— 它们是垃圾。
  content = content.replaceAll(
    RegExp('</?(?:$_kTagNames)(?:\\s[^>]*)?>', caseSensitive: false),
    '',
  );

  // 拆完之后开头结尾常常多出一堆空行，收一下（中间的排版不动）。
  return ThinkSplit(
    content: content.trim(),
    reasoning: reasoning.toString().trim(),
  );
}
