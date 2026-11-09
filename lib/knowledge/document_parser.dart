import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:xml/xml.dart';

/// 解析后的一篇文档。
class ParsedDocument {
  const ParsedDocument({
    required this.title,
    required this.text,
    required this.kind,
  });

  final String title;
  final String text;

  /// 给人看的来源类型（Markdown / PDF / Word / 图片 OCR…）。
  final String kind;

  int get chars => text.length;
}

/// 把本地文件解析成纯文本。
///
/// ## 为什么"解析质量 > 模型质量"
///
/// RAG 的上限在切片，切片的上限在解析：一个双栏 PDF 被读成
/// "左栏第一行 + 右栏第一行"交错，后面再好的 embedding 也救不回来。
/// 所以这里按格式分开处理，并且**在解析失败时明确说原因**，
/// 而不是把一堆乱码塞进知识库。
Future<ParsedDocument> parseKnowledgeFile(String path, {String? title}) async {
  final File f = File(path);
  if (!await f.exists()) {
    throw const FormatException('文件不存在');
  }
  final int size = await f.length();
  // 手机内存有限：30 MB 以上的文档先明确拒绝，别在解析时 OOM。
  if (size > 30 * 1024 * 1024) {
    throw const FormatException('文件太大（超过 30 MB），请先拆分或转成文本');
  }
  final Uint8List bytes = await f.readAsBytes();
  final String name = title?.trim().isNotEmpty == true
      ? title!.trim()
      : _baseName(f.path);
  return parseKnowledgeBytes(bytes, f.path, title: name);
}

Future<ParsedDocument> parseKnowledgeBytes(
  Uint8List bytes,
  String sourcePath, {
  String? title,
}) async {
  final String name = (title?.trim().isNotEmpty ?? false)
      ? title!.trim()
      : _baseName(sourcePath);
  final String ext = _ext(sourcePath);

  try {
    switch (ext) {
      case 'md':
      case 'markdown':
      case 'txt':
      case 'text':
      case 'log':
      case 'json':
        return ParsedDocument(
          title: name,
          text: _decodeText(bytes),
          kind: ext == 'md' || ext == 'markdown' ? 'Markdown' : '文本',
        );

      case 'html':
      case 'htm':
        return ParsedDocument(
          title: name,
          text: htmlToPlainText(_decodeText(bytes)),
          kind: '网页',
        );

      case 'csv':
      case 'tsv':
        return ParsedDocument(
          title: name,
          text: _tabularToText(_decodeText(bytes), ext == 'tsv' ? '\t' : ','),
          kind: ext.toUpperCase(),
        );

      case 'docx':
        return ParsedDocument(
          title: name,
          text: _docxToText(bytes),
          kind: 'Word',
        );

      case 'xlsx':
        return ParsedDocument(
          title: name,
          text: _xlsxToText(bytes),
          kind: 'Excel',
        );

      case 'pptx':
        return ParsedDocument(
          title: name,
          text: _pptxToText(bytes),
          kind: 'PPT',
        );

      case 'pdf':
        return ParsedDocument(
          title: name,
          text: _pdfToText(bytes),
          kind: 'PDF',
        );

      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'webp':
      case 'bmp':
        return ParsedDocument(
          title: name,
          text: await _imageToText(sourcePath),
          kind: '图片 OCR',
        );

      default:
        // 未知扩展名：可能是纯文本。能按 UTF-8 解出足够可读内容就用，
        // 否则明确拒绝，不让二进制垃圾进库。
        final String text = _decodeText(bytes);
        if (_looksReadable(text)) {
          return ParsedDocument(title: name, text: text, kind: '文本');
        }
        throw FormatException('不支持的文件类型：.$ext');
    }
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('解析失败：$e');
  }
}

String _baseName(String path) {
  final String base = path.split(RegExp(r'[/\\]')).last;
  final int dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

String _ext(String path) {
  final String base = path.split(RegExp(r'[/\\]')).last;
  final int dot = base.lastIndexOf('.');
  return dot >= 0 ? base.substring(dot + 1).toLowerCase() : '';
}

String _decodeText(List<int> bytes) {
  // 先按 UTF-8；失败再按 GBK 不现实（Dart 没内置），退回 latin1 也比抛错好。
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

bool _looksReadable(String s) {
  if (s.trim().length < 20) return false;
  int control = 0;
  for (final int c in s.codeUnits.take(2000)) {
    if (c < 9 || (c > 13 && c < 32)) control++;
  }
  return control / (s.length.clamp(1, 2000)) < 0.02;
}

/// HTML → 纯文本（保留段落/列表结构，去掉脚本与样式）。
String htmlToPlainText(String html) {
  String s = html
      .replaceAll(
        RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<!--[\s\S]*?-->', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(
          r'</(p|div|li|tr|h[1-6]|section|article|blockquote)>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'<h([1-6])[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = _decodeEntities(s);
  s = s
      .replaceAll(RegExp(r'[ \t\u00A0]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

String _decodeEntities(String s) {
  const Map<String, String> map = <String, String>{
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&mdash;': '—',
    '&hellip;': '…',
  };
  String out = s;
  map.forEach((String k, String v) => out = out.replaceAll(k, v));
  // 数字实体
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (Match m) {
    final int? code = int.tryParse(m.group(1)!);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
  return out;
}

/// CSV / TSV → "表头: 值"的自然语言行。
///
/// 直接把 CSV 扔给 embedding，向量里全是逗号和引号；转成
/// `姓名=张三；年龄=30` 之后，模型和向量都更容易理解每一行在说什么。
String _tabularToText(String text, String delimiter) {
  final List<List<String>> rows = _parseDelimited(text, delimiter);
  if (rows.isEmpty) return '';
  final List<String> headers = rows.first;
  final StringBuffer sb = StringBuffer();
  for (int r = 1; r < rows.length; r++) {
    final List<String> row = rows[r];
    final List<String> parts = <String>[];
    for (int c = 0; c < row.length; c++) {
      final String v = row[c].trim();
      if (v.isEmpty) continue;
      final String h = c < headers.length ? headers[c].trim() : '';
      parts.add(h.isEmpty ? v : '$h=$v');
    }
    if (parts.isEmpty) continue;
    sb.writeln('第 $r 行：${parts.join('；')}');
  }
  // 表头本身也保留：有些查询问的就是"有哪些列"
  return '表头：${headers.join(' | ')}\n\n$sb'.trim();
}

List<List<String>> _parseDelimited(String text, String delimiter) {
  final List<List<String>> rows = <List<String>>[];
  List<String> row = <String>[];
  final StringBuffer cell = StringBuffer();
  bool quoted = false;

  void endCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void endRow() {
    endCell();
    if (row.any((String c) => c.trim().isNotEmpty)) rows.add(row);
    row = <String>[];
  }

  for (int i = 0; i < text.length; i++) {
    final String ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
      continue;
    }
    if (ch == '"') {
      quoted = true;
    } else if (ch == delimiter) {
      endCell();
    } else if (ch == '\n') {
      endRow();
    } else if (ch != '\r') {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

String _docxToText(List<int> bytes) {
  final Archive archive = ZipDecoder().decodeBytes(bytes);
  final ArchiveFile? file = archive.findFile('word/document.xml');
  if (file == null) throw const FormatException('不是有效的 .docx（缺 document.xml）');
  final XmlDocument doc = XmlDocument.parse(
    utf8.decode(file.content, allowMalformed: true),
  );

  final StringBuffer sb = StringBuffer();
  for (final XmlElement p in doc.descendants.whereType<XmlElement>().where(
    (XmlElement e) => e.name.local == 'p',
  )) {
    final String text = p.descendants
        .whereType<XmlElement>()
        .where((XmlElement e) => e.name.local == 't')
        .map((XmlElement e) => e.innerText)
        .join();
    if (text.trim().isEmpty) continue;

    final String style = _attributeByLocal(p, 'val');
    final RegExpMatch? h = RegExp(r'[Hh]eading(\d)').firstMatch(style);
    if (h != null) {
      final int level = int.parse(h.group(1)!).clamp(1, 6);
      sb.writeln('${'#' * level} ${text.trim()}');
    } else {
      sb.writeln(text.trim());
    }
    sb.writeln();
  }
  final String out = sb.toString().trim();
  if (out.isEmpty) throw const FormatException('Word 文档里没有可读文字');
  return out;
}

String _xlsxToText(List<int> bytes) {
  final Archive archive = ZipDecoder().decodeBytes(bytes);

  final List<String> shared = <String>[];
  final ArchiveFile? ss = archive.findFile('xl/sharedStrings.xml');
  if (ss != null) {
    final XmlDocument doc = XmlDocument.parse(
      utf8.decode(ss.content, allowMalformed: true),
    );
    for (final XmlElement si in doc.descendants.whereType<XmlElement>().where(
      (XmlElement e) => e.name.local == 'si',
    )) {
      shared.add(
        si.descendants
            .whereType<XmlElement>()
            .where((XmlElement e) => e.name.local == 't')
            .map((XmlElement e) => e.innerText)
            .join(),
      );
    }
  }

  final List<ArchiveFile> sheets =
      archive.files
          .where(
            (ArchiveFile f) =>
                f.name.startsWith('xl/worksheets/sheet') &&
                f.name.endsWith('.xml'),
          )
          .toList()
        ..sort((ArchiveFile a, ArchiveFile b) => a.name.compareTo(b.name));
  if (sheets.isEmpty) throw const FormatException('Excel 里没有工作表');

  final StringBuffer out = StringBuffer();
  int sheetNo = 0;
  for (final ArchiveFile sheet in sheets) {
    sheetNo++;
    final XmlDocument doc = XmlDocument.parse(
      utf8.decode(sheet.content, allowMalformed: true),
    );
    final List<List<String>> grid = <List<String>>[];
    for (final XmlElement row in doc.descendants.whereType<XmlElement>().where(
      (XmlElement e) => e.name.local == 'row',
    )) {
      final List<String> cells = <String>[];
      for (final XmlElement c in row.descendants.whereType<XmlElement>().where(
        (XmlElement e) => e.name.local == 'c',
      )) {
        // 空单元格在 xlsx 里常常被**整个省略**；按 `r="B2"` 的列号补空位，
        // 否则后面的表头会整体左移，`姓名=30` 这种错位比不解析更糟。
        final int col = _colIndex(_attributeByLocal(c, 'r'));
        final String type = _attributeByLocal(c, 't');
        final String raw = c.descendants
            .whereType<XmlElement>()
            .where((XmlElement e) => e.name.local == 'v')
            .map((XmlElement e) => e.innerText)
            .join();
        final String inline = c.descendants
            .whereType<XmlElement>()
            .where((XmlElement e) => e.name.local == 't')
            .map((XmlElement e) => e.innerText)
            .join();
        String value = inline;
        if (value.isEmpty) {
          if (type == 's') {
            final int? idx = int.tryParse(raw);
            if (idx != null && idx >= 0 && idx < shared.length) {
              value = shared[idx];
            }
          } else {
            value = raw;
          }
        }
        if (col >= 0) {
          while (cells.length < col) {
            cells.add('');
          }
          cells.add(value.trim());
        } else {
          cells.add(value.trim());
        }
      }
      if (cells.any((String v) => v.isNotEmpty)) grid.add(cells);
    }
    if (grid.isEmpty) continue;

    final List<String> headers = grid.first;
    out.writeln('## 工作表 $sheetNo');
    for (int r = 1; r < grid.length; r++) {
      final List<String> parts = <String>[];
      for (int c = 0; c < grid[r].length; c++) {
        final String v = grid[r][c].trim();
        if (v.isEmpty) continue;
        final String h = c < headers.length ? headers[c].trim() : '';
        parts.add(h.isEmpty ? v : '$h=$v');
      }
      if (parts.isNotEmpty) out.writeln('第 ${r + 1} 行：${parts.join('；')}');
    }
    out.writeln();
  }

  final String text = out.toString().trim();
  if (text.isEmpty) throw const FormatException('Excel 里没有可读单元格');
  return text;
}

String _pptxToText(List<int> bytes) {
  final Archive archive = ZipDecoder().decodeBytes(bytes);
  final List<ArchiveFile> slides =
      archive.files
          .where(
            (ArchiveFile f) =>
                RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name),
          )
          .toList()
        ..sort((ArchiveFile a, ArchiveFile b) {
          int numOf(ArchiveFile f) {
            final RegExpMatch? m = RegExp(r'slide(\d+)\.xml$')
                .firstMatch(f.name);
            return int.tryParse(m?.group(1) ?? '') ?? 0;
          }

          return numOf(a).compareTo(numOf(b));
        });
  if (slides.isEmpty) throw const FormatException('PPT 里没有幻灯片');

  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < slides.length; i++) {
    final XmlDocument doc = XmlDocument.parse(
      utf8.decode(slides[i].content, allowMalformed: true),
    );
    final List<String> texts = doc.descendants
        .whereType<XmlElement>()
        .where((XmlElement e) => e.name.local == 't')
        .map((XmlElement e) => e.innerText.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (texts.isEmpty) continue;
    sb.writeln('## 幻灯片 ${i + 1}');
    sb.writeln(texts.join('\n'));
    sb.writeln();
  }
  final String out = sb.toString().trim();
  if (out.isEmpty) throw const FormatException('PPT 里没有可读文字');
  return out;
}

/// 单元格引用（`B2`）→ 列下标（从 0 开始）。拿不到就返回 -1。
int _colIndex(String ref) {
  int n = 0;
  bool any = false;
  for (final int code in ref.toUpperCase().codeUnits) {
    if (code < 65 || code > 90) break;
    n = n * 26 + (code - 64);
    any = true;
  }
  return any ? n - 1 : -1;
}

/// 读取带命名空间属性的本地名（`w:val` → `val`）。
String _attributeByLocal(XmlElement e, String local) {
  for (final XmlAttribute a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return '';
}

/// PDF 文本层抽取（**不做版面重建**）。
///
/// 纯 Dart、无原生依赖：解压 FlateDecode 流，从文本操作符里取出字符串。
/// 扫描件 / 双栏 / CID 字体的 PDF 可能抽不出可用文字 —— 这种情况下
/// 直接报错让用户转成文本或截图 OCR，而不是塞一堆乱码进知识库。
String _pdfToText(List<int> bytes) {
  final String latin = String.fromCharCodes(bytes);
  final RegExp streamRe = RegExp(r'stream\r?\n([\s\S]*?)endstream');
  final StringBuffer text = StringBuffer();

  for (final RegExpMatch m in streamRe.allMatches(latin)) {
    final int dictStart = (m.start - 400).clamp(0, latin.length);
    final String dict = latin.substring(dictStart, m.start);
    List<int> data = latin.substring(m.start, m.end).codeUnits;
    // 去掉 "stream\n" 与 "endstream"
    int from = 0;
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 10) {
        from = i + 1;
        break;
      }
    }
    int to = data.length;
    const String endTag = 'endstream';
    final String tail = String.fromCharCodes(data);
    final int at = tail.lastIndexOf(endTag);
    if (at >= 0) to = at;
    data = data.sublist(from, to);

    if (dict.contains('FlateDecode')) {
      try {
        data = ZLibDecoder().decodeBytes(data);
      } catch (_) {
        continue;
      }
    }
    _extractPdfStrings(String.fromCharCodes(data), text);
  }

  final String out = text
      .toString()
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  // 少于 40 个可读字符基本可以断定是扫描件/字体编码问题
  final int readable = out.runes
      .where((int r) => r >= 32 && r != 0xFFFD)
      .length;
  if (readable < 40) {
    throw const FormatException(
      'PDF 里没有可提取的文本层（可能是扫描件、双栏或字体编码特殊）。'
      '请先转成文本 / Markdown，或截图后作为图片导入走 OCR。',
    );
  }
  return out;
}

void _extractPdfStrings(String content, StringBuffer out) {
  final RegExp tj = RegExp(r'\((?:\\.|[^\\()])*\)\s*Tj');
  final RegExp tjArray = RegExp(r'\[((?:\((?:\\.|[^\\()])*\)|[^\]])*)\]\s*TJ');
  final RegExp strRe = RegExp(r'\((?:\\.|[^\\()])*\)');

  for (final RegExpMatch m in tj.allMatches(content)) {
    final RegExpMatch? s = strRe.firstMatch(m.group(0)!);
    if (s != null) out.writeln(_decodePdfString(s.group(0)!));
  }
  for (final RegExpMatch m in tjArray.allMatches(content)) {
    final StringBuffer line = StringBuffer();
    for (final RegExpMatch s in strRe.allMatches(m.group(1)!)) {
      line.write(_decodePdfString(s.group(0)!));
    }
    if (line.isNotEmpty) out.writeln(line);
  }
}

String _decodePdfString(String withParens) {
  final String s = withParens.substring(1, withParens.length - 1);
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    final String ch = s[i];
    if (ch != r'\') {
      out.write(ch);
      continue;
    }
    if (i + 1 >= s.length) break;
    final String n = s[++i];
    switch (n) {
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 't':
        out.write('\t');
      case 'b':
        out.write('\b');
      case 'f':
        out.write('\f');
      case '(':
      case ')':
      case r'\':
        out.write(n);
      default:
        // 八进制转义 \ddd
        final RegExpMatch? oct = RegExp(r'^[0-7]{1,3}')
            .firstMatch(s.substring(i));
        if (oct != null) {
          out.writeCharCode(int.parse(oct.group(0)!, radix: 8));
          i += oct.group(0)!.length - 1;
        } else {
          out.write(n);
        }
    }
  }
  return out.toString();
}

Future<String> _imageToText(String path) async {
  final TextRecognizer recognizer = TextRecognizer(
    script: TextRecognitionScript.chinese,
  );
  try {
    final RecognizedText result = await recognizer.processImage(
      InputImage.fromFilePath(path),
    );
    final String text = result.text.trim();
    if (text.isEmpty) {
      throw const FormatException('图片里没有识别到文字');
    }
    return text;
  } finally {
    await recognizer.close();
  }
}
