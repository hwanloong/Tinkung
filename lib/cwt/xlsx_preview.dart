import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Excel 预览里的一个单元格。
class XlsxCell {
  const XlsxCell({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.align = 'l',
    this.colorArgb = 0xFF16211D,
    this.fillArgb,
    this.fontSize,
    this.colSpan = 1,
    this.rowSpan = 1,
  });

  final String text;
  final bool bold;
  final bool italic;
  final String align;
  final int colorArgb;
  final int? fillArgb;
  final double? fontSize;
  final int colSpan;
  final int rowSpan;

  bool get isEmpty => text.trim().isEmpty && fillArgb == null;
}

class XlsxSheet {
  const XlsxSheet({
    required this.name,
    required this.rows,
    required this.colWidths,
    required this.rowHeights,
    required this.truncated,
  });

  final String name;

  /// 矩形数据（缺失的格子是 null）。
  final List<List<XlsxCell?>> rows;

  /// 每列宽度（逻辑像素）。
  final List<double> colWidths;

  /// 每行高度（逻辑像素）。
  final List<double> rowHeights;

  final bool truncated;

  int get colCount => colWidths.length;
  int get rowCount => rows.length;
}

/// 解析 `.xlsx`：工作表、单元格文本、合并、列宽行高、基本样式。
///
/// 目标不是"能算出公式"，而是**看起来像那张表**：
/// 行列位置、列宽、单元格底色、粗体、对齐、数字格式（日期/百分比）。
/// 公式单元格取的是 Excel 存下来的缓存值（`v`）。
List<XlsxSheet> parseXlsxPreview(String path) {
  final Archive archive = ZipDecoder().decodeBytes(
    File(path).readAsBytesSync(),
  );

  final List<String> shared = _sharedStrings(archive);
  final _Styles styles = _Styles.parse(archive);

  final List<_SheetRef> refs = _sheetRefs(archive);
  if (refs.isEmpty) {
    throw const FormatException('Excel 文件里没有工作表');
  }

  final List<XlsxSheet> out = <XlsxSheet>[];
  for (final _SheetRef ref in refs.take(20)) {
    final ArchiveFile? f = archive.findFile(ref.path);
    if (f == null) continue;
    out.add(
      _parseSheet(
        name: ref.name,
        bytes: f.content,
        shared: shared,
        styles: styles,
      ),
    );
  }
  if (out.isEmpty) throw const FormatException('Excel 文件里没有可预览的内容');
  return out;
}

class _SheetRef {
  const _SheetRef(this.name, this.path);

  final String name;
  final String path;
}

List<_SheetRef> _sheetRefs(Archive archive) {
  final ArchiveFile? wb = archive.findFile('xl/workbook.xml');
  final Map<String, String> rels = _parseRels(
    archive,
    'xl/_rels/workbook.xml.rels',
  );
  final List<_SheetRef> out = <_SheetRef>[];
  if (wb != null) {
    final XmlDocument doc = XmlDocument.parse(
      utf8.decode(wb.content, allowMalformed: true),
    );
    for (final XmlElement e in doc.descendants.whereType<XmlElement>()) {
      if (e.name.local != 'sheet') continue;
      final String name = _attr(e, 'name');
      String id = '';
      for (final XmlAttribute a in e.attributes) {
        if (a.name.local == 'id') {
          id = a.value;
          break;
        }
      }
      final String? target = rels[id];
      if (target == null) continue;
      out.add(_SheetRef(name.isEmpty ? '工作表' : name, _resolve('xl', target)));
    }
  }
  if (out.isEmpty) {
    final List<ArchiveFile> files =
        archive.files
            .where(
              (ArchiveFile f) =>
                  RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name),
            )
            .toList()
          ..sort((ArchiveFile a, ArchiveFile b) {
            int n(ArchiveFile f) =>
                int.tryParse(
                  RegExp(r'(\d+)').firstMatch(f.name)?.group(1) ?? '',
                ) ??
                0;
            return n(a).compareTo(n(b));
          });
    for (int i = 0; i < files.length; i++) {
      out.add(_SheetRef('工作表 ${i + 1}', files[i].name));
    }
  }
  return out;
}

XlsxSheet _parseSheet({
  required String name,
  required List<int> bytes,
  required List<String> shared,
  required _Styles styles,
}) {
  final XmlDocument doc = XmlDocument.parse(
    utf8.decode(bytes, allowMalformed: true),
  );

  const int maxRows = 400;
  const int maxCols = 40;

  // ---- 列宽 ----
  final Map<int, double> widthByCol = <int, double>{};
  double defaultWidth = 8.43;
  final XmlElement? format = _descFirst(doc.rootElement, 'sheetFormatPr');
  if (format != null) {
    final double? w = double.tryParse(_attr(format, 'defaultColWidth'));
    if (w != null && w > 0) defaultWidth = w;
    final double? cw = double.tryParse(_attr(format, 'defaultColWidth'));
    if (cw != null) defaultWidth = cw;
  }
  for (final XmlElement col in doc.descendants.whereType<XmlElement>()) {
    if (col.name.local != 'col') continue;
    final int min = int.tryParse(_attr(col, 'min')) ?? 0;
    final int max = int.tryParse(_attr(col, 'max')) ?? 0;
    final double w = double.tryParse(_attr(col, 'width')) ?? defaultWidth;
    if (min <= 0 || max < min) continue;
    for (int i = min; i <= max && i <= maxCols; i++) {
      widthByCol[i - 1] = _colPx(w);
    }
  }

  // ---- 行与单元格 ----
  final Map<int, Map<int, XlsxCell>> grid = <int, Map<int, XlsxCell>>{};
  final Map<int, double> heightByRow = <int, double>{};
  int maxRow = 0;
  int maxCol = 0;
  bool truncated = false;

  final XmlElement? sheetData = _descFirst(doc.rootElement, 'sheetData');
  int implicitRow = 0;
  for (final XmlElement row in _children(sheetData, 'row')) {
    implicitRow++;
    final int r = int.tryParse(_attr(row, 'r')) ?? implicitRow;
    if (r > maxRows) {
      truncated = true;
      break;
    }
    final double? ht = double.tryParse(_attr(row, 'ht'));
    if (ht != null && ht > 0) heightByRow[r - 1] = _rowPx(ht);

    int implicitCol = -1;
    for (final XmlElement c in _children(row, 'c')) {
      final String ref = _attr(c, 'r');
      int col;
      if (ref.isEmpty) {
        col = implicitCol + 1;
      } else {
        col = _colIndex(ref);
      }
      implicitCol = col;
      if (col < 0 || col >= maxCols) {
        if (col >= maxCols) truncated = true;
        continue;
      }
      if (r > maxRow) maxRow = r;
      if (col + 1 > maxCol) maxCol = col + 1;

      final int styleIdx = int.tryParse(_attr(c, 's')) ?? 0;
      final _CellStyle st = styles.style(styleIdx);
      final String type = _attr(c, 't');
      String text;
      if (type == 'inlineStr') {
        text = _textOf(_descFirst(c, 'is'));
      } else {
        final String v = _textOf(_child(c, 'v'));
        text = switch (type) {
          's' =>
            int.tryParse(v) != null && int.parse(v) < shared.length
                ? shared[int.parse(v)]
                : v,
          'b' => v == '1' ? 'TRUE' : 'FALSE',
          'e' => v.isEmpty ? '#N/A' : v,
          'str' => v,
          _ => _formatNumber(v, st.numFmt),
        };
      }
      grid.putIfAbsent(r - 1, () => <int, XlsxCell>{})[col] = XlsxCell(
        text: text,
        bold: st.bold,
        italic: st.italic,
        align: st.align,
        colorArgb: st.colorArgb,
        fillArgb: st.fillArgb,
        fontSize: st.fontSize,
      );
    }
  }

  // ---- 合并单元格 ----
  for (final XmlElement mc in doc.descendants.whereType<XmlElement>()) {
    if (mc.name.local != 'mergeCell') continue;
    final String ref = _attr(mc, 'ref');
    final List<String> parts = ref.split(':');
    if (parts.length != 2) continue;
    final int c1 = _colIndex(parts[0]);
    final int r1 = _rowIndex(parts[0]);
    final int c2 = _colIndex(parts[1]);
    final int r2 = _rowIndex(parts[1]);
    if (c1 < 0 || r1 < 0 || c2 < c1 || r2 < r1) continue;
    if (r1 >= maxRows || c2 >= maxCols) continue;
    final XlsxCell? start = grid[r1]?[c1];
    final int cs = (c2 - c1 + 1).clamp(1, maxCols);
    final int rs = (r2 - r1 + 1).clamp(1, maxRows);
    grid[r1]![c1] = XlsxCell(
      text: start?.text ?? '',
      bold: start?.bold ?? false,
      italic: start?.italic ?? false,
      align: start?.align ?? 'l',
      colorArgb: start?.colorArgb ?? 0xFF16211D,
      fillArgb: start?.fillArgb,
      fontSize: start?.fontSize,
      colSpan: cs,
      rowSpan: rs,
    );
    for (int r = r1; r <= r2 && r < maxRows; r++) {
      for (int c = c1; c <= c2 && c < maxCols; c++) {
        if (r == r1 && c == c1) continue;
        grid[r] ??= <int, XlsxCell>{};
        grid[r]![c] = const XlsxCell(text: '', colSpan: 0, rowSpan: 0);
      }
    }
    if (r2 + 1 > maxRow) maxRow = r2 + 1;
    if (c2 + 1 > maxCol) maxCol = c2 + 1;
  }

  final int rowCount = maxRow.clamp(1, maxRows);
  final int colCount = maxCol.clamp(1, maxCols);

  final List<double> colWidths = <double>[
    for (int i = 0; i < colCount; i++) widthByCol[i] ?? _colPx(defaultWidth),
  ];
  final List<double> rowHeights = <double>[
    for (int i = 0; i < rowCount; i++) heightByRow[i] ?? 26,
  ];
  final List<List<XlsxCell?>> rows = <List<XlsxCell?>>[
    for (int r = 0; r < rowCount; r++)
      <XlsxCell?>[
        for (int c = 0; c < colCount; c++)
          grid[r]?[c] == null || (grid[r]![c]!.colSpan == 0)
              ? null
              : grid[r]![c],
      ],
  ];

  return XlsxSheet(
    name: name,
    rows: rows,
    colWidths: colWidths,
    rowHeights: rowHeights,
    truncated: truncated,
  );
}

List<String> _sharedStrings(Archive archive) {
  final ArchiveFile? f = archive.findFile('xl/sharedStrings.xml');
  if (f == null) return <String>[];
  final XmlDocument doc = XmlDocument.parse(
    utf8.decode(f.content, allowMalformed: true),
  );
  final List<String> out = <String>[];
  for (final XmlElement si in doc.descendants.whereType<XmlElement>()) {
    if (si.name.local != 'si') continue;
    final StringBuffer sb = StringBuffer();
    for (final XmlElement t in si.descendants.whereType<XmlElement>()) {
      if (t.name.local != 't') continue;
      // 跳过拼音注音（rPh 里的 t 不是正文）
      bool phonetic = false;
      for (
        XmlElement? p = t.parentElement;
        p != null && p != si;
        p = p.parentElement
      ) {
        if (p.name.local == 'rPh') {
          phonetic = true;
          break;
        }
      }
      if (phonetic) continue;
      sb.write(t.innerText);
    }
    out.add(sb.toString());
  }
  return out;
}

class _CellStyle {
  const _CellStyle({
    this.bold = false,
    this.italic = false,
    this.align = 'l',
    this.colorArgb = 0xFF16211D,
    this.fillArgb,
    this.fontSize,
    this.numFmt = 0,
  });

  final bool bold;
  final bool italic;
  final String align;
  final int colorArgb;
  final int? fillArgb;
  final double? fontSize;
  final int numFmt;
}

class _Styles {
  _Styles(this._xfs);

  final List<_CellStyle> _xfs;

  static const _CellStyle _fallback = _CellStyle();

  _CellStyle style(int i) => i >= 0 && i < _xfs.length ? _xfs[i] : _fallback;

  static _Styles parse(Archive archive) {
    final ArchiveFile? f = archive.findFile('xl/styles.xml');
    if (f == null) return _Styles(<_CellStyle>[_fallback]);
    final XmlDocument doc = XmlDocument.parse(
      utf8.decode(f.content, allowMalformed: true),
    );

    // 自定义数字格式
    final Map<int, String> formats = <int, String>{};
    for (final XmlElement e in doc.descendants.whereType<XmlElement>()) {
      if (e.name.local != 'numFmt') continue;
      final int id = int.tryParse(_attr(e, 'numFmtId')) ?? -1;
      final String code = _attr(e, 'formatCode');
      if (id >= 0) formats[id] = code;
    }

    // 字体
    final List<_FontStyle> fonts = <_FontStyle>[];
    final XmlElement? fontsEl = _descFirst(doc.rootElement, 'fonts');
    for (final XmlElement fnt in _children(fontsEl, 'font')) {
      bool bold = false;
      bool italic = false;
      double? size;
      int color = 0xFF16211D;
      final XmlElement? b = _child(fnt, 'b');
      if (b != null) {
        final String v = _attr(b, 'val');
        bold = v.isEmpty || (v != '0' && v != 'false');
      }
      final XmlElement? i = _child(fnt, 'i');
      if (i != null) {
        final String v = _attr(i, 'val');
        italic = v.isEmpty || (v != '0' && v != 'false');
      }
      final double? sz = double.tryParse(_attr(_child(fnt, 'sz'), 'val'));
      if (sz != null) size = sz;
      final int? c = _rgb(_child(fnt, 'color'));
      if (c != null) color = c;
      fonts.add(_FontStyle(bold, italic, size, color));
    }

    // 填充（Excel 里前两个通常是 none / gray125，照样按顺序入表）
    final List<int?> fills = <int?>[];
    final XmlElement? fillsEl = _descFirst(doc.rootElement, 'fills');
    for (final XmlElement fill in _children(fillsEl, 'fill')) {
      final XmlElement? pf = _child(fill, 'patternFill');
      fills.add(pf == null ? null : _rgb(_child(pf, 'fgColor')));
    }

    // cellXfs
    final List<_CellStyle> xfs = <_CellStyle>[];
    final XmlElement? xfsEl = _descFirst(doc.rootElement, 'cellXfs');
    for (final XmlElement xf in _children(xfsEl, 'xf')) {
      final int fontId = int.tryParse(_attr(xf, 'fontId')) ?? 0;
      final int fillId = int.tryParse(_attr(xf, 'fillId')) ?? 0;
      final int numFmtId = int.tryParse(_attr(xf, 'numFmtId')) ?? 0;
      final _FontStyle font = fontId >= 0 && fontId < fonts.length
          ? fonts[fontId]
          : const _FontStyle(false, false, null, 0xFF16211D);
      String align = 'l';
      final XmlElement? alignment = _child(xf, 'alignment');
      if (alignment != null) {
        final String h = _attr(alignment, 'horizontal');
        if (h == 'center' || h == 'centerContinuous') align = 'ctr';
        if (h == 'right') align = 'r';
        if (h == 'justify') align = 'just';
      }
      final int? fill = fillId >= 0 && fillId < fills.length
          ? fills[fillId]
          : null;
      xfs.add(
        _CellStyle(
          bold: font.bold,
          italic: font.italic,
          align: align,
          colorArgb: font.color,
          fillArgb: fill,
          fontSize: font.size,
          numFmt: numFmtId,
        ),
      );
    }
    return _Styles(xfs.isEmpty ? <_CellStyle>[_fallback] : xfs);
  }
}

class _FontStyle {
  const _FontStyle(this.bold, this.italic, this.size, this.color);

  final bool bold;
  final bool italic;
  final double? size;
  final int color;
}

String _formatNumber(String raw, int fmt) {
  final double? v = double.tryParse(raw);
  if (v == null) return raw;

  final bool isDate = (fmt >= 14 && fmt <= 22) || (fmt >= 45 && fmt <= 47);
  if (isDate) {
    final DateTime d = DateTime(
      1899,
      12,
      30,
    ).add(Duration(milliseconds: (v * 86400000).round()));
    if (v < 1 && fmt >= 18) {
      return '${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
  if (fmt == 9 || fmt == 10) {
    return '${(v * 100).toStringAsFixed(0)}%';
  }
  if (fmt == 0 || fmt == 1) return _trimNumber(v);
  if (fmt == 2) return v.toStringAsFixed(2);
  if (fmt == 3) return v.toStringAsFixed(0);
  if (fmt == 4) return v.toStringAsFixed(2);
  if (fmt == 49) return '@';
  return _trimNumber(v);
}

String _trimNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) {
    return v.toInt().toString();
  }
  return v.toString();
}

double _colPx(double chars) => (chars * 7 + 6).clamp(36, 260);

double _rowPx(double points) => (points * 96 / 72).clamp(24, 120);

int _colIndex(String ref) {
  int col = 0;
  for (int i = 0; i < ref.length; i++) {
    final int c = ref.codeUnitAt(i);
    if (c >= 65 && c <= 90) {
      col = col * 26 + (c - 64);
    } else if (c >= 97 && c <= 122) {
      col = col * 26 + (c - 96);
    } else {
      break;
    }
  }
  return col - 1;
}

int _rowIndex(String ref) {
  final RegExpMatch? m = RegExp(r'(\d+)$').firstMatch(ref);
  return m == null ? -1 : (int.tryParse(m.group(1)!) ?? 1) - 1;
}

int? _rgb(XmlElement? color) {
  if (color == null) return null;
  String v = _attr(color, 'rgb');
  if (v.isEmpty) return null;
  if (v.length == 8) v = v.substring(2);
  if (v.length != 6) return null;
  final int? c = int.tryParse(v, radix: 16);
  return c == null ? null : 0xFF000000 | c;
}

String _textOf(XmlElement? e) {
  if (e == null) return '';
  final StringBuffer sb = StringBuffer();
  for (final XmlElement t in e.descendants.whereType<XmlElement>()) {
    if (t.name.local == 't') sb.write(t.innerText);
  }
  if (sb.isEmpty) sb.write(e.innerText);
  return sb.toString();
}

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
