import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

/// PPTX 预览里的一段文字（同一形状里的不同 run 可以有不同的字号/颜色）。
class PptxRun {
  const PptxRun({
    required this.text,
    required this.fontSize,
    this.bold = false,
    this.italic = false,
    this.colorArgb = 0xFF16211D,
  });

  final String text;
  final double fontSize;
  final bool bold;
  final bool italic;
  final int colorArgb;
}

/// 一块带位置的文字（框选/选中原文用）。
class PptxShape {
  const PptxShape({
    required this.rect,
    required this.text,
    required this.fontSize,
    this.bold = false,
    this.italic = false,
    this.colorArgb = 0xFF16211D,
    this.align = 'l',
    this.anchor = 't',
    this.runs = const <PptxRun>[],
    this.insetL = 7,
    this.insetT = 4,
    this.insetR = 7,
    this.insetB = 4,
    this.phType = '',
  });

  /// 归一化坐标（0..1），相对于幻灯片。
  final Rect rect;
  final String text;

  /// 磅值（pt）。
  final double fontSize;
  final bool bold;
  final bool italic;
  final int colorArgb;

  /// `l` / `ctr` / `r` / `just`
  final String align;

  /// `t` / `ctr` / `b`
  final String anchor;

  final List<PptxRun> runs;

  /// 文本框内边距（逻辑像素，按预览尺寸换算）。
  final double insetL;
  final double insetT;
  final double insetR;
  final double insetB;

  /// 占位符类型（title / body / ftr / sldNum…）；普通文本框为空。
  final String phType;
}

/// 一张图片（`p:pic`）。
class PptxImageShape {
  const PptxImageShape({required this.rect, required this.bytes});

  final Rect rect;
  final Uint8List bytes;
}

/// 纯装饰形状：矩形 / 圆角矩形 / 椭圆 / 线条。
class PptxBoxShape {
  const PptxBoxShape({
    required this.rect,
    this.fillArgb,
    this.lineArgb,
    this.ellipse = false,
    this.rounded = false,
    this.lineWidth = 1,
  });

  final Rect rect;
  final int? fillArgb;
  final int? lineArgb;
  final bool ellipse;
  final bool rounded;
  final double lineWidth;
}

/// 表格（`p:graphicFrame/a:tbl`）。
class PptxTableShape {
  const PptxTableShape({
    required this.rect,
    required this.rows,
    required this.colWidths,
    required this.rowHeights,
    this.fontSize = 12,
    this.headerFillArgb,
  });

  final Rect rect;
  final List<List<String>> rows;

  /// 归一化列宽（合计 1）。
  final List<double> colWidths;

  /// 归一化行高（合计 1）。
  final List<double> rowHeights;

  final double fontSize;
  final int? headerFillArgb;
}

class PptxSlide {
  const PptxSlide({
    required this.widthEmu,
    required this.heightEmu,
    required this.shapes,
    this.nodes = const <Object>[],
    this.backgroundArgb,
    this.backgroundImage,
    this.unsupportedMedia = 0,
  });

  final double widthEmu;
  final double heightEmu;

  /// 文字块（按位置排序，供点选/框选取原文）。
  final List<PptxShape> shapes;

  /// 按 z 序排列的渲染节点：文字 / 图片 / 形状 / 表格。
  final List<Object> nodes;

  final int? backgroundArgb;
  final Uint8List? backgroundImage;

  /// 引用了、但解不出来 / 格式不支持（EMF/WMF/外链）的图片数量。
  /// 大于 0 时预览上会提示，而不是悄悄显示空白。
  final int unsupportedMedia;

  double get aspect => heightEmu <= 0 ? 16 / 9 : widthEmu / heightEmu;
}

/// 解析 `.pptx`：每页幻灯片 + 带位置的文字、图片、形状、表格。
///
/// 这不是像素级渲染（那需要 LibreOffice），但尽量贴近 PowerPoint：
///
///  · 文字：位置来自 `a:xfrm`，字号取 `rPr@sz`，支持粗体/斜体/颜色/对齐/锚点；
///  · 图片：`p:pic` 的 `a:blip r:embed` 从 `ppt/media/` 取出原图，
///    按原始框铺满（`BoxFit.fill`）；
///  · 形状：纯色填充、描边、圆角/椭圆；
///  · 表格：`a:tbl` 的列宽/行高按比例还原；
///  · 背景：幻灯片底色或背景图；
///  · 组合形状：按 `chOff/chExt` 变换子坐标（否则组合里的东西会跑到左上角）。
List<PptxSlide> parsePptxPreview(String path) {
  final Archive archive = ZipDecoder().decodeBytes(
    File(path).readAsBytesSync(),
  );

  double slideW = 12192000; // 16:9 默认
  double slideH = 6858000;
  final ArchiveFile? pres = _findFile(archive, 'ppt/presentation.xml');
  if (pres != null) {
    final XmlDocument doc = XmlDocument.parse(
      utf8.decode(pres.content, allowMalformed: true),
    );
    for (final XmlElement e in doc.descendants.whereType<XmlElement>()) {
      if (e.name.local == 'sldSz') {
        slideW = double.tryParse(_attr(e, 'cx')) ?? slideW;
        slideH = double.tryParse(_attr(e, 'cy')) ?? slideH;
        break;
      }
    }
  }

  final _Theme theme = _parseTheme(archive);

  // 幻灯片顺序以 presentation.xml 的 sldIdLst 为准（在 PowerPoint 里
  // 拖动过顺序时，文件名顺序和实际顺序会不一致）。
  final List<String> ordered = _slideOrder(archive);
  final List<ArchiveFile> files = <ArchiveFile>[];
  if (ordered.isNotEmpty) {
    for (final String path in ordered) {
      final ArchiveFile? f = _findFile(archive, path);
      if (f != null) files.add(f);
    }
  }
  if (files.isEmpty) {
    files.addAll(
      archive.files.where(
        (ArchiveFile f) =>
            RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name),
      ),
    );
  }
  if (ordered.isEmpty) {
    // 没有 presentation.xml 的 sldIdLst 时才按文件名排序
    files.sort((ArchiveFile a, ArchiveFile b) {
      int num(ArchiveFile f) {
        final RegExpMatch? m = RegExp(r'slide(\d+)\.xml$').firstMatch(f.name);
        return int.tryParse(m?.group(1) ?? '') ?? 0;
      }

      return num(a).compareTo(num(b));
    });
  }
  if (files.isEmpty) {
    throw const FormatException('PPT 里没有幻灯片');
  }

  final List<PptxSlide> slides = <PptxSlide>[];
  for (final ArchiveFile f in files) {
    final XmlDocument doc = XmlDocument.parse(
      utf8.decode(f.content, allowMalformed: true),
    );
    final String slideDir = f.name.substring(0, f.name.lastIndexOf('/'));
    final String base = f.name.split('/').last;
    final Map<String, String> rels = _parseRels(
      archive,
      '$slideDir/_rels/$base.rels',
    );

    final List<PptxShape> textShapes = <PptxShape>[];
    final List<Object> nodes = <Object>[];
    final List<String> missingMedia = <String>[];
    int? bg;
    Uint8List? bgImage;

    // 版式（slideLayout）里的占位符位置：幻灯片里没写 xfrm 时用它，
    // 否则"标题/正文"这类占位符会整块丢掉。
    final String? layoutPath = _layoutPath(rels);
    final String? masterPath = layoutPath == null
        ? null
        : _masterPath(archive, layoutPath);
    final Map<String, Rect> layoutRects = layoutPath == null
        ? <String, Rect>{}
        : _layoutRects(archive, layoutPath, slideW, slideH);

    // ---- 背景（幻灯片 → 版式 → 母版） ----
    //
    // 很多模板整页就是一张背景图，文字只是浮在上面；只读幻灯片自己的
    // p:bg 会得到一张白纸 —— 看起来就是"图片显示不出来"。
    final (int?, Uint8List?) own = _backgroundOf(
      archive,
      doc.rootElement,
      slideDir,
      rels,
      theme,
    );
    bg = own.$1;
    bgImage = own.$2;
    for (final String? under in <String?>[layoutPath, masterPath]) {
      if (bg != null || bgImage != null || under == null) continue;
      final XmlElement? root = _rootOf(archive, under);
      if (root == null) continue;
      final String udir = under.substring(0, under.lastIndexOf('/'));
      final String ubase = under.split('/').last;
      final Map<String, String> urels = _parseRels(
        archive,
        '$udir/_rels/$ubase.rels',
      );
      final (int?, Uint8List?) ubg = _backgroundOf(
        archive,
        root,
        udir,
        urels,
        theme,
      );
      bg = ubg.$1;
      bgImage = ubg.$2;
    }

    // ---- 版式 / 母版上的装饰（图片、色块、表格） ----
    //
    // 幻灯片本身常常只有几个文本框，真正的背景图、logo、装饰条都在
    // slideLayout / slideMaster 上。以前只画幻灯片自己的节点，
    // 结果整页"只剩几个字"。这里把它们垫在最底下。
    final Set<String> slidePh = _placeholders(doc.rootElement);
    if (masterPath != null) {
      nodes.addAll(
        _decorationNodes(
          archive,
          masterPath,
          theme,
          slideW,
          slideH,
          const <String>{},
        ),
      );
    }
    if (layoutPath != null) {
      nodes.addAll(
        _decorationNodes(archive, layoutPath, theme, slideW, slideH, slidePh),
      );
    }

    // ---- 形状树 ----
    final XmlElement? tree = _descFirst(doc.rootElement, 'spTree');
    if (tree != null) {
      _collectSlide(
        tree,
        archive: archive,
        dir: slideDir,
        rels: rels,
        theme: theme,
        tx: const _Tx(1, 1, 0, 0),
        slideW: slideW,
        slideH: slideH,
        layoutRects: layoutRects,
        textShapes: textShapes,
        nodes: nodes,
        missingMedia: missingMedia,
      );
    }

    // 没有任何带位置形状（或纯占位页）：至少把文字按行铺开，别显示空白。
    if (textShapes.isEmpty && nodes.isEmpty) {
      final String all = doc.descendants
          .whereType<XmlElement>()
          .where((XmlElement e) => e.name.local == 't')
          .map((XmlElement e) => e.innerText)
          .join('\n')
          .trim();
      if (all.isNotEmpty) {
        final PptxShape fallback = PptxShape(
          rect: const Rect.fromLTWH(0.06, 0.08, 0.88, 0.84),
          text: all,
          fontSize: 18,
          runs: <PptxRun>[PptxRun(text: all, fontSize: 18)],
        );
        textShapes.add(fallback);
        nodes.add(fallback);
      }
    }

    slides.add(
      PptxSlide(
        widthEmu: slideW,
        heightEmu: slideH,
        shapes: textShapes,
        nodes: nodes,
        backgroundArgb: bg,
        backgroundImage: bgImage,
        unsupportedMedia: missingMedia.length,
      ),
    );
  }
  return slides;
}

/// 组合/根容器的坐标变换：把子坐标映射到幻灯片 EMU。
class _Tx {
  const _Tx(this.sx, this.sy, this.dx, this.dy);

  final double sx;
  final double sy;
  final double dx;
  final double dy;

  Offset apply(double x, double y) => Offset(dx + x * sx, dy + y * sy);
}

void _collectSlide(
  XmlElement tree, {
  required Archive archive,
  required String dir,
  required Map<String, String> rels,
  required _Theme theme,
  required _Tx tx,
  required double slideW,
  required double slideH,
  required Map<String, Rect> layoutRects,
  required List<PptxShape> textShapes,
  required List<Object> nodes,
  Set<String> skipPh = const <String>{},
  List<String>? missingMedia,
}) {
  for (final XmlElement el in tree.children.whereType<XmlElement>()) {
    switch (el.name.local) {
      case 'sp':
        _collectSp(
          el,
          archive: archive,
          dir: dir,
          rels: rels,
          theme: theme,
          tx: tx,
          slideW: slideW,
          slideH: slideH,
          layoutRects: layoutRects,
          textShapes: textShapes,
          nodes: nodes,
          skipPh: skipPh,
          missingMedia: missingMedia,
        );
      case 'pic':
        _collectPic(
          el,
          archive: archive,
          dir: dir,
          rels: rels,
          tx: tx,
          slideW: slideW,
          slideH: slideH,
          layoutRects: layoutRects,
          nodes: nodes,
          missingMedia: missingMedia,
        );
      case 'graphicFrame':
        _collectFrame(
          el,
          archive: archive,
          dir: dir,
          rels: rels,
          theme: theme,
          tx: tx,
          slideW: slideW,
          slideH: slideH,
          textShapes: textShapes,
          nodes: nodes,
          missingMedia: missingMedia,
        );
      case 'cxnSp':
        _collectCxn(
          el,
          theme: theme,
          tx: tx,
          slideW: slideW,
          slideH: slideH,
          nodes: nodes,
        );
      case 'AlternateContent':
        // Office 会把图表 / SmartArt / 部分图片包在 mc:AlternateContent 里。
        // 以前直接跳过，整页就只剩标题那几个字。优先取 Choice，没有再取 Fallback。
        final XmlElement? choice =
            _child(el, 'Choice') ?? _child(el, 'Fallback');
        if (choice != null) {
          _collectSlide(
            choice,
            archive: archive,
            dir: dir,
            rels: rels,
            theme: theme,
            tx: tx,
            slideW: slideW,
            slideH: slideH,
            layoutRects: layoutRects,
            textShapes: textShapes,
            nodes: nodes,
            skipPh: skipPh,
            missingMedia: missingMedia,
          );
        }
      case 'grpSp':
        final XmlElement? xfrm = _descFirst(el, 'xfrm');
        final XmlElement? off = xfrm == null ? null : _child(xfrm, 'off');
        final XmlElement? ext = xfrm == null ? null : _child(xfrm, 'ext');
        final XmlElement? chOff = _descFirst(el, 'chOff');
        final XmlElement? chExt = _descFirst(el, 'chExt');
        final double ox = _num(off, 'x', 0);
        final double oy = _num(off, 'y', 0);
        final double ew = _num(ext, 'cx', slideW);
        final double eh = _num(ext, 'cy', slideH);
        final double cx = _num(chOff, 'x', 0);
        final double cy = _num(chOff, 'y', 0);
        final double cw = _num(chExt, 'cx', ew);
        final double ch = _num(chExt, 'cy', eh);
        final double sxc = cw == 0 ? 1 : ew / cw;
        final double syc = ch == 0 ? 1 : eh / ch;
        // 先套父变换，再套组合自己的映射
        final Offset o = tx.apply(ox, oy);
        final _Tx child = _Tx(
          tx.sx * sxc,
          tx.sy * syc,
          o.dx - cx * tx.sx * sxc,
          o.dy - cy * tx.sy * syc,
        );
        _collectSlide(
          el,
          archive: archive,
          dir: dir,
          rels: rels,
          theme: theme,
          tx: child,
          slideW: slideW,
          slideH: slideH,
          layoutRects: layoutRects,
          textShapes: textShapes,
          nodes: nodes,
          skipPh: skipPh,
          missingMedia: missingMedia,
        );
      default:
        break;
    }
  }
}

void _collectSp(
  XmlElement sp, {
  required Archive archive,
  required String dir,
  required Map<String, String> rels,
  required _Theme theme,
  required _Tx tx,
  required double slideW,
  required double slideH,
  required Map<String, Rect> layoutRects,
  required List<PptxShape> textShapes,
  required List<Object> nodes,
  Set<String> skipPh = const <String>{},
  List<String>? missingMedia,
}) {
  final XmlElement? ph = _descFirst(sp, 'ph');
  if (ph != null) {
    final String type = _attr(ph, 'type').isEmpty ? 'body' : _attr(ph, 'type');
    final String idx = _attr(ph, 'idx');
    if (skipPh.contains('$type|$idx') || skipPh.contains('$type|')) return;
  }
  final XmlElement? spPr = _child(sp, 'spPr');
  final XmlElement? xfrm = spPr == null ? null : _child(spPr, 'xfrm');
  Rect? rect = _rectOf(xfrm, tx, slideW, slideH);
  if (rect == null) {
    // 占位符经常不带 xfrm（位置写在版式里）：用版式同类型占位符的框。
    if (ph != null) {
      final String type = _attr(ph, 'type').isEmpty
          ? 'body'
          : _attr(ph, 'type');
      final String idx = _attr(ph, 'idx');
      rect =
          layoutRects['$type|$idx'] ??
          layoutRects['$type|'] ??
          layoutRects['body|$idx'];
    }
  }
  // 没坐标也画：给一个默认框，总比整块内容消失好
  rect ??= const Rect.fromLTWH(0.08, 0.18, 0.84, 0.5);

  final XmlElement? prst = spPr == null ? null : _descFirst(spPr, 'prstGeom');
  final String geom = _attr(prst, 'prst');

  int? fill = _fillOf(spPr, theme);
  int? styleLine;
  final XmlElement? style = _child(sp, 'style');
  if (style != null) {
    if (fill == null) {
      final XmlElement? ref = _child(style, 'fillRef');
      final int idx = int.tryParse(_attr(ref, 'idx')) ?? 0;
      if (idx > 0) fill = _colorOf(ref, theme);
    }
    final XmlElement? lnRef = _child(style, 'lnRef');
    final int lnIdx = int.tryParse(_attr(lnRef, 'idx')) ?? 0;
    if (lnIdx > 0) styleLine = _colorOf(lnRef, theme);
  }

  // 有些"图片"不是 p:pic，而是给形状铺一张图（blipFill）
  Uint8List? shapeImage;
  final XmlElement? blipFill = spPr == null ? null : _child(spPr, 'blipFill');
  if (blipFill != null) {
    final XmlElement? blip = _descFirst(blipFill, 'blip');
    if (blip != null) {
      shapeImage = _imageFor(archive, dir, rels, _embedOf(blip));
      if (shapeImage == null && missingMedia != null) {
        missingMedia.add(_embedOf(blip));
      }
    }
  }

  final XmlElement? ln = spPr == null ? null : _child(spPr, 'ln');
  final int? line =
      (ln == null ? null : _colorOf(_descFirst(ln, 'solidFill'), theme)) ??
      styleLine;
  final double lineW = ln == null ? 1 : _max(0.5, _num(ln, 'w', 12700) / 12700);

  // 图片填充和文字可以同时存在：形状铺一张图，图上面写注释。
  // 以前只在"没有文字"时才画这张图，结果整页只剩几句注释。
  if (shapeImage != null) {
    nodes.add(PptxImageShape(rect: rect, bytes: shapeImage));
  }

  final List<PptxRun> runs = <PptxRun>[];
  String align = 'l';
  String anchor = 't';
  final String phType = ph == null || _attr(ph, 'type').isEmpty
      ? (ph == null ? '' : 'body')
      : _attr(ph, 'type');
  double insetL = 7;
  double insetT = 4;
  double insetR = 7;
  double insetB = 4;
  final XmlElement? txBody = _child(sp, 'txBody');
  if (txBody != null) {
    final XmlElement? bodyPr = _child(txBody, 'bodyPr');
    if (bodyPr != null) {
      anchor = _attr(bodyPr, 'anchor').isEmpty ? 't' : _attr(bodyPr, 'anchor');
      // EMU → 预览逻辑像素（按 96dpi 粗算，再夹在可读范围内）
      final double l = _num(bodyPr, 'lIns', 91440) / 12700 * 96 / 72;
      final double t = _num(bodyPr, 'tIns', 45720) / 12700 * 96 / 72;
      final double r = _num(bodyPr, 'rIns', 91440) / 12700 * 96 / 72;
      final double b = _num(bodyPr, 'bIns', 45720) / 12700 * 96 / 72;
      insetL = l.clamp(0, 24);
      insetT = t.clamp(0, 20);
      insetR = r.clamp(0, 24);
      insetB = b.clamp(0, 20);
    }
    int bulletNum = 0;
    String? firstAlign;
    for (final XmlElement p in _children(txBody, 'p')) {
      final XmlElement? pPr = _child(p, 'pPr');
      if (firstAlign == null && pPr != null) {
        final String a = _attr(pPr, 'algn');
        if (a.isNotEmpty) firstAlign = a;
      }
      String bullet = '';
      if (pPr != null) {
        final XmlElement? bc = _child(pPr, 'buChar');
        if (_attr(bc, 'char').isNotEmpty) bullet = '${_attr(bc, 'char')} ';
        final XmlElement? bn = _child(pPr, 'buAutoNum');
        if (bn != null) {
          bulletNum++;
          bullet = '$bulletNum. ';
        }
        final XmlElement? bl = _child(pPr, 'buNone');
        if (bl != null) bullet = '';
      }
      final double defSize = _defaultTextSize(txBody, p);
      final int defColor = _defaultTextColor(txBody, p, theme);
      if (bullet.isNotEmpty) {
        runs.add(PptxRun(text: bullet, fontSize: defSize, colorArgb: defColor));
      }
      for (final XmlElement child in p.children.whereType<XmlElement>()) {
        if (child.name.local == 'r') {
          final String t = child.descendants
              .whereType<XmlElement>()
              .where((XmlElement e) => e.name.local == 't')
              .map((XmlElement e) => e.innerText)
              .join();
          if (t.isEmpty) continue;
          final XmlElement? rPr = _child(child, 'rPr');
          runs.add(
            _runOf(
              t,
              rPr,
              theme,
              fallbackSize: defSize,
              fallbackColor: defColor,
            ),
          );
        } else if (child.name.local == 'fld') {
          final String t = child.descendants
              .whereType<XmlElement>()
              .where((XmlElement e) => e.name.local == 't')
              .map((XmlElement e) => e.innerText)
              .join();
          if (t.isNotEmpty) {
            runs.add(PptxRun(text: t, fontSize: defSize, colorArgb: defColor));
          }
        } else if (child.name.local == 'br') {
          runs.add(PptxRun(text: '\n', fontSize: defSize));
        }
      }
      runs.add(PptxRun(text: '\n', fontSize: 18));
    }
    if (firstAlign != null) align = firstAlign;
  }

  // 去掉末尾多余换行
  while (runs.isNotEmpty && runs.last.text.trim().isEmpty) {
    runs.removeLast();
  }
  final String text = runs.map((PptxRun r) => r.text).join().trim();

  if (text.isNotEmpty) {
    final double size = runs.isEmpty ? 18 : runs.first.fontSize;
    final PptxShape shape = PptxShape(
      rect: rect,
      text: text,
      fontSize: size.clamp(8, 72),
      bold: _visibleBold(runs),
      italic: runs.isNotEmpty && runs.first.italic,
      colorArgb: runs.isEmpty ? 0xFF16211D : runs.first.colorArgb,
      align: align,
      anchor: anchor,
      runs: runs,
      phType: phType,
      insetL: insetL,
      insetT: insetT,
      insetR: insetR,
      insetB: insetB,
    );
    textShapes.add(shape);
    nodes.add(shape);
  } else if (shapeImage == null && (fill != null || line != null)) {
    // 预设形状远不止矩形/圆/圆角矩形：星形、箭头、标注、线条……
    // 以前只认这三种，模板里的装饰元素几乎全被丢掉。这里统一画出来，
    // 形状差异用圆/圆角/矩形近似 —— 位置和颜色至少是对的。
    nodes.add(
      PptxBoxShape(
        rect: rect,
        fillArgb: fill,
        lineArgb: line,
        ellipse: geom == 'ellipse' || geom == 'oval' || geom == 'circle',
        rounded: geom == 'roundRect' || geom == 'flowChartProcess',
        lineWidth: lineW,
      ),
    );
  }
}

void _collectPic(
  XmlElement pic, {
  required Archive archive,
  required String dir,
  required Map<String, String> rels,
  required _Tx tx,
  required double slideW,
  required double slideH,
  required Map<String, Rect> layoutRects,
  required List<Object> nodes,
  Set<String> skipPh = const <String>{},
  List<String>? missingMedia,
}) {
  final XmlElement? ph = _descFirst(pic, 'ph');
  if (ph != null) {
    final String type = _attr(ph, 'type').isEmpty ? 'pic' : _attr(ph, 'type');
    final String idx = _attr(ph, 'idx');
    if (skipPh.contains('$type|$idx') || skipPh.contains('$type|')) return;
  }
  final XmlElement? spPr = _child(pic, 'spPr');
  final XmlElement? xfrm = spPr == null ? null : _child(spPr, 'xfrm');
  Rect? rect = _rectOf(xfrm, tx, slideW, slideH);
  if (rect == null) {
    if (ph != null) {
      final String type = _attr(ph, 'type').isEmpty ? 'pic' : _attr(ph, 'type');
      final String idx = _attr(ph, 'idx');
      rect =
          layoutRects['$type|$idx'] ??
          layoutRects['$type|'] ??
          layoutRects['pic|$idx'];
    }
  }
  rect ??= const Rect.fromLTWH(0.08, 0.08, 0.84, 0.84);
  final XmlElement? blip = _descFirst(pic, 'blip');
  final Uint8List? bytes = _imageFor(archive, dir, rels, _embedOf(blip));
  if (bytes == null) {
    if (missingMedia != null && _embedOf(blip).isNotEmpty) {
      missingMedia.add(_embedOf(blip));
    }
    return;
  }
  nodes.add(PptxImageShape(rect: rect, bytes: bytes));
}

void _collectCxn(
  XmlElement el, {
  required _Theme theme,
  required _Tx tx,
  required double slideW,
  required double slideH,
  required List<Object> nodes,
}) {
  final XmlElement? spPr = _child(el, 'spPr');
  final XmlElement? xfrm = spPr == null ? null : _child(spPr, 'xfrm');
  final Rect? rect = _rectOf(xfrm, tx, slideW, slideH);
  if (rect == null) return;
  final XmlElement? ln = spPr == null ? null : _child(spPr, 'ln');
  final int? color = ln == null
      ? null
      : _colorOf(_descFirst(ln, 'solidFill'), theme);
  nodes.add(
    PptxBoxShape(
      rect: rect,
      lineArgb: color ?? 0xFF16211D,
      lineWidth: _max(0.8, _num(ln, 'w', 12700) / 12700),
    ),
  );
}

void _collectFrame(
  XmlElement frame, {
  required Archive archive,
  required String dir,
  required Map<String, String> rels,
  required _Theme theme,
  required _Tx tx,
  required double slideW,
  required double slideH,
  required List<PptxShape> textShapes,
  required List<Object> nodes,
  Set<String> skipPh = const <String>{},
  List<String>? missingMedia,
}) {
  final XmlElement? ph = _descFirst(frame, 'ph');
  if (ph != null) {
    final String type = _attr(ph, 'type').isEmpty ? 'body' : _attr(ph, 'type');
    final String idx = _attr(ph, 'idx');
    if (skipPh.contains('$type|$idx') || skipPh.contains('$type|')) return;
  }
  final XmlElement? xfrm = _child(frame, 'xfrm');
  final Rect rect =
      _rectOf(xfrm, tx, slideW, slideH) ??
      const Rect.fromLTWH(0.06, 0.18, 0.88, 0.64);
  // 有些生成器把整张图塞在 graphicFrame 里（graphicData > pic:pic）
  final XmlElement? framePic = _descFirst(frame, 'pic');
  if (framePic != null) {
    final XmlElement? blip = _descFirst(framePic, 'blip');
    final Uint8List? bytes = blip == null
        ? null
        : _imageFor(archive, dir, rels, _embedOf(blip));
    if (bytes != null) {
      nodes.add(PptxImageShape(rect: rect, bytes: bytes));
    } else if (missingMedia != null && _embedOf(blip).isNotEmpty) {
      missingMedia.add(_embedOf(blip));
    }
    return;
  }

  final XmlElement? tbl = _descFirst(frame, 'tbl');
  if (tbl == null) return;

  final List<double> colW = <double>[];
  for (final XmlElement c in _children(tbl, 'gridCol')) {
    colW.add(_num(c, 'w', 1));
  }
  final List<double> rowH = <double>[];
  final List<List<String>> rows = <List<String>>[];
  double maxFont = 12;
  for (final XmlElement tr in _children(tbl, 'tr')) {
    rowH.add(_num(tr, 'h', 1));
    final List<String> row = <String>[];
    for (final XmlElement tc in _children(tr, 'tc')) {
      final String txt = tc.descendants
          .whereType<XmlElement>()
          .where((XmlElement e) => e.name.local == 't')
          .map((XmlElement e) => e.innerText)
          .join('\n')
          .trim();
      row.add(txt);
      for (final XmlElement rPr in tc.descendants.whereType<XmlElement>()) {
        if (rPr.name.local == 'rPr' || rPr.name.local == 'defRPr') {
          final double? sz = double.tryParse(_attr(rPr, 'sz'));
          if (sz != null && sz / 100 > maxFont) maxFont = sz / 100;
        }
      }
    }
    if (row.isNotEmpty) rows.add(row);
  }
  if (rows.isEmpty) return;
  final double totalW = colW.fold<double>(0, (double a, double b) => a + b);
  final double totalH = rowH.fold<double>(0, (double a, double b) => a + b);
  nodes.add(
    PptxTableShape(
      rect: rect,
      rows: rows,
      colWidths: totalW <= 0
          ? List<double>.filled(
              colW.isEmpty ? 1 : colW.length,
              1 / (colW.isEmpty ? 1 : colW.length),
            )
          : colW.map((double w) => w / totalW).toList(),
      rowHeights: totalH <= 0
          ? List<double>.filled(rowH.length, 1 / rowH.length)
          : rowH.map((double h) => h / totalH).toList(),
      fontSize: maxFont.clamp(9, 24),
      headerFillArgb: _tableHeaderFill(tbl, theme),
    ),
  );
}

int? _tableHeaderFill(XmlElement tbl, _Theme theme) {
  final XmlElement? tr = _child(tbl, 'tr');
  if (tr == null) return null;
  final XmlElement? tc = _child(tr, 'tc');
  if (tc == null) return null;
  final XmlElement? tcPr = _child(tc, 'tcPr');
  if (tcPr == null) return null;
  return _colorOf(_descFirst(tcPr, 'solidFill'), theme);
}

/// 段落默认字号：rPr 没写时按 pPr/endParaRPr/lstStyle/bodyPr 逐级继承。
double _defaultTextSize(XmlElement txBody, XmlElement p) {
  final XmlElement? pPr = _child(p, 'pPr');
  final int lvl = int.tryParse(_attr(pPr, 'lvl')) ?? 0;
  final XmlElement? lst = _child(txBody, 'lstStyle');
  final XmlElement? lvlPr = _child(lst, 'lvl${(lvl + 1).clamp(1, 9)}pPr');
  for (final XmlElement? el in <XmlElement?>[
    _child(pPr, 'defRPr'),
    _child(lvlPr, 'defRPr'),
    _child(p, 'endParaRPr'),
    _child(_child(txBody, 'bodyPr'), 'defRPr'),
  ]) {
    final double? sz = double.tryParse(_attr(el, 'sz'));
    if (sz != null) return (sz / 100).clamp(8, 96);
  }
  return 18;
}

/// 段落默认文字颜色（同样的继承顺序）。
int _defaultTextColor(XmlElement txBody, XmlElement p, _Theme theme) {
  final XmlElement? pPr = _child(p, 'pPr');
  final int lvl = int.tryParse(_attr(pPr, 'lvl')) ?? 0;
  final XmlElement? lst = _child(txBody, 'lstStyle');
  final XmlElement? lvlPr = _child(lst, 'lvl${(lvl + 1).clamp(1, 9)}pPr');
  for (final XmlElement? el in <XmlElement?>[
    _child(pPr, 'defRPr'),
    _child(lvlPr, 'defRPr'),
    _child(p, 'endParaRPr'),
    _child(_child(txBody, 'bodyPr'), 'defRPr'),
  ]) {
    final int? c = _colorOf(_descFirst(el, 'solidFill'), theme);
    if (c != null) return c;
  }
  return 0xFF16211D;
}

/// 版式/母版里的"占位提示"，不是正文。
bool _isPromptText(String t) {
  if (t.isEmpty) return true;
  final String lower = t.toLowerCase();
  return t.contains('单击此处') ||
      t.contains('点击此处') ||
      t.contains('编辑母版') ||
      lower.contains('click to edit') ||
      t.contains('‹#›') ||
      t.contains('<#>') ||
      t == '‹#›';
}

PptxRun _runOf(
  String text,
  XmlElement? rPr,
  _Theme theme, {
  required double fallbackSize,
  int fallbackColor = 0xFF16211D,
}) {
  double size = fallbackSize;
  bool bold = false;
  bool italic = false;
  int color = fallbackColor;
  if (rPr != null) {
    final double? sz = double.tryParse(_attr(rPr, 'sz'));
    if (sz != null) size = sz / 100;
    bold = _attr(rPr, 'b') == '1';
    italic = _attr(rPr, 'i') == '1';
    final int? c = _colorOf(_descFirst(rPr, 'solidFill'), theme);
    if (c != null) color = c;
  }
  return PptxRun(
    text: text,
    fontSize: size.clamp(8, 96),
    bold: bold,
    italic: italic,
    colorArgb: color,
  );
}

bool _visibleBold(List<PptxRun> runs) {
  for (final PptxRun r in runs) {
    if (r.text.trim().isNotEmpty) return r.bold;
  }
  return false;
}

Rect? _rectOf(XmlElement? xfrm, _Tx tx, double slideW, double slideH) {
  if (xfrm == null) return null;
  final XmlElement? off = _child(xfrm, 'off');
  final XmlElement? ext = _child(xfrm, 'ext');
  if (off == null || ext == null) return null;
  final double x = _num(off, 'x', 0);
  final double y = _num(off, 'y', 0);
  double w = _num(ext, 'cx', 0);
  double h = _num(ext, 'cy', 0);
  if (w <= 0 || h <= 0) return null;
  final Offset p = tx.apply(x, y);
  w *= tx.sx;
  h *= tx.sy;
  if (w <= 0 || h <= 0) return null;
  return Rect.fromLTWH(p.dx / slideW, p.dy / slideH, w / slideW, h / slideH);
}

/// 取一个元素的填充色（`a:solidFill` / 第一个渐变标）。
int? _fillOf(XmlElement? parent, _Theme theme) {
  if (parent == null) return null;
  final XmlElement? solid = _child(parent, 'solidFill');
  if (solid != null) return _colorOf(solid, theme);
  final XmlElement? grad = _child(parent, 'gradFill');
  if (grad != null) {
    final XmlElement? gs = _descFirst(grad, 'gs');
    final int? c = _colorOf(gs, theme);
    if (c != null) return c;
  }
  return null;
}

int? _colorOf(XmlElement? holder, _Theme theme) {
  if (holder == null) return null;
  for (final XmlElement e in holder.descendants.whereType<XmlElement>()) {
    final String n = e.name.local;
    if (n == 'srgbClr') {
      final String v = _attr(e, 'val');
      final int? c = int.tryParse(v, radix: 16);
      if (c != null) return 0xFF000000 | (c & 0xFFFFFF);
    }
    if (n == 'schemeClr') return theme.color(_attr(e, 'val'));
    if (n == 'sysClr') {
      final String last = _attr(e, 'lastClr');
      final int? c = int.tryParse(last, radix: 16);
      if (c != null) return 0xFF000000 | (c & 0xFFFFFF);
    }
    if (n == 'prstClr') {
      switch (_attr(e, 'val')) {
        case 'black':
          return 0xFF000000;
        case 'white':
          return 0xFFFFFFFF;
        case 'red':
          return 0xFFC0392B;
        case 'green':
          return 0xFF1F7A4D;
        case 'blue':
          return 0xFF1F4B8F;
        case 'yellow':
          return 0xFFE0B31A;
        case 'gray':
        case 'grey':
          return 0xFF808080;
        default:
          return null;
      }
    }
    if (n == 'lumMod' || n == 'lumOff' || n == 'shade' || n == 'tint') {
      continue;
    }
  }
  return null;
}

String _embedOf(XmlElement? blip) {
  if (blip == null) return '';
  for (final XmlAttribute a in blip.attributes) {
    if (a.name.local == 'embed' || a.name.local == 'link') return a.value;
  }
  return '';
}

Uint8List? _imageFor(
  Archive archive,
  String slideDir,
  Map<String, String> rels,
  String embed,
) {
  if (embed.isEmpty) return null;
  final String? target = rels[embed];
  if (target == null || target.isEmpty) return null;
  final String path = _resolve(slideDir, target);
  final ArchiveFile? f = _findFile(archive, path);
  if (f == null) return null;
  final String lower = path.toLowerCase();
  if (lower.endsWith('.emf') || lower.endsWith('.wmf')) {
    // 1) 有些导出器会同时留一张同名 PNG/JPEG 预览
    final int dot = path.lastIndexOf('.');
    if (dot > 0) {
      for (final String ext in <String>['.png', '.jpg', '.jpeg']) {
        final ArchiveFile? alt = _findFile(
          archive,
          path.substring(0, dot) + ext,
        );
        if (alt != null) return Uint8List.fromList(alt.content);
      }
    }
    // 2) EMF 里如果嵌了位图（整页截图导出很常见），把最大的那张抽出来
    if (lower.endsWith('.emf')) {
      final Uint8List? bmp = _emfBitmap(Uint8List.fromList(f.content));
      if (bmp != null) return bmp;
    }
    return null;
  }
  if (lower.endsWith('.tif') || lower.endsWith('.tiff')) return null;
  return Uint8List.fromList(f.content);
}

String _resolve(String dir, String target) {
  String t = target.replaceAll('\\', '/');
  try {
    t = Uri.decodeFull(t);
  } catch (_) {
    // 非法转义就按原样用
  }
  if (t.startsWith('/')) return t.substring(1);
  final List<String> parts = <String>[...dir.split('/'), ...t.split('/')];
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
  final ArchiveFile? f = _findFile(archive, path);
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

class _Theme {
  _Theme(this._colors);

  final Map<String, int> _colors;

  static const Map<String, String> _alias = <String, String>{
    'tx1': 'dk1',
    'bg1': 'lt1',
    'tx2': 'dk2',
    'bg2': 'lt2',
  };

  int? color(String scheme) {
    final String key = _alias[scheme] ?? scheme;
    return _colors[key] ?? _colors[scheme];
  }
}

_Theme _parseTheme(Archive archive) {
  final Map<String, int> colors = <String, int>{};
  final ArchiveFile? f = _findFile(archive, 'ppt/theme/theme1.xml');
  if (f != null) {
    final XmlDocument doc = XmlDocument.parse(
      utf8.decode(f.content, allowMalformed: true),
    );
    final XmlElement? scheme = _descFirst(doc.rootElement, 'clrScheme');
    if (scheme != null) {
      for (final XmlElement e in scheme.children.whereType<XmlElement>()) {
        final String name = e.name.local;
        final XmlElement? c = _descFirst(e, 'srgbClr');
        final int? v = int.tryParse(_attr(c, 'val'), radix: 16);
        if (v != null) {
          colors[name] = 0xFF000000 | (v & 0xFFFFFF);
        }
      }
    }
  }
  // 兜底：主题里没有就用 Office 默认蓝灰
  colors.putIfAbsent('dk1', () => 0xFF000000);
  colors.putIfAbsent('lt1', () => 0xFFFFFFFF);
  colors.putIfAbsent('dk2', () => 0xFF44546A);
  colors.putIfAbsent('lt2', () => 0xFFE7E6E6);
  for (int i = 1; i <= 6; i++) {
    colors.putIfAbsent('accent$i', () => 0xFF4472C4);
  }
  return _Theme(colors);
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

double _num(XmlElement? e, String local, double fallback) {
  return double.tryParse(_attr(e, local)) ?? fallback;
}

double _max(double a, double b) => a > b ? a : b;

List<String> _slideOrder(Archive archive) {
  final ArchiveFile? pres = _findFile(archive, 'ppt/presentation.xml');
  if (pres == null) return <String>[];
  final Map<String, String> rels = _parseRels(
    archive,
    'ppt/_rels/presentation.xml.rels',
  );
  final XmlDocument doc = XmlDocument.parse(
    utf8.decode(pres.content, allowMalformed: true),
  );
  final List<String> out = <String>[];
  for (final XmlElement e in doc.descendants.whereType<XmlElement>()) {
    if (e.name.local != 'sldId') continue;
    final String id = _relId(e);
    final String? target = rels[id];
    if (target == null) continue;
    out.add(_resolve('ppt', target));
  }
  return out;
}

/// 取 `r:id`（`sldId` 自己的 `id` 是数字，不能混）。
String _relId(XmlElement e) {
  for (final XmlAttribute a in e.attributes) {
    if (a.name.local == 'id' &&
        (a.name.prefix == 'r' || a.name.toString().startsWith('r:'))) {
      return a.value;
    }
  }
  return '';
}

/// 幻灯片对应的版式文件路径。
String? _layoutPath(Map<String, String> rels) {
  for (final String target in rels.values) {
    if (target.toLowerCase().contains('slidelayout') &&
        target.toLowerCase().endsWith('.xml')) {
      return _resolve('ppt/slides', target);
    }
  }
  return null;
}

/// 版式里的占位符位置（`类型|idx`）。
Map<String, Rect> _layoutRects(
  Archive archive,
  String path,
  double slideW,
  double slideH,
) {
  final ArchiveFile? f = _findFile(archive, path);
  if (f == null) return <String, Rect>{};
  final XmlDocument doc = XmlDocument.parse(
    utf8.decode(f.content, allowMalformed: true),
  );
  final XmlElement? tree = _descFirst(doc.rootElement, 'spTree');
  if (tree == null) return <String, Rect>{};
  final Map<String, Rect> out = <String, Rect>{};
  for (final XmlElement sp in tree.children.whereType<XmlElement>()) {
    if (sp.name.local != 'sp') continue;
    final XmlElement? ph = _descFirst(sp, 'ph');
    if (ph == null) continue;
    final XmlElement? spPr = _child(sp, 'spPr');
    final XmlElement? xfrm = spPr == null ? null : _child(spPr, 'xfrm');
    final Rect? rect = _rectOf(xfrm, const _Tx(1, 1, 0, 0), slideW, slideH);
    if (rect == null) continue;
    final String type = _attr(ph, 'type').isEmpty ? 'body' : _attr(ph, 'type');
    final String idx = _attr(ph, 'idx');
    out['$type|$idx'] = rect;
    out.putIfAbsent('$type|', () => rect);
    if (idx.isNotEmpty) out.putIfAbsent('body|$idx', () => rect);
  }
  return out;
}

/// 背景色 / 背景图。
(int?, Uint8List?) _backgroundOf(
  Archive archive,
  XmlElement root,
  String dir,
  Map<String, String> rels,
  _Theme theme,
) {
  final XmlElement? cSld = _descFirst(root, 'cSld');
  final XmlElement? bgEl = cSld == null ? null : _child(cSld, 'bg');
  if (bgEl == null) return (null, null);
  final XmlElement? bgPr = _descFirst(bgEl, 'bgPr');
  if (bgPr == null) return (null, null);

  int? color = _colorOf(_descFirst(bgPr, 'solidFill'), theme);
  color ??= _colorOf(_descFirst(bgPr, 'gs'), theme);
  Uint8List? image;
  final XmlElement? blip = _descFirst(bgPr, 'blip');
  if (blip != null) {
    image = _imageFor(archive, dir, rels, _embedOf(blip));
  }
  return (color, image);
}

/// 读取一个 XML 部件的根节点。
XmlElement? _rootOf(Archive archive, String path) {
  final ArchiveFile? f = _findFile(archive, path);
  if (f == null) return null;
  return XmlDocument.parse(utf8.decode(f.content, allowMalformed: true))
      .rootElement;
}

/// 版式对应的母版路径。
String? _masterPath(Archive archive, String layoutPath) {
  final String dir = layoutPath.substring(0, layoutPath.lastIndexOf('/'));
  final String base = layoutPath.split('/').last;
  final Map<String, String> rels = _parseRels(archive, '$dir/_rels/$base.rels');
  for (final String target in rels.values) {
    final String lower = target.toLowerCase();
    if (lower.contains('slidemaster') && lower.endsWith('.xml')) {
      return _resolve(dir, target);
    }
  }
  for (final ArchiveFile f in archive.files) {
    if (RegExp(r'^ppt/slideMasters/slideMaster\d+\.xml$').hasMatch(f.name)) {
      return f.name;
    }
  }
  return null;
}

/// 幻灯片自己占了哪些占位符（`类型|idx`）。版式里同名的就不再画。
Set<String> _placeholders(XmlElement root) {
  final Set<String> out = <String>{};
  for (final XmlElement sp in root.descendants.whereType<XmlElement>()) {
    if (sp.name.local != 'sp' && sp.name.local != 'pic') continue;
    final XmlElement? ph = _descFirst(sp, 'ph');
    if (ph == null) continue;
    final String type = _attr(ph, 'type').isEmpty ? 'body' : _attr(ph, 'type');
    final String idx = _attr(ph, 'idx');
    out.add('$type|$idx');
    out.add('$type|');
  }
  return out;
}

/// 版式 / 母版上的装饰节点：只取图片、形状、表格，**不取文字**。
///
/// 版式里的文字大多是"单击此处编辑母版标题"这类占位提示，
/// 真放到预览里会变成一页假字；装饰图、logo、色块才是要补的。
List<Object> _decorationNodes(
  Archive archive,
  String path,
  _Theme theme,
  double slideW,
  double slideH,
  Set<String> skipPh,
) {
  final XmlElement? root = _rootOf(archive, path);
  if (root == null) return <Object>[];
  final XmlElement? tree = _descFirst(root, 'spTree');
  if (tree == null) return <Object>[];
  final String dir = path.substring(0, path.lastIndexOf('/'));
  final String base = path.split('/').last;
  final Map<String, String> rels = _parseRels(archive, '$dir/_rels/$base.rels');
  final List<PptxShape> ignoredText = <PptxShape>[];
  final List<Object> nodes = <Object>[];
  _collectSlide(
    tree,
    archive: archive,
    dir: dir,
    rels: rels,
    theme: theme,
    tx: const _Tx(1, 1, 0, 0),
    slideW: slideW,
    slideH: slideH,
    layoutRects: <String, Rect>{},
    textShapes: ignoredText,
    nodes: nodes,
    skipPh: skipPh,
    missingMedia: <String>[],
  );
  // 文字：只补"页脚/页码/栏目名"这类装饰文字；标题/正文占位符上的
  // "单击此处编辑"一律丢掉，否则每页都会多出一行假字。
  final List<Object> out = <Object>[];
  for (final Object n in nodes) {
    if (n is! PptxShape) {
      out.add(n);
      continue;
    }
    final String t = n.text.trim();
    if (_isPromptText(t)) continue;
    if (const <String>{
      'title',
      'ctrTitle',
      'subTitle',
      'body',
      'obj',
      'tx',
    }.contains(n.phType)) {
      continue;
    }
    out.add(n);
  }
  return out;
}

/// 从 EMF 记录里抽出最大的内嵌位图（返回 PNG 字节）。
///
/// 很多"整页导出 / Word 转 PPT"的课件，正文是一张 EMF，里面其实包着
/// 一整张 DIB 位图。Flutter 解不了 EMF，但可以把这张位图抠出来显示。
/// 纯矢量（只有文字/线条）的 EMF 抽不到东西，返回 null。
Uint8List? _emfBitmap(Uint8List emf) {
  if (emf.length < 16) return null;
  final ByteData bd = ByteData.sublistView(emf);
  Uint8List? best;
  int bestArea = 0;
  int i = 0;
  while (i + 8 <= emf.length) {
    final int type = bd.getUint32(i, Endian.little);
    final int size = bd.getUint32(i + 4, Endian.little);
    if (size < 8 || i + size > emf.length) break;

    int? offBmi;
    int? cbBmi;
    int? offBits;
    int? cbBits;
    if (type == 81) {
      // EMR_STRETCHDIBITS
      offBmi = bd.getUint32(i + 48, Endian.little);
      cbBmi = bd.getUint32(i + 52, Endian.little);
      offBits = bd.getUint32(i + 56, Endian.little);
      cbBits = bd.getUint32(i + 60, Endian.little);
    } else if (type == 76) {
      // EMR_BITBLT
      offBmi = bd.getUint32(i + 68, Endian.little);
      cbBmi = bd.getUint32(i + 72, Endian.little);
      offBits = bd.getUint32(i + 76, Endian.little);
      cbBits = bd.getUint32(i + 80, Endian.little);
    } else if (type == 80) {
      // EMR_SETDIBITSTODEVICE
      offBmi = bd.getUint32(i + 56, Endian.little);
      cbBmi = bd.getUint32(i + 60, Endian.little);
      offBits = bd.getUint32(i + 64, Endian.little);
      cbBits = bd.getUint32(i + 68, Endian.little);
    }

    if (offBmi != null &&
        cbBmi != null &&
        offBits != null &&
        cbBits != null &&
        cbBmi >= 40 &&
        offBmi + cbBmi <= size &&
        offBits + cbBits <= size) {
      try {
        final int biSize = bd.getUint32(i + offBmi, Endian.little);
        final int w = bd.getInt32(i + offBmi + 4, Endian.little).abs();
        final int h = bd.getInt32(i + offBmi + 8, Endian.little).abs();
        final int compression = bd.getUint32(i + offBmi + 16, Endian.little);
        // BI_RGB / BI_BITFIELDS 才让 image 包解
        if (biSize >= 40 &&
            w > 0 &&
            h > 0 &&
            (compression == 0 || compression == 3)) {
          final int area = w * h;
          if (area > bestArea) {
            final BytesBuilder bmp = BytesBuilder(copy: false);
            final int fileSize = 14 + cbBmi + cbBits;
            final ByteData head = ByteData(14);
            head.setUint8(0, 0x42); // B
            head.setUint8(1, 0x4D); // M
            head.setUint32(2, fileSize, Endian.little);
            head.setUint32(10, 14 + cbBmi, Endian.little);
            bmp.add(head.buffer.asUint8List());
            bmp.add(emf.sublist(i + offBmi, i + offBmi + cbBmi));
            bmp.add(emf.sublist(i + offBits, i + offBits + cbBits));
            final img.Image? decoded = img.decodeBmp(bmp.takeBytes());
            if (decoded != null) {
              best = Uint8List.fromList(img.encodePng(decoded));
              bestArea = area;
            }
          }
        }
      } catch (_) {
        // 单条记录坏了不影响其它记录
      }
    }
    i += size;
  }
  return best;
}

/// 大小写 / 反斜杠不敏感地找归档文件。
///
/// 有些导出器把 rels 里的 Target 写成 `..\media\image1.PNG`，或大小写
/// 和实际文件名对不上；按字面找就会"图片全部消失"。
ArchiveFile? _findFile(Archive archive, String path) {
  final String clean = path.replaceAll('\\', '/');
  final ArchiveFile? exact = archive.findFile(clean);
  if (exact != null) return exact;
  final String lower = clean.toLowerCase();
  for (final ArchiveFile f in archive.files) {
    if (f.name.toLowerCase() == lower) return f;
  }
  return null;
}
