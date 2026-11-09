import 'dart:math' as math;

/// 一个待入库的切片。
class KnowledgeChunkDraft {
  const KnowledgeChunkDraft({required this.text, this.heading = ''});

  final String text;

  /// 这一片所属的标题路径（`第二章 > 2.1 背景`）。
  /// 写进检索结果里，用户能一眼看出出处。
  final String heading;
}

/// 把一篇文档切成**语义尽量完整**的片段。
///
/// ## 为什么不能按固定字数硬切
///
/// 固定长度会把一句话、一个表格、一段代码从中间切断：
///  · 块太大 → 语义被稀释，向量检索命中率下降；
///  · 块太小 → 上下文丢失，模型看到半句话也答不对。
///
/// 这里的顺序是：
///  1. 按**空行**分段，标题行单独成段；
///  2. 超长段落按句号 / 问号 / 换行拆开；
///  3. 段与段拼到接近 [maxChars]，片与片之间保留 [overlap] 字的上下文；
///  4. 记录当前标题路径，检索结果能带出处。
///
/// [maxChars] 按**字符**算而不是 token：中文场景下 700 字约 700 token，
/// 对大多数 embedding 模型都安全。
List<KnowledgeChunkDraft> chunkKnowledgeText(
  String raw, {
  int maxChars = 700,
  int overlap = 120,
}) {
  final List<KnowledgeChunkDraft> out = <KnowledgeChunkDraft>[];
  final StringBuffer buf = StringBuffer();
  String bufHeading = '';

  // 标题栈：进入新标题时把层级 >= 它的旧标题弹掉。
  final List<(int, String)> stack = <(int, String)>[];

  void flush() {
    final String text = buf.toString().trim();
    buf.clear();
    if (text.isEmpty) return;
    out.add(KnowledgeChunkDraft(text: text, heading: bufHeading));
  }

  String headingPath() => stack.map(((int, String) e) => e.$2).join(' > ');

  final List<_Block> blocks = _splitBlocks(raw);
  for (final _Block block in blocks) {
    if (block.headingLevel > 0) {
      // 标题是**天然的语义边界**：先把上一段收掉，避免下一章的开头
      // 被拼到上一章的结尾里。
      flush();
      while (stack.isNotEmpty && stack.last.$1 >= block.headingLevel) {
        stack.removeLast();
      }
      stack.add((block.headingLevel, block.text));
      continue;
    }

    final List<String> pieces = block.text.length > maxChars
        ? _splitLong(block.text, maxChars)
        : <String>[block.text];

    for (final String piece in pieces) {
      if (piece.trim().isEmpty) continue;
      final String heading = headingPath();
      if (buf.isEmpty) {
        bufHeading = heading;
        buf.write(piece.trim());
        continue;
      }
      // +2 是段落之间那两个换行
      if (buf.length + 2 + piece.length <= maxChars) {
        buf.write('\n\n');
        buf.write(piece.trim());
        continue;
      }

      final String prev = buf.toString();
      flush();
      bufHeading = heading.isEmpty ? bufHeading : heading;
      // 重叠不能把这一片顶出 maxChars：先算给正文留多少位置，
      // 超了就截断重叠部分（宁可少一点上下文，也不让块无限膨胀）。
      final int room = maxChars - piece.length - 2;
      if (overlap > 0 && prev.length > overlap && room > 0) {
        final String ov = prev.substring(prev.length - overlap).trimLeft();
        buf.write(ov.length > room ? ov.substring(ov.length - room) : ov);
        buf.write('\n\n');
      }
      buf.write(piece.trim());
    }
  }
  flush();

  // 极端情况：整篇都是空白 / 只有分隔符
  if (out.isEmpty) {
    final String text = raw.trim();
    if (text.isNotEmpty) {
      out.add(KnowledgeChunkDraft(text: text));
    }
  }
  return out;
}

class _Block {
  const _Block(this.text, {this.headingLevel = 0});

  final String text;

  /// 0 = 普通段落；1–6 = Markdown 标题层级。
  final int headingLevel;
}

final RegExp _headingRe = RegExp(r'^(#{1,6})\s+(.+?)\s*$');

List<_Block> _splitBlocks(String raw) {
  final String text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final List<_Block> out = <_Block>[];
  final StringBuffer cur = StringBuffer();

  void flushParagraph() {
    final String p = cur.toString().trim();
    cur.clear();
    if (p.isNotEmpty) out.add(_Block(p));
  }

  bool inCode = false;
  for (final String line in text.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      inCode = !inCode;
      cur.writeln(line);
      continue;
    }
    if (!inCode) {
      final RegExpMatch? m = _headingRe.firstMatch(trimmed);
      if (m != null) {
        flushParagraph();
        out.add(_Block(m.group(2)!.trim(), headingLevel: m.group(1)!.length));
        continue;
      }
    }
    if (trimmed.isEmpty && !inCode) {
      flushParagraph();
      continue;
    }
    cur.writeln(line);
  }
  flushParagraph();
  return out;
}

/// 把超长段落按句子边界拆开；仍然超长才硬切。
List<String> _splitLong(String text, int maxChars) {
  final List<String> sentences = <String>[];
  final StringBuffer cur = StringBuffer();
  final RegExp sentenceEnd = RegExp(r'(?<=[。！？!?；;])');

  for (final String line in text.split('\n')) {
    for (final String s in line.split(sentenceEnd)) {
      if (s.trim().isEmpty) continue;
      if (cur.length + s.length > maxChars && cur.isNotEmpty) {
        sentences.add(cur.toString().trim());
        cur.clear();
      }
      // 单句本身就超长：硬切，避免死循环
      if (s.length > maxChars) {
        if (cur.isNotEmpty) {
          sentences.add(cur.toString().trim());
          cur.clear();
        }
        for (int i = 0; i < s.length; i += maxChars) {
          sentences.add(
            s.substring(i, math.min(i + maxChars, s.length)).trim(),
          );
        }
        continue;
      }
      cur.write(s);
    }
    // 行尾补一个换行：保留段落感，也让"一行一条"的表格不会被粘死
    if (cur.isNotEmpty && cur.length < maxChars) cur.write('\n');
  }
  if (cur.isNotEmpty) sentences.add(cur.toString().trim());
  return sentences.where((String s) => s.isNotEmpty).toList();
}

/// 检索用的分词：拉丁词 + 中文二元组。
///
/// 为什么中文用 bigram 而不是按字：
///  · 按字会把"知识"和"识库"都拆散，召回一堆不相关的片段；
///  · bigram 不依赖词典，器名词、术语、错别字混排都能命中；
///  · 单字查询（"钱"）仍然保留 unigram，否则查不到。
List<String> knowledgeTokens(String text) {
  final List<String> out = <String>[];
  final RegExp re = RegExp(r'[a-zA-Z0-9_]+|[\u4e00-\u9fff]+');
  for (final RegExpMatch m in re.allMatches(text.toLowerCase())) {
    final String s = m.group(0)!;
    final bool latin = RegExp(r'^[a-z0-9_]').hasMatch(s);
    if (latin) {
      out.add(s);
      continue;
    }
    for (int i = 0; i < s.length; i++) {
      if (s.length == 1) {
        out.add(s);
      } else if (i + 1 < s.length) {
        out.add(s.substring(i, i + 2));
      }
    }
  }
  return out;
}

/// 单位化向量。embedding 服务返回的向量长度不一，但余弦只关心方向。
List<double> normalizeVector(List<double> v) {
  double sum = 0;
  for (final double x in v) {
    sum += x * x;
  }
  if (sum <= 0) return List<double>.from(v);
  final double n = math.sqrt(sum);
  return List<double>.generate(v.length, (int i) => v[i] / n);
}

double cosineSimilarity(List<double> a, List<double> b) {
  final int n = math.min(a.length, b.length);
  double dot = 0;
  for (int i = 0; i < n; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}
