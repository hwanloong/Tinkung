import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Word 预览里的一段文字（保留粗体/斜体/下划线/字号/颜色）。
class DocxRun {
  const DocxRun({
    required this.text,
    required this.size,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.colorArgb = 0xFF16211D,
  });

  final String text;
  final double size;
  final bool bold;
  final bool italic;
  final bool underline;
  final int colorArgb;

  DocxRun withText(String t) => DocxRun(
    text: t,
    size: size,
    bold: bold,
    italic: italic,
    underline: underline,
    colorArgb: colorArgb,
  );
}

sealed class DocxBlock {
  const DocxBlock();

  /// 估算占几行，用来分页。
  int get lines;
}

class DocxParagraph extends DocxBlock {
  const DocxParagraph({
    required this.runs,
    this.align = 'l',
    this.size = 13,
    this.bullet = false,
    this.heading = 0,
  });

  final List<DocxRun> runs;
  final String align;

  /// 这段的基础字号（pt）。
  final double size;
  final bool bullet;

  /// 1–6，0 = 正文。
  final int heading;

  String get text => runs.map((DocxRun r) => r.text).join();

  @override
  int get lines {
    final int chars = text.length;
    final int perLine = heading > 0 ? 24 : 34;
    return ((chars / perLine).ceil() * (heading > 0 ? 1.4 : 1)).ceil().clamp(
      1,
      40,
    );
  }
}

class DocxImageBlock extends DocxBlock {
  const DocxImageBlock({required this.bytes, required this.aspect});

  final Uint8List bytes;

  /// 宽 / 高。
  final double aspect;

  @override
  int get lines => 7; // 约 140px，包括上下留白
}

class DocxTableBlock extends DocxBlock {
  const DocxTableBlock({
    required this.rows,
    this.header = true,
    this.fontSize = 11,
  });

  final List<List<String>> rows;
  final bool header;
  final double fontSize;

  @override
  int get lines => (rows.length * 1.2).ceil().clamp(2, 18);
}

/// 显式分页符。
class DocxBreakBlock extends DocxBlock {
  const DocxBreakBlock();

  @override
  int get lines => 0;
}

class DocxPage {
  const DocxPage({required this.blocks});

  final List<DocxBlock> blocks;
}

/// 解析 `.docx` 成**可渲染的页面**：段落、图片、表格、分页符。
///
/// 和"抽成纯文本"不同，这里保留表现信息：标题层级、粗斜体、字号、颜色、
/// 对齐、项目符号、表格边框、内嵌图片。排版按行数估算分页，每页保证
/// 能放进 460 高的预览框，框选时不会因为滚动错位。
List<DocxPage> parseDocxPreview(String path) {
  final Archive archive = ZipDecoder().decodeBytes(
    File(path).readAsBytesSync(),
  );
  final ArchiveFile? file = archive.findFile('word/document.xml');
  if (file == null) {
    throw const FormatException('不是有效的 .docx：缺 word/document.xml');
  }
  final Map<String, String> rels = _parseRels(
    archive,
    'word/_rels/document.xml.rels',
  );
  final XmlDocument doc = XmlDocument.parse(
    utf8.decode(file.content, allowMalformed: true),
  );
  final XmlElement? body = _descFirst(doc.rootElement, 'body');
  if (body == null) throw const FormatException('Word 文档没有正文');

  final List<DocxBlock> blocks = <DocxBlock>[];
  _collectBody(body, archive, rels, blocks);
  if (blocks.isEmpty) {
    throw const FormatException('Word 文档没有可预览的内容');
  }

  // ---- 分页：按估算行数 ----
  const int budget = 21;
  final List<DocxPage> pages = <DocxPage>[];
  List<DocxBlock> current = <DocxBlock>[];
  int used = 0;
  void flush() {
    if (current.isEmpty) return;
    pages.add(DocxPage(blocks: List<DocxBlock>.from(current)));
    current = <DocxBlock>[];
    used = 0;
  }

  for (final DocxBlock b in blocks) {
    if (b is DocxBreakBlock) {
      flush();
      continue;
    }
    final int need = b.lines;
    if (current.isNotEmpty && used + need > budget) flush();
    current.add(b);
    used += need;
    if (pages.length >= 80) break;
  }
  flush();
  if (pages.isEmpty) pages.add(const DocxPage(blocks: <DocxBlock>[]));
  return pages;
}

void _collectBody(
  XmlElement parent,
  Archive archive,
  Map<String, String> rels,
  List<DocxBlock> out,
) {
  for (final XmlElement el in parent.children.whereType<XmlElement>()) {
    switch (el.name.local) {
      case 'p':
        _collectParagraph(el, archive, rels, out);
      case 'tbl':
        final DocxTableBlock? t = _table(el, archive, rels);
        if (t != null) out.add(t);
      case 'sdt':
        final XmlElement? content = _descFirst(el, 'sdtContent');
        if (content != null) _collectBody(content, archive, rels, out);
      default:
        final XmlElement? nested = _descFirst(el, 'sdtContent');
        if (nested != null) _collectBody(nested, archive, rels, out);
    }
  }
}

/// 一个 `w:p` 可能同时包含文字和图片：按出现顺序拆成多个 block。
void _collectParagraph(
  XmlElement p,
  Archive archive,
  Map<String, String> rels,
  List<DocxBlock> out,
) {
  final XmlElement? pPr = _child(p, 'pPr');
  final String styleId = _attr(_child(pPr, 'pStyle'), 'val');
  final int heading = _headingLevel(styleId);

  String align = 'l';
  final String jc = _attr(_child(pPr, 'jc'), 'val');
  if (jc == 'center') align = 'ctr';
  if (jc == 'right' || jc == 'end') align = 'r';
  if (jc == 'both' || jc == 'justify') align = 'just';

  final bool bullet = _child(pPr, 'numPr') != null;

  final List<DocxRun> pending = <DocxRun>[];
  bool breakAfter = false;

  void flushRuns() {
    if (pending.isEmpty) return;
    final List<DocxRun> merged = <DocxRun>[];
    for (final DocxRun r in pending) {
      if (r.text.isEmpty) continue;
      if (merged.isNotEmpty && _sameStyle(merged.last, r)) {
        merged[merged.length - 1] = merged.last.withText(
          merged.last.text + r.text,
        );
      } else {
        merged.add(r);
      }
    }
    pending.clear();
    if (merged.isEmpty) return;
    final double size = merged
        .map((DocxRun r) => r.size)
        .reduce((double a, double b) => a > b ? a : b);
    out.add(
      DocxParagraph(
        runs: merged,
        align: align,
        size: size,
        bullet: bullet,
        heading: heading,
      ),
    );
  }

  void visit(XmlElement el) {
    for (final XmlElement child in el.children.whereType<XmlElement>()) {
      switch (child.name.local) {
        case 'r':
          _visitRun(
            child,
            archive,
            rels,
            pending,
            heading,
            (bool page) {
              if (page) breakAfter = true;
            },
            () => flushRuns(),
            (DocxImageBlock img) {
              flushRuns();
              out.add(img);
            },
          );
        case 'hyperlink':
        case 'ins':
          visit(child);
        case 'sdt':
          final XmlElement? content = _descFirst(child, 'sdtContent');
          if (content != null) visit(content);
        case 't':
          final String t = child.innerText;
          if (t.isNotEmpty) {
            pending.add(_runStyle(child, null, heading).withText(t));
          }
        case 'tab':
          pending.add(_runStyle(child, null, heading).withText('    '));
        case 'br':
          if (_attr(child, 'type') == 'page') {
            breakAfter = true;
          } else {
            pending.add(_runStyle(child, null, heading).withText('\n'));
          }
        default:
          break;
      }
    }
  }

  visit(p);
  flushRuns();
  if (breakAfter) out.add(const DocxBreakBlock());
}

void _visitRun(
  XmlElement run,
  Archive archive,
  Map<String, String> rels,
  List<DocxRun> pending,
  int heading,
  void Function(bool page) onPageBreak,
  void Function() flush,
  void Function(DocxImageBlock image) onImage,
) {
  for (final XmlElement child in run.children.whereType<XmlElement>()) {
    switch (child.name.local) {
      case 't':
        final String t = child.innerText;
        if (t.isEmpty) continue;
        pending.add(_runStyle(child, run, heading).withText(t));
      case 'tab':
        pending.add(_runStyle(child, run, heading).withText('    '));
      case 'br':
        if (_attr(child, 'type') == 'page') {
          onPageBreak(true);
        } else {
          pending.add(_runStyle(child, run, heading).withText('\n'));
        }
      case 'drawing':
      case 'pict':
        final DocxImageBlock? img = _image(child, archive, rels);
        if (img != null) onImage(img);
      default:
        break;
    }
  }
}

DocxRun _runStyle(XmlElement node, XmlElement? run, int heading) {
  final XmlElement? rPr =
      (run == null ? null : _child(run, 'rPr')) ??
      _child(node, 'rPr') ??
      (run == null ? null : _descFirst(run, 'rPr'));
  bool bold = heading > 0;
  bool italic = false;
  bool underline = false;
  double size = switch (heading) {
    1 => 22,
    2 => 18,
    3 => 15.5,
    _ => 13,
  };
  int color = 0xFF16211D;
  if (rPr != null) {
    if (_flag(rPr, 'b')) bold = true;
    if (_flag(rPr, 'i')) italic = true;
    if (_flag(rPr, 'u')) underline = true;
    final double? half = double.tryParse(_attr(_child(rPr, 'sz'), 'val'));
    if (half != null) size = half / 2;
    final String c = _attr(_child(rPr, 'color'), 'val');
    if (c.length == 6) {
      final int? v = int.tryParse(c, radix: 16);
      if (v != null) color = 0xFF000000 | v;
    }
  }
  return DocxRun(
    text: '',
    size: size.clamp(8, 40),
    bold: bold,
    italic: italic,
    underline: underline,
    colorArgb: color,
  );
}

DocxTableBlock? _table(
  XmlElement tbl,
  Archive archive,
  Map<String, String> rels,
) {
  final List<List<String>> rows = <List<String>>[];
  bool header = false;
  for (final XmlElement tr in _children(tbl, 'tr')) {
    final XmlElement? trPr = _child(tr, 'trPr');
    if (_child(trPr, 'tblHeader') != null) header = true;
    final List<String> cells = <String>[];
    for (final XmlElement tc in _children(tr, 'tc')) {
      final StringBuffer sb = StringBuffer();
      for (final XmlElement p in _children(tc, 'p')) {
        final String t = _paragraphText(p);
        if (t.isEmpty) continue;
        if (sb.isNotEmpty) sb.write('\n');
        sb.write(t);
      }
      cells.add(sb.toString());
    }
    if (cells.isNotEmpty) rows.add(cells);
    if (rows.length >= 40) break;
  }
  if (rows.isEmpty) return null;
  return DocxTableBlock(rows: rows, header: header);
}

String _paragraphText(XmlElement p) {
  final StringBuffer sb = StringBuffer();
  for (final XmlElement c in p.descendants.whereType<XmlElement>()) {
    if (c.name.local == 't') sb.write(c.innerText);
    if (c.name.local == 'tab') sb.write(' ');
    if (c.name.local == 'br') sb.write('\n');
  }
  return sb.toString().trim();
}

DocxImageBlock? _image(
  XmlElement node,
  Archive archive,
  Map<String, String> rels,
) {
  String id = '';
  for (final XmlElement e in node.descendants.whereType<XmlElement>()) {
    if (e.name.local == 'blip' || e.name.local == 'imagedata') {
      for (final XmlAttribute a in e.attributes) {
        if (a.name.local == 'embed' || a.name.local == 'id') {
          id = a.value;
          break;
        }
      }
      if (id.isNotEmpty) break;
    }
  }
  if (id.isEmpty) return null;
  final String? target = rels[id];
  if (target == null) return null;
  final String path = _resolve('word', target);
  final ArchiveFile? f = archive.findFile(path);
  if (f == null) return null;
  final String lower = path.toLowerCase();
  if (lower.endsWith('.emf') ||
      lower.endsWith('.wmf') ||
      lower.endsWith('.tif') ||
      lower.endsWith('.tiff')) {
    return null;
  }

  double aspect = 1.6;
  for (final XmlElement e in node.descendants.whereType<XmlElement>()) {
    if (e.name.local != 'extent') continue;
    final double cx = double.tryParse(_attr(e, 'cx')) ?? 0;
    final double cy = double.tryParse(_attr(e, 'cy')) ?? 0;
    if (cx > 0 && cy > 0) {
      aspect = (cx / cy).clamp(0.2, 8);
      break;
    }
  }
  return DocxImageBlock(bytes: Uint8List.fromList(f.content), aspect: aspect);
}

int _headingLevel(String style) {
  final String s = style.toLowerCase();
  if (s.isEmpty) return 0;
  if (s.contains('title')) return 1;
  final RegExpMatch? m = RegExp(r'heading\s*(\d)').firstMatch(s);
  if (m != null) return int.tryParse(m.group(1) ?? '') ?? 0;
  if (RegExp(r'^h[1-6]$').hasMatch(s)) {
    return int.tryParse(s.substring(1)) ?? 0;
  }
  return 0;
}

bool _flag(XmlElement parent, String local) {
  final XmlElement? e = _child(parent, local);
  if (e == null) return false;
  final String v = _attr(e, 'val').toLowerCase();
  return v != '0' && v != 'false' && v != 'none';
}

bool _sameStyle(DocxRun a, DocxRun b) =>
    a.size == b.size &&
    a.bold == b.bold &&
    a.italic == b.italic &&
    a.underline == b.underline &&
    a.colorArgb == b.colorArgb;

String _resolve(String dir, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final List<String> parts = <String>[...dir.split('/'), ...target.split('/')];
  final List<String> out = <String>[];
  for (final String p in parts) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(p);
  }
  return out.join('/');
}

Map<String, String> _parseRels(Archive archive, String path) {
  final ArchiveFile? f = archive.findFile(path);
  if (f == null) return <String, String>{};
  final XmlDocument doc = XmlDocument.parse(
    utf8.decode(f.content, allowMalformed: true),
  );
  final Map<String, String> map = <String, String>{};
  for (final XmlElement e in doc.descendants.whereType<XmlElement>()) {
    if (e.name.local != 'Relationship') continue;
    final String id = _attr(e, 'Id');
    final String target = _attr(e, 'Target');
    if (id.isNotEmpty && target.isNotEmpty) map[id] = target;
  }
  return map;
}

XmlElement? _child(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final XmlElement e in parent.children.whereType<XmlElement>()) {
    if (e.name.local == local) return e;
  }
  return null;
}

List<XmlElement> _children(XmlElement? parent, String local) {
  if (parent == null) return <XmlElement>[];
  return parent.children
      .whereType<XmlElement>()
      .where((XmlElement e) => e.name.local == local)
      .toList();
}

XmlElement? _descFirst(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final XmlElement e in parent.descendants.whereType<XmlElement>()) {
    if (e.name.local == local) return e;
  }
  return null;
}

String _attr(XmlElement? e, String local) {
  if (e == null) return '';
  for (final XmlAttribute a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return '';
}
