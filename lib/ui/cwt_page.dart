import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;

import '../cwt/cwt_hub.dart';
import '../cwt/docx_preview.dart';
import '../cwt/pdf_render.dart';
import '../cwt/pptx_preview.dart';
import '../cwt/pptx_web_preview.dart';
import '../cwt/xlsx_preview.dart';
import '../knowledge/document_parser.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// 打开 ChangeWhatYouThink，返回用户框选的修改请求。
Future<CwtResult?> showChangeWhatYouThink(
  BuildContext context, {
  required CwtRequest request,
  required String workDir,
}) {
  return Navigator.of(context).push<CwtResult>(
    MaterialPageRoute<CwtResult>(
      fullscreenDialog: true,
      builder: (BuildContext _) =>
          ChangeWhatYouThinkPage(request: request, workDir: workDir),
    ),
  );
}

/// 文档预览的**固定**配色 —— 纸张 + 墨迹。
///
/// 这一组**不跟随深色主题**：预览要呈现的是"这份文件长什么样"，
/// 而不是"我们的界面长什么样"。白纸在任何主题下都是白的，
/// 跟着主题变暗会让人以为文档本身是黑底。
///
/// 但色相和新界面的暖纸一致：纸面是米白，墨是暖黑，表格线是暖灰 ——
/// 不再是原来那套偏青绿的 `#F1F4F2 / #BFC9C4 / #16211D`。
class _Doc {
  const _Doc._();

  /// 纸面（正文底色、幻灯片底色）
  static const Color paper = Color(0xFFFBF9F3);

  /// 墨色（正文、表格文字）
  static const Color ink = Color(0xFF23211D);

  /// 次要墨色（预览说明、页码标签）
  static const Color inkSoft = Color(0xFF6E675C);

  /// 更淡的墨色（"没有可预览的文字"这类占位）
  static const Color inkFaint = Color(0xFF9A9284);

  /// 表格线（主线）
  static const Color rule = Color(0xFFE4DFD3);

  /// 表格线（单元格内部的细线）
  static const Color ruleSoft = Color(0xFFEDE8DC);

  /// 表头底色
  static const Color headFill = Color(0xFFF1ECE0);

  /// 行号那一列的底色（比表头再淡一档）
  static const Color headFillSoft = Color(0xFFF6F2E8);

  /// 批注底色（未显示内容的红色提示条）
  static const Color noteBg = Color(0xFFF3DDD9);
}

class _DraftBox {
  _DraftBox({
    required this.rect,
    required this.description,
    this.page = 0,
    this.location = '',
    this.selectedText = '',
    this.cropPath = '',
  });

  final Rect rect;
  final int page;
  String description;
  final String selectedText;
  final String cropPath;
  final String location;
}

/// 在文件预览上拖框、写要求，最后变成输入框里的修改请求。
class ChangeWhatYouThinkPage extends StatefulWidget {
  const ChangeWhatYouThinkPage({
    super.key,
    required this.request,
    required this.workDir,
  });

  final CwtRequest request;
  final String workDir;

  @override
  State<ChangeWhatYouThinkPage> createState() => _ChangeWhatYouThinkPageState();
}

class _ChangeWhatYouThinkPageState extends State<ChangeWhatYouThinkPage> {
  late final String _ext;
  bool _loading = true;
  String _error = '';

  // 图片 / PDF 的像素尺寸（用于精确框选与裁剪）
  int _imgW = 0;
  int _imgH = 0;

  // PDF
  int _pageCount = 0;
  int _pageIndex = 0;
  RenderedPdfPage? _pdfPage;
  String _pdfPageFile = '';

  // Office（docx/xlsx/pptx/txt/md/html）结构化预览
  List<String> _blocks = <String>[];
  final List<GlobalKey> _blockKeys = <GlobalKey>[];
  String _officeKind = '';
  bool _officeTruncated = false;
  int _officePage = 0;

  /// 每页 10 段：保证 460 高的预览里能完整放下，不靠"只显示前 120 行"。
  static const int _officePageSize = 10;

  // PPTX：按幻灯片分页，位置来自 xfrm
  List<PptxSlide> _slides = <PptxSlide>[];
  int _slideIndex = 0;

  /// 高保真渲染（WebView + pptx-preview）。失败时自动退回自带渲染。
  final GlobalKey<PptxWebPreviewState> _pptxWebKey =
      GlobalKey<PptxWebPreviewState>();
  bool _pptxWebReady = false;
  bool _pptxWebFailed = false;
  String _pptxWebError = '';

  /// 用户手动切到"兼容渲染"（内置解析）。高保真偶尔遇到库不支持的
  /// 元素时，可以切回来看我们自己解析出的图片/形状。
  bool _pptxCompat = false;

  // Word：保留段落样式/图片/表格，按行数分页
  List<DocxPage> _docxPages = <DocxPage>[];
  int _docxPage = 0;
  List<GlobalKey> _docxKeys = <GlobalKey>[];

  // Excel：每张工作表按行分页；列宽/底色/合并按原样
  List<XlsxSheet> _xlsxSheets = <XlsxSheet>[];
  int _xlsxSheet = 0;
  int _xlsxRowPage = 0;
  Map<String, GlobalKey> _xlsxKeys = <String, GlobalKey>{};

  /// 每"屏"从第几行开始（按行高算，保证一屏放得下）。
  List<int> _xlsxPageStarts = <int>[];

  /// Excel 这类"内容比窗口大"的预览：浏览模式下不拦截手势，
  /// 否则一拖就变成画框，永远滚不到右边。
  bool _browseMode = false;

  static const double _xlsxBodyHeight = 428;

  // 选框
  final GlobalKey _previewKey = GlobalKey();
  final List<_DraftBox> _boxes = <_DraftBox>[];
  Offset? _dragStart;
  Offset? _dragNow;

  bool get _isImage =>
      <String>{'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'}.contains(_ext);
  bool get _isPdf => _ext == 'pdf';
  bool get _isPpt => const <String>{'pptx', 'pptm', 'potx'}.contains(_ext);
  bool get _isDocx => const <String>{'docx', 'docm', 'dotx'}.contains(_ext);
  bool get _isXlsx => const <String>{'xlsx', 'xlsm', 'xltx'}.contains(_ext);

  /// 老版二进制 Office（.doc/.xls/.ppt）没有可解析的 XML，只能提示转换。
  bool get _isLegacyOffice =>
      const <String>{'doc', 'xls', 'ppt', 'wps', 'et', 'dps'}.contains(_ext);

  /// 老格式对应的新格式，用在错误提示里。
  String get _legacyHint {
    final String to = switch (_ext) {
      'doc' || 'wps' => 'docx',
      'xls' || 'et' => 'xlsx',
      'ppt' || 'dps' => 'pptx',
      _ => 'docx / xlsx / pptx',
    };
    return '这是老版 Office 格式（.$_ext），无法直接预览。\n'
        '请先另存为 .$to 再打开，就能按原版式框选。';
  }

  /// Word / Excel / 文本类走结构化预览；PPT 单独按幻灯片渲染。
  bool get _isOffice => !_isImage && !_isPdf && !_isPpt && !_isDocx && !_isXlsx;

  /// 已经写好修改要求的框数量（空框不算）。
  int get _readyCount =>
      _boxes.where((_DraftBox b) => b.description.trim().isNotEmpty).length;

  int get _xlsxRowPages => _xlsxPageStarts.isEmpty ? 1 : _xlsxPageStarts.length;

  /// 按行高切屏：一屏最多 428 逻辑像素，避免高行被裁掉。
  void _rebuildXlsxPages() {
    _xlsxPageStarts = <int>[0];
    if (_xlsxSheets.isEmpty) return;
    final XlsxSheet sheet = _xlsxSheets[_xlsxSheet];
    int start = 0;
    while (start < sheet.rowCount) {
      double used = 0;
      int i = start;
      while (i < sheet.rowCount &&
          (used + sheet.rowHeights[i] <= _xlsxBodyHeight || i == start)) {
        used += sheet.rowHeights[i];
        i++;
      }
      if (i >= sheet.rowCount) break;
      _xlsxPageStarts.add(i);
      start = i;
    }
    if (_xlsxPageStarts.isEmpty) _xlsxPageStarts = <int>[0];
    _xlsxRowPage = _xlsxRowPage.clamp(0, _xlsxPageStarts.length - 1);
  }

  /// 某一屏的行范围 [start, end)。
  (int, int) _xlsxRangeFor(int page) {
    if (_xlsxSheets.isEmpty) return (0, 0);
    final XlsxSheet sheet = _xlsxSheets[_xlsxSheet];
    final int p = page.clamp(0, _xlsxPageStarts.length - 1);
    final int start = _xlsxPageStarts[p];
    final int end = p + 1 < _xlsxPageStarts.length
        ? _xlsxPageStarts[p + 1]
        : sheet.rowCount;
    return (start, end);
  }

  static List<GlobalKey> _keysFor(int n) =>
      List<GlobalKey>.generate(n, (_) => GlobalKey());

  /// 当前预览里可见框的 page 编号。
  int get _currentPageId {
    if (_isDocx) return _docxPage;
    if (_isXlsx) return _xlsxSheet * 1000 + _xlsxRowPage;
    if (_isPdf) return _pageIndex;
    if (_isPpt) return _slideIndex;
    if (_isOffice) return _officePage;
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _ext = widget.request.path.split('.').last.toLowerCase();
    _load();
  }

  Future<void> _load() async {
    try {
      if (_isImage) {
        final Map<String, int> info = await compute(
          _imageInfo,
          widget.request.path,
        );
        _imgW = info['w'] ?? 0;
        _imgH = info['h'] ?? 0;
        if (_imgW <= 0 || _imgH <= 0) {
          throw const FormatException('图片无法解码');
        }
      } else if (_isPdf) {
        _pageCount = await PdfRender.pageCount(widget.request.path);
        await _loadPdfPage(0);
      } else if (_isPpt) {
        _slides = parsePptxPreview(widget.request.path);
        if (_slides.isEmpty) throw const FormatException('PPT 里没有幻灯片');
        _slideIndex = 0;
        _pageCount = _slides.length;
      } else if (_isDocx) {
        _docxPages = parseDocxPreview(widget.request.path);
        _docxPage = 0;
        _docxKeys = _keysFor(_docxPages.first.blocks.length);
        _pageCount = _docxPages.length;
      } else if (_isXlsx) {
        _xlsxSheets = parseXlsxPreview(widget.request.path);
        _xlsxSheet = 0;
        _xlsxRowPage = 0;
        _xlsxKeys = <String, GlobalKey>{};
        _xlsxRowPage = 0;
        _rebuildXlsxPages();
        _pageCount = _xlsxRowPages;
      } else {
        final ParsedDocument d = await parseKnowledgeFile(widget.request.path);
        _officeKind = d.kind;
        final List<String> lines = d.text
            .split('\n')
            .map((String s) => s.trim())
            .where((String s) => s.isNotEmpty)
            .toList();
        // 全量保留（上限 2000 行），靠**分页**看完整内容，不再只显示前 120 行。
        const int maxBlocks = 2000;
        if (lines.length > maxBlocks) {
          _officeTruncated = true;
          _blocks = lines.take(maxBlocks).toList();
        } else {
          _blocks = lines;
        }
        _blocks = _blocks
            .map((String s) => s.length > 500 ? s.substring(0, 500) : s)
            .toList();
        _blockKeys
          ..clear()
          ..addAll(
            List<GlobalKey>.generate(_blocks.length, (_) => GlobalKey()),
          );
        _officePage = 0;
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _isLegacyOffice ? _legacyHint : '$e';
        });
      }
    }
  }

  Future<void> _loadPdfPage(int index) async {
    if (index < 0 || index >= _pageCount) return;
    setState(() => _loading = true);
    try {
      final RenderedPdfPage p = await PdfRender.renderPage(
        widget.request.path,
        index,
      );
      final Directory dir = Directory('${widget.workDir}/cwt');
      await dir.create(recursive: true);
      final String file =
          '${dir.path}/cwt_pdf_${index + 1}'
          '_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(file).writeAsBytes(p.bytes);
      if (!mounted) return;
      setState(() {
        _pageIndex = index;
        _pdfPage = p;
        _pdfPageFile = file;
        _imgW = p.width;
        _imgH = p.height;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _isLegacyOffice ? _legacyHint : '$e';
        });
      }
    }
  }

  /// 把一次拖拽变成选框：先算选中文字/截图，把框留在预览上，再打开编辑。
  Future<void> _finishSelection(Size size) async {
    final Offset? a = _dragStart;
    final Offset? b = _dragNow;
    setState(() {
      _dragStart = null;
      _dragNow = null;
    });
    if (a == null || b == null) return;

    final double left = math.min(a.dx, b.dx).clamp(0.0, size.width);
    final double top = math.min(a.dy, b.dy).clamp(0.0, size.height);
    final double right = math.max(a.dx, b.dx).clamp(0.0, size.width);
    final double bottom = math.max(a.dy, b.dy).clamp(0.0, size.height);
    if (right - left < 14 || bottom - top < 14) return;

    final Rect norm = Rect.fromLTRB(
      left / size.width,
      top / size.height,
      right / size.width,
      bottom / size.height,
    );

    String selected = '';
    String crop = '';
    if (_isOffice) {
      selected = _officeTextIn(norm);
    } else if (_isPpt) {
      if (_pptxWebReady) {
        selected = await _pptxWebKey.currentState?.pickText(norm) ?? '';
      }
      if (selected.trim().isEmpty) selected = _pptxTextIn(norm);
    } else if (_isDocx) {
      selected = _textFromKeys(_docxKeys, norm, size);
    } else if (_isXlsx) {
      selected = _textFromKeys(_xlsxKeys.values.toList(), norm, size);
    } else {
      crop = await _cropFor(norm);
    }
    if (!mounted) return;
    setState(() {
      _boxes.add(
        _DraftBox(
          rect: norm,
          page: _currentPageId,
          location: _locationLabel(_currentPageId),
          description: '',
          selectedText: selected,
          cropPath: crop,
        ),
      );
    });
    // 框一直显示在预览上；马上打开编辑，让用户填这块要改成什么。
    await _editBox(_boxes.length - 1);
  }

  /// 点已有的框 / 刚画完的框：输入改动，确定保存，删除移除。
  ///
  /// 框本身一直画在预览上，不会因为编辑框关闭而消失；再点它就能改。
  Future<void> _editBox(int index) async {
    if (index < 0 || index >= _boxes.length || !mounted) return;
    final _DraftBox box = _boxes[index];
    final TextEditingController c = TextEditingController(
      text: box.description,
    );
    String error = '';

    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) {
          final AppSurface s = AppSurface.of(ctx);
          return AlertDialog(
            title: Text('选框 ${index + 1}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '位置：x ${(box.rect.left * 100).round()}% · '
                    'y ${(box.rect.top * 100).round()}% · '
                    'w ${(box.rect.width * 100).round()}% · '
                    'h ${(box.rect.height * 100).round()}%',
                    style: AppFonts.body(size: 11.5, color: s.muted),
                  ),
                  if (box.selectedText.trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      '选中：${box.selectedText.replaceAll('\n', ' ')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(size: 11.5, color: s.muted),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: c,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                      labelText: '这块要改成什么？',
                      hintText: '例如：标题改短；把这张图换成我们的 logo',
                      errorText: error.isEmpty ? null : error,
                    ),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('delete'),
                child: Text(
                  '删除',
                  style: AppFonts.body(size: 14, color: AppColors.danger),
                ),
              ),
              TextButton(
                onPressed: () {
                  if (c.text.trim().isEmpty) {
                    setLocal(() => error = '请输入修改要求');
                    return;
                  }
                  Navigator.of(ctx).pop('save');
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
    final String text = c.text.trim();
    c.dispose();
    if (!mounted) return;

    if (action == 'delete') {
      setState(() => _boxes.removeAt(index));
      return;
    }
    if (action == 'save') {
      setState(() => _boxes[index].description = text);
      return;
    }
    // 点遮罩 / 返回关闭：还没写内容的空框撤掉，已写过的保持原样。
    if (text.isEmpty && box.description.trim().isEmpty) {
      setState(() => _boxes.removeAt(index));
    }
  }

  String _pptxTextIn(Rect norm) {
    if (_slides.isEmpty) return '';
    final PptxSlide slide = _slides[_slideIndex];
    final List<String> out = <String>[];
    for (final PptxShape shape in slide.shapes) {
      if (shape.rect.overlaps(norm)) out.add(shape.text);
    }
    return out.join('\n');
  }

  /// GlobalKey → 文本。Word / Excel 的块是在 build 里动态生成的，
  /// 没法像 `_blocks` 那样按下标取，所以顺手记一份。
  final Map<GlobalKey, String> _textByKey = <GlobalKey, String>{};

  /// 选框命中的文字（Word / Excel 用）。
  String _textFromKeys(List<GlobalKey> keys, Rect norm, Size size) {
    final BuildContext? ctx = _previewKey.currentContext;
    final RenderBox? container = ctx?.findRenderObject() as RenderBox?;
    if (container == null) return '';
    final Offset origin = container.localToGlobal(Offset.zero);
    final Rect target = Rect.fromLTWH(
      norm.left * size.width,
      norm.top * size.height,
      norm.width * size.width,
      norm.height * size.height,
    ).shift(origin);
    final List<String> out = <String>[];
    for (final GlobalKey k in keys) {
      final RenderBox? b = k.currentContext?.findRenderObject() as RenderBox?;
      if (b == null || !b.hasSize) continue;
      final Rect r = b.localToGlobal(Offset.zero) & b.size;
      if (!r.overlaps(target)) continue;
      final String t = _textByKey[k] ?? '';
      if (t.trim().isEmpty) continue;
      out.add(t);
      if (out.join('\n').length > 1200) break;
    }
    return out.join('\n');
  }

  String _officeTextIn(Rect norm) {
    final BuildContext? ctx = _previewKey.currentContext;
    if (ctx == null) return '';
    final RenderBox? container = ctx.findRenderObject() as RenderBox?;
    if (container == null) return '';
    final Offset origin = container.localToGlobal(Offset.zero);
    final Rect target = Rect.fromLTWH(
      norm.left * container.size.width,
      norm.top * container.size.height,
      norm.width * container.size.width,
      norm.height * container.size.height,
    );
    final List<String> out = <String>[];
    for (int i = 0; i < _blockKeys.length; i++) {
      final RenderBox? b =
          _blockKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (b == null) continue;
      final Rect r = Rect.fromLTWH(
        b.localToGlobal(Offset.zero).dx - origin.dx,
        b.localToGlobal(Offset.zero).dy - origin.dy,
        b.size.width,
        b.size.height,
      );
      if (r.overlaps(target)) out.add(_blocks[i]);
      if (out.join('\n').length > 1200) break;
    }
    return out.join('\n');
  }

  Future<String> _cropFor(Rect norm) async {
    final String src = _isPdf ? _pdfPageFile : widget.request.path;
    if (src.isEmpty || _imgW <= 0 || _imgH <= 0) return '';
    final Directory dir = Directory('${widget.workDir}/cwt');
    await dir.create(recursive: true);
    final String out =
        '${dir.path}/cwt_crop_${DateTime.now().millisecondsSinceEpoch}.png';
    try {
      return await compute(_cropImage, <String, dynamic>{
        'src': src,
        'out': out,
        'x': norm.left,
        'y': norm.top,
        'w': norm.width,
        'h': norm.height,
      });
    } catch (_) {
      return '';
    }
  }

  Future<void> _finish() async {
    final List<_DraftBox> ready = _boxes
        .where((_DraftBox d) => d.description.trim().isNotEmpty)
        .toList();
    if (ready.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('先拖一个选框，并写下要改什么')));
      }
      return;
    }
    Navigator.of(context).pop(
      CwtResult(
        path: widget.request.path,
        boxes: ready
            .map(
              (_DraftBox d) => CwtBox(
                rect: d.rect,
                page: d.page,
                location: d.location,
                description: d.description,
                selectedText: d.selectedText,
                cropPath: d.cropPath,
              ),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final String name = widget.request.path.split(RegExp(r'[/\\]')).last;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: 'ChangeWhatYouThink',
            subtitle: name,
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error.isNotEmpty
                ? _errorView(s)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                    children: <Widget>[
                      if (widget.request.brief.trim().isNotEmpty) _briefCard(s),
                      const SizedBox(height: 10),
                      _hint(s),
                      const SizedBox(height: 10),
                      _preview(s),
                      if (_isPdf) ...<Widget>[
                        const SizedBox(height: 8),
                        _pdfNav(s),
                      ],
                      if (_isPpt) ...<Widget>[
                        const SizedBox(height: 8),
                        _pptxNav(s),
                      ],
                      if (_isOffice) ...<Widget>[
                        const SizedBox(height: 8),
                        _officeNav(s),
                      ],
                      if (_isDocx) ...<Widget>[
                        const SizedBox(height: 8),
                        _docxNav(s),
                      ],
                      if (_isXlsx) ...<Widget>[
                        const SizedBox(height: 8),
                        _xlsxNav(s),
                      ],
                      const SizedBox(height: 14),
                      _boxesList(s),
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading || _error.isNotEmpty ? null : _finish,
                  child: Text(
                    _readyCount == 0 ? '拖框并写下要改什么' : '完成（$_readyCount 处修改）',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _briefCard(AppSurface s) => SurfaceCard(
    padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
    child: Text(
      widget.request.brief,
      style: AppFonts.body(size: 13, color: s.text, height: 1.5),
    ),
  );

  Widget _hint(AppSurface s) => Row(
    children: <Widget>[
      Icon(Icons.touch_app_outlined, size: 15, color: AppColors.accent),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          '在预览上拖动框选，松手后写下修改要求；框会一直留在预览上，'
          '点任意一个框就能改内容或删除。PPT 会显示图片、形状和表格，'
          'Word / Excel 按原版式显示；Excel 点右下角的手形图标可左右滚动。',
          style: AppFonts.body(size: 11.5, color: s.muted, height: 1.45),
        ),
      ),
    ],
  );

  Widget _errorView(AppSurface s) => ListView(
    padding: const EdgeInsets.all(16),
    children: <Widget>[
      SurfaceCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '无法生成预览',
              style: AppFonts.body(
                size: 14,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _error,
              style: AppFonts.body(size: 12.5, color: s.muted, height: 1.5),
            ),
            const SizedBox(height: 10),
            Text(
              '仍然可以直接在聊天里描述要改什么；或者把文件转成图片后再试。',
              style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _pdfNav(AppSurface s) => Row(
    children: <Widget>[
      IconButton(
        icon: const Icon(Icons.chevron_left_rounded),
        onPressed: _pageIndex > 0 ? () => _loadPdfPage(_pageIndex - 1) : null,
      ),
      Expanded(
        child: Center(
          child: Text(
            '第 ${_pageIndex + 1} / $_pageCount 页',
            style: AppFonts.body(size: 12, color: s.muted),
          ),
        ),
      ),
      IconButton(
        icon: const Icon(Icons.chevron_right_rounded),
        onPressed: _pageIndex + 1 < _pageCount
            ? () => _loadPdfPage(_pageIndex + 1)
            : null,
      ),
    ],
  );

  Widget _preview(AppSurface s) {
    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints c) {
        if (_isOffice) {
          return _officePreview(s, c.maxWidth);
        }
        if (_isPpt) {
          return _pptxPreview(s, c.maxWidth);
        }
        if (_isDocx) {
          return _docxPreview(s, c.maxWidth);
        }
        if (_isXlsx) {
          return _xlsxPreview(s, c.maxWidth);
        }
        final double aspect = (_imgW > 0 && _imgH > 0) ? _imgW / _imgH : 0.7;
        const double maxH = 520;
        double w = c.maxWidth;
        double h = w / aspect;
        if (h > maxH) {
          h = maxH;
          w = h * aspect;
        }
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.code),
                    child: _isImage
                        ? Image.file(
                            File(widget.request.path),
                            fit: BoxFit.fill,
                          )
                        : (_pdfPage != null
                              ? Image.memory(_pdfPage!.bytes, fit: BoxFit.fill)
                              : const SizedBox.shrink()),
                  ),
                ),
                Positioned.fill(child: _selectionLayer(Size(w, h))),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Office 里的图片：SVG 用矢量渲染，其它交给 `Image.memory`。
  ///
  /// PowerPoint / Word 很爱把图标、流程图存成 SVG。`Image.memory` 解不了，
  /// 之前这些图直接空白，整页就只剩几个字。
  Widget _officeImage(
    Uint8List bytes, {
    BoxFit fit = BoxFit.fill,
    Alignment alignment = Alignment.center,
  }) {
    if (_looksLikeSvg(bytes)) {
      return SvgPicture.memory(
        bytes,
        fit: fit,
        alignment: alignment,
        placeholderBuilder: (BuildContext _) => const SizedBox.shrink(),
        errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
            const SizedBox.shrink(),
      );
    }
    return Image.memory(
      bytes,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
          const SizedBox.shrink(),
    );
  }

  static bool _looksLikeSvg(Uint8List bytes) {
    final int n = bytes.length > 600 ? 600 : bytes.length;
    final String head = String.fromCharCodes(bytes.sublist(0, n)).toLowerCase();
    return head.contains('<svg') ||
        (head.contains('<?xml') && head.contains('svg'));
  }

  Widget _pptxPreview(AppSurface s, double maxWidth) {
    if (_slides.isEmpty) return const SizedBox.shrink();
    final PptxSlide slide = _slides[_slideIndex];
    const double maxH = 520;
    double w = maxWidth;
    double h = w / slide.aspect;
    if (h > maxH) {
      h = maxH;
      w = h * slide.aspect;
    }
    final double ptWidth = slide.widthEmu / 12700.0;
    final double scale = ptWidth <= 0 ? 1 : w / ptWidth;
    final bool useWeb = !_pptxWebFailed && !_pptxCompat;

    return Center(
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: slide.backgroundArgb == null
                      ? _Doc.paper
                      : Color(slide.backgroundArgb!),
                  borderRadius: BorderRadius.circular(AppRadius.code),
                  border: Border.all(color: s.border, width: 0.8),
                ),
              ),
            ),
            // ---- 高保真：WebView 里用 pptx-preview 渲染 ----
            //
            // 它把 pptx 解析成 HTML/CSS，图表、SmartArt、主题样式、旋转、
            // 裁剪等都能画；比我们自己解析 OOXML 完整得多。
            // 初始化失败（或超时）时 `_pptxWebFailed` 会置位，自动退回
            // 下面的内置渲染。
            if (useWeb)
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.code),
                  child: PptxWebPreview(
                    key: _pptxWebKey,
                    path: widget.request.path,
                    width: w,
                    height: h,
                    slideIndex: _slideIndex,
                    onReady: (int count) {
                      if (!mounted) return;
                      setState(() {
                        _pptxWebReady = true;
                        if (count > 0) {
                          _pageCount = count;
                          if (_slideIndex >= count) _slideIndex = count - 1;
                        }
                      });
                    },
                    onError: (String why) {
                      if (!mounted) return;
                      setState(() {
                        _pptxWebFailed = true;
                        _pptxWebReady = false;
                        _pptxWebError = why;
                      });
                    },
                  ),
                ),
              ),
            // ---- 内置渲染：只作为 WebView 的兜底 ----
            if (!useWeb) ...<Widget>[
              if (slide.backgroundImage != null)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.code),
                    child: _officeImage(
                      slide.backgroundImage!,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              for (final Object node in slide.nodes)
                _pptxNode(node, w, h, scale),
            ],
            if (useWeb && !_pptxWebReady)
              const Positioned.fill(
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ),
              ),
            Positioned.fill(child: _selectionLayer(Size(w, h))),
            if (!useWeb && slide.unsupportedMedia > 0)
              Positioned(
                left: 8,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _Doc.noteBg,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: AppColors.danger.withValues(alpha: 0.32),
                      width: 0.6,
                    ),
                  ),
                  child: Text(
                    '${slide.unsupportedMedia} 张图未能显示',
                    style: TextStyle(
                      fontSize: 9.5,
                      height: 1.1,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ),
            if (!useWeb)
              Positioned(
                left: 8,
                bottom: 6,
                child: Tooltip(
                  message: _pptxWebError.isEmpty
                      ? '内置解析渲染'
                      : '内置解析渲染：$_pptxWebError',
                  child: Text(
                    _pptxWebError.isEmpty ? '兼容预览' : '兼容预览（高保真不可用）',
                    style: TextStyle(fontSize: 9.5, color: s.muted),
                  ),
                ),
              ),
            Positioned(
              right: 8,
              bottom: 6,
              child: Text(
                '${_slideIndex + 1} / ${_pageCount > 0 ? _pageCount : _slides.length}',
                style: const TextStyle(fontSize: 10, color: _Doc.inkFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pptxNode(Object node, double w, double h, double scale) {
    if (node is PptxImageShape) {
      return Positioned(
        left: node.rect.left * w,
        top: node.rect.top * h,
        width: node.rect.width * w,
        height: node.rect.height * h,
        child: _officeImage(node.bytes),
      );
    }
    if (node is PptxBoxShape) {
      return Positioned(
        left: node.rect.left * w,
        top: node.rect.top * h,
        width: node.rect.width * w,
        height: node.rect.height * h,
        child: Container(
          decoration: BoxDecoration(
            color: node.fillArgb == null ? null : Color(node.fillArgb!),
            border: node.lineArgb == null
                ? null
                : Border.all(
                    color: Color(node.lineArgb!),
                    width: node.lineWidth.clamp(0.5, 3),
                  ),
            shape: node.ellipse ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: node.ellipse || !node.rounded
                ? null
                : BorderRadius.circular(6),
          ),
        ),
      );
    }
    if (node is PptxTableShape) {
      final List<double> widths = <double>[
        for (final double f in node.colWidths) f * node.rect.width * w,
      ];
      return Positioned(
        left: node.rect.left * w,
        top: node.rect.top * h,
        width: node.rect.width * w,
        height: node.rect.height * h,
        child: ClipRect(
          child: Table(
            columnWidths: <int, TableColumnWidth>{
              for (int i = 0; i < widths.length; i++)
                i: FixedColumnWidth(widths[i]),
            },
            border: TableBorder.all(color: _Doc.rule, width: 0.6),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: <TableRow>[
              for (int r = 0; r < node.rows.length; r++)
                TableRow(
                  children: <Widget>[
                    for (int c = 0; c < node.rows[r].length; c++)
                      Container(
                        color: r == 0 && node.headerFillArgb != null
                            ? Color(node.headerFillArgb!)
                            : null,
                        padding: const EdgeInsets.all(3),
                        child: Text(
                          node.rows[r][c],
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: (node.fontSize * scale * 1.4).clamp(
                              6,
                              14,
                            ),
                            fontWeight: r == 0
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _Doc.ink,
                            height: 1.2,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
    }
    if (node is PptxShape) {
      final TextAlign align = switch (node.align) {
        'ctr' => TextAlign.center,
        'r' => TextAlign.right,
        'just' => TextAlign.justify,
        _ => TextAlign.left,
      };
      final CrossAxisAlignment cross = switch (node.align) {
        'ctr' => CrossAxisAlignment.center,
        'r' => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.start,
      };
      final MainAxisAlignment main = switch (node.anchor) {
        'ctr' => MainAxisAlignment.center,
        'b' => MainAxisAlignment.end,
        _ => MainAxisAlignment.start,
      };
      final List<PptxRun> runs = node.runs.isEmpty
          ? <PptxRun>[
              PptxRun(
                text: node.text,
                fontSize: node.fontSize,
                bold: node.bold,
                italic: node.italic,
                colorArgb: node.colorArgb,
              ),
            ]
          : node.runs;
      return Positioned(
        left: node.rect.left * w,
        top: node.rect.top * h,
        width: node.rect.width * w,
        height: node.rect.height * h,
        child: ClipRect(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              node.insetL * scale * 0.6,
              node.insetT * scale * 0.6,
              node.insetR * scale * 0.6,
              node.insetB * scale * 0.6,
            ),
            child: Column(
              crossAxisAlignment: cross,
              mainAxisAlignment: main,
              children: <Widget>[
                RichText(
                  textAlign: align,
                  text: TextSpan(
                    children: <InlineSpan>[
                      for (final PptxRun r in runs)
                        TextSpan(
                          text: r.text,
                          style: TextStyle(
                            fontSize: (r.fontSize * scale).clamp(6.5, 44),
                            height: 1.25,
                            fontWeight: r.bold
                                ? FontWeight.w600
                                : FontWeight.w400,
                            fontStyle: r.italic
                                ? FontStyle.italic
                                : FontStyle.normal,
                            color: Color(r.colorArgb),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  // ---------------------------------------------------------------- Word

  Widget _docxPreview(AppSurface s, double maxWidth) {
    if (_docxPages.isEmpty) return const SizedBox.shrink();
    final DocxPage page = _docxPages[_docxPage.clamp(0, _docxPages.length - 1)];
    if (_docxKeys.length != page.blocks.length) {
      _docxKeys = _keysFor(page.blocks.length);
    }
    _textByKey.removeWhere((GlobalKey k, _) => !_docxKeys.contains(k));
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < page.blocks.length; i++) {
      final DocxBlock b = page.blocks[i];
      final GlobalKey key = _docxKeys[i];
      _textByKey[key] = switch (b) {
        DocxParagraph p => p.text,
        DocxTableBlock t =>
          t.rows.map((List<String> r) => r.join(' | ')).join('\n'),
        _ => '',
      };
      children.add(_docxBlockWidget(s, b, key));
    }
    return Container(
      key: _previewKey,
      width: maxWidth,
      height: 460,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: _Doc.paper,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: s.border, width: 0.8),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
          Positioned.fill(child: _selectionLayer(Size(maxWidth, 460))),
        ],
      ),
    );
  }

  Widget _docxBlockWidget(AppSurface s, DocxBlock b, GlobalKey key) {
    if (b is DocxImageBlock) {
      return Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            height: 132,
            child: AspectRatio(
              aspectRatio: b.aspect,
              child: _officeImage(
                b.bytes,
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
              ),
            ),
          ),
        ),
      );
    }
    if (b is DocxTableBlock) {
      final int cols = b.rows.fold<int>(
        0,
        (int a, List<String> r) => math.max(a, r.length),
      );
      return Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Table(
          border: TableBorder.all(color: _Doc.rule, width: 0.7),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: <TableRow>[
            for (int r = 0; r < b.rows.length; r++)
              TableRow(
                decoration: b.header && r == 0
                    ? const BoxDecoration(color: _Doc.headFill)
                    : null,
                children: <Widget>[
                  for (int c = 0; c < cols; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Text(
                        c < b.rows[r].length ? b.rows[r][c] : '',
                        style: TextStyle(
                          fontSize: b.fontSize,
                          height: 1.35,
                          fontWeight: b.header && r == 0
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: _Doc.ink,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      );
    }
    final DocxParagraph p = b as DocxParagraph;
    final TextAlign align = switch (p.align) {
      'ctr' => TextAlign.center,
      'r' => TextAlign.right,
      'just' => TextAlign.justify,
      _ => TextAlign.left,
    };
    final Widget text = RichText(
      textAlign: align,
      text: TextSpan(
        children: <InlineSpan>[
          for (final DocxRun r in p.runs)
            TextSpan(
              text: r.text,
              style: TextStyle(
                fontSize: r.size,
                height: 1.5,
                fontWeight: r.bold ? FontWeight.w600 : FontWeight.w400,
                fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
                decoration: r.underline
                    ? TextDecoration.underline
                    : TextDecoration.none,
                color: Color(r.colorArgb),
              ),
            ),
        ],
      ),
    );
    return Padding(
      key: key,
      padding: EdgeInsets.only(
        top: p.heading > 0 ? 8 : 0,
        bottom: p.heading > 0 ? 4 : 2,
      ),
      child: p.bullet
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('•  ', style: TextStyle(fontSize: 13)),
                Expanded(child: text),
              ],
            )
          : text,
    );
  }

  // ---------------------------------------------------------------- Excel

  Widget _xlsxPreview(AppSurface s, double maxWidth) {
    if (_xlsxSheets.isEmpty) return const SizedBox.shrink();
    final XlsxSheet sheet =
        _xlsxSheets[_xlsxSheet.clamp(0, _xlsxSheets.length - 1)];
    final (int startRow, int endRow) = _xlsxRangeFor(_xlsxRowPage);
    // key 表在翻页/换表时清空（见导航），这里只复用：每次重建都换新
    // GlobalKey 会让整张表重建一遍，滚动时闪。

    const double rowHeader = 38;
    const double headHeight = 26;
    final double totalWidth =
        rowHeader +
        sheet.colWidths.fold<double>(0, (double a, double b) => a + b);

    return Container(
      key: _previewKey,
      width: maxWidth,
      height: 460,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: _Doc.paper,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: s.border, width: 0.8),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: _browseMode
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: math.max(totalWidth, maxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      height: headHeight,
                      child: Row(
                        children: <Widget>[
                          _xlsxHeadCell('', rowHeader, _Doc.headFill),
                          for (int c = 0; c < sheet.colCount; c++)
                            _xlsxHeadCell(
                              _colName(c),
                              sheet.colWidths[c],
                              _Doc.headFill,
                            ),
                        ],
                      ),
                    ),
                    for (int r = startRow; r < endRow; r++)
                      SizedBox(
                        height: sheet.rowHeights[r],
                        child: Row(
                          children: <Widget>[
                            _xlsxHeadCell(
                              '${r + 1}',
                              rowHeader,
                              _Doc.headFillSoft,
                            ),
                            for (int c = 0; c < sheet.colCount; c++)
                              _xlsxCellWidget(s, sheet, r, c),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _browseMode,
              child: _selectionLayer(Size(maxWidth, 460)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _xlsxHeadCell(String text, double width, Color bg) => Container(
    width: width,
    height: 26,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: bg,
      border: const Border(
        right: BorderSide(color: _Doc.ruleSoft, width: 0.6),
        bottom: BorderSide(color: _Doc.ruleSoft, width: 0.6),
      ),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 9.5, color: _Doc.inkSoft),
    ),
  );

  Widget _xlsxCellWidget(AppSurface s, XlsxSheet sheet, int r, int c) {
    final XlsxCell? cell = sheet.rows[r][c];
    if (cell == null || cell.colSpan == 0) {
      return SizedBox(width: sheet.colWidths[c], height: sheet.rowHeights[r]);
    }
    final int span = cell.colSpan.clamp(1, sheet.colCount - c);
    double width = 0;
    for (int i = 0; i < span; i++) {
      width += sheet.colWidths[c + i];
    }
    final GlobalKey? key = cell.text.trim().isEmpty
        ? null
        : (_xlsxKeys['${r}_$c'] ??= GlobalKey());
    if (key != null) _textByKey[key] = cell.text;
    return Container(
      key: key,
      width: width,
      height: sheet.rowHeights[r],
      alignment: switch (cell.align) {
        'ctr' => Alignment.center,
        'r' => Alignment.centerRight,
        _ => Alignment.centerLeft,
      },
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: cell.fillArgb == null ? null : Color(cell.fillArgb!),
        border: const Border(
          right: BorderSide(color: _Doc.ruleSoft, width: 0.6),
          bottom: BorderSide(color: _Doc.ruleSoft, width: 0.6),
        ),
      ),
      child: Text(
        cell.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: (cell.fontSize ?? 11.5).clamp(9, 15),
          height: 1.25,
          fontWeight: cell.bold ? FontWeight.w600 : FontWeight.w400,
          fontStyle: cell.italic ? FontStyle.italic : FontStyle.normal,
          color: Color(cell.colorArgb),
        ),
      ),
    );
  }

  static String _colName(int index) {
    int n = index + 1;
    final StringBuffer sb = StringBuffer();
    while (n > 0) {
      final int rem = (n - 1) % 26;
      sb.write(String.fromCharCode(65 + rem));
      n = (n - 1) ~/ 26;
    }
    return sb.toString();
  }

  Widget _pptxNav(AppSurface s) => Row(
    children: <Widget>[
      IconButton(
        icon: const Icon(Icons.chevron_left_rounded),
        onPressed: _slideIndex > 0 ? () => setState(() => _slideIndex--) : null,
      ),
      Expanded(
        child: Center(
          child: Text(
            '幻灯片 ${_slideIndex + 1} / ${_pageCount > 0 ? _pageCount : _slides.length}',
            style: AppFonts.body(size: 12, color: s.muted),
          ),
        ),
      ),
      IconButton(
        icon: Icon(
          _pptxCompat ? Icons.auto_awesome_outlined : Icons.layers_outlined,
          size: 19,
        ),
        tooltip: _pptxCompat ? '切回高保真渲染' : '兼容渲染（内置解析）',
        onPressed: () => setState(() {
          _pptxCompat = !_pptxCompat;
          _pptxWebReady = false;
        }),
      ),
      IconButton(
        icon: const Icon(Icons.chevron_right_rounded),
        onPressed:
            _slideIndex + 1 < (_pageCount > 0 ? _pageCount : _slides.length)
            ? () => setState(() => _slideIndex++)
            : null,
      ),
    ],
  );

  Widget _docxNav(AppSurface s) {
    final int pages = math.max(1, _docxPages.length);
    return Row(
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: _docxPage > 0
              ? () => setState(() {
                  _docxPage--;
                  _docxKeys = _keysFor(_docxPages[_docxPage].blocks.length);
                })
              : null,
        ),
        Expanded(
          child: Center(
            child: Text(
              '第 ${_docxPage + 1} / $pages 页',
              style: AppFonts.body(size: 12, color: s.muted),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: _docxPage + 1 < pages
              ? () => setState(() {
                  _docxPage++;
                  _docxKeys = _keysFor(_docxPages[_docxPage].blocks.length);
                })
              : null,
        ),
      ],
    );
  }

  Widget _xlsxNav(AppSurface s) {
    if (_xlsxSheets.isEmpty) return const SizedBox.shrink();
    final XlsxSheet sheet = _xlsxSheets[_xlsxSheet];
    final (int start, int end) = _xlsxRangeFor(_xlsxRowPage);
    return Row(
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: _xlsxRowPage > 0
              ? () => setState(() {
                  _xlsxRowPage--;
                  _xlsxKeys = <String, GlobalKey>{};
                })
              : null,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '第 ${start + 1}–$end 行'
                '${sheet.truncated ? '（预览截断）' : ''}',
                style: AppFonts.body(size: 12, color: s.muted),
              ),
              if (_xlsxSheets.length > 1)
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _xlsxSheet,
                    isDense: true,
                    style: AppFonts.body(size: 11.5, color: s.muted),
                    items: <DropdownMenuItem<int>>[
                      for (int i = 0; i < _xlsxSheets.length; i++)
                        DropdownMenuItem<int>(
                          value: i,
                          child: Text(_xlsxSheets[i].name),
                        ),
                    ],
                    onChanged: (int? v) {
                      if (v == null) return;
                      setState(() {
                        _xlsxSheet = v;
                        _xlsxRowPage = 0;
                        _rebuildXlsxPages();
                        _xlsxKeys = <String, GlobalKey>{};
                      });
                    },
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          icon: Icon(
            _browseMode ? Icons.crop_free_rounded : Icons.pan_tool_alt_outlined,
            size: 19,
          ),
          tooltip: _browseMode ? '框选模式' : '浏览模式（左右滚动）',
          onPressed: () => setState(() => _browseMode = !_browseMode),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: _xlsxRowPage + 1 < _xlsxRowPages
              ? () => setState(() {
                  _xlsxRowPage++;
                  _xlsxKeys = <String, GlobalKey>{};
                })
              : null,
        ),
      ],
    );
  }

  Widget _officeNav(AppSurface s) {
    final int pages = math.max(1, (_blocks.length / _officePageSize).ceil());
    return Row(
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: _officePage > 0
              ? () => setState(() => _officePage--)
              : null,
        ),
        Expanded(
          child: Center(
            child: Text(
              '第 ${_officePage + 1} / $pages 页'
              '${_officeTruncated ? ' · 内容过长，仅保留前 2000 段' : ''}',
              style: AppFonts.body(size: 12, color: s.muted),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: _officePage + 1 < pages
              ? () => setState(() => _officePage++)
              : null,
        ),
      ],
    );
  }

  Widget _officePreview(AppSurface s, double maxWidth) {
    final int start = _officePage * _officePageSize;
    final int end = math.min(start + _officePageSize, _blocks.length);
    final int pages = math.max(1, (_blocks.length / _officePageSize).ceil());

    return Container(
      key: _previewKey,
      width: maxWidth,
      height: 460,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: _Doc.paper,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: s.border, width: 0.8),
      ),
      child: Stack(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${_officeKind.isEmpty ? '文档' : _officeKind} · 结构化预览'
                  ' · 第 ${_officePage + 1}/$pages 页',
                  style: AppFonts.body(size: 10.5, color: _Doc.inkSoft),
                ),
                const SizedBox(height: 8),
                for (int i = start; i < end; i++)
                  Padding(
                    key: _blockKeys[i],
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      _blocks[i],
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: _Doc.ink,
                      ),
                    ),
                  ),
                if (_blocks.isEmpty)
                  const Text(
                    '（没有可预览的文字）',
                    style: TextStyle(fontSize: 12, color: _Doc.inkFaint),
                  ),
              ],
            ),
          ),
          Positioned.fill(child: _selectionLayer(Size(maxWidth, 460))),
        ],
      ),
    );
  }

  Widget _selectionLayer(Size size) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (TapUpDetails d) => _openBoxAt(d.localPosition, size),
      onPanStart: (DragStartDetails d) => setState(() {
        _dragStart = d.localPosition;
        _dragNow = d.localPosition;
      }),
      onPanUpdate: (DragUpdateDetails d) => setState(() {
        _dragNow = Offset(
          d.localPosition.dx.clamp(0.0, size.width),
          d.localPosition.dy.clamp(0.0, size.height),
        );
      }),
      onPanEnd: (_) => _finishSelection(size),
      child: CustomPaint(
        painter: _SelectionPainter(
          start: _dragStart,
          now: _dragNow,
          existing: _visibleBoxes().map((_DraftBox b) => b.rect).toList(),
          labels: <String>[
            for (final _DraftBox b in _visibleBoxes())
              '${_boxes.indexOf(b) + 1}',
          ],
        ),
      ),
    );
  }

  /// 当前这一页/这一张上应该显示的框（按添加顺序）。
  List<_DraftBox> _visibleBoxes() =>
      _boxes.where(_visibleHere).toList(growable: false);

  /// 点已有选框 → 打开编辑。后画的框在上层，优先命中。
  void _openBoxAt(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final Offset norm = Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
    for (int i = _boxes.length - 1; i >= 0; i--) {
      final _DraftBox b = _boxes[i];
      if (!_visibleHere(b)) continue;
      if (b.rect.contains(norm)) {
        _editBox(i);
        return;
      }
    }
  }

  bool _visibleHere(_DraftBox b) {
    if (_isImage) return true;
    if (_isPdf) return b.page == _pageIndex;
    if (_isPpt) return b.page == _slideIndex;
    if (_isDocx) return b.page == _docxPage;
    if (_isXlsx) {
      return b.page ~/ 1000 == _xlsxSheet && b.page % 1000 == _xlsxRowPage;
    }
    return b.page == _officePage;
  }

  /// 选框所属位置的人类可读标签（给清单和模型看）。
  String _locationLabel(int page) {
    if (_isDocx) return '第 ${page + 1} 页';
    if (_isXlsx) {
      final int sheetIdx = page ~/ 1000;
      final int screen = page % 1000;
      final String name = sheetIdx >= 0 && sheetIdx < _xlsxSheets.length
          ? _xlsxSheets[sheetIdx].name
          : '工作表';
      return '$name 第 ${screen + 1} 屏';
    }
    if (_isPpt) return '幻灯片 ${page + 1}';
    if (_isPdf) return '第 ${page + 1} 页';
    if (page > 0) return '第 ${page + 1} 页';
    return '';
  }

  String _pageLabel(int page) {
    final String l = _locationLabel(page);
    return l.isEmpty ? '' : ' · $l';
  }

  Widget _boxesList(AppSurface s) {
    if (_boxes.isEmpty) {
      return Text('还没有选框。', style: AppFonts.body(size: 12, color: s.muted));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '修改清单 ${_boxes.length} · 点框可改',
          style: AppFonts.body(
            size: 12.5,
            weight: FontWeight.w600,
            color: s.muted,
          ),
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < _boxes.length; i++) _boxCard(s, i),
      ],
    );
  }

  Widget _boxCard(AppSurface s, int i) {
    final _DraftBox b = _boxes[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        onTap: () => _editBox(i),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${i + 1}',
                style: AppFonts.body(
                  size: 11,
                  weight: FontWeight.w600,
                  color: AppColors.onAccent,
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    b.description.trim().isEmpty ? '点这里写要改成什么' : b.description,
                    style: AppFonts.body(
                      size: 12.5,
                      color: b.description.trim().isEmpty ? s.muted : s.text,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'x ${(b.rect.left * 100).round()}% · y ${(b.rect.top * 100).round()}%'
                    ' · w ${(b.rect.width * 100).round()}% · h ${(b.rect.height * 100).round()}%'
                    '${_pageLabel(b.page)}',
                    style: AppFonts.body(size: 10, color: s.muted),
                  ),
                  if (b.selectedText.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      '选中：${b.selectedText.replaceAll('\n', ' ')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(size: 10.5, color: s.muted),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 16),
              tooltip: '删除这个选框',
              color: s.muted,
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _boxes.removeAt(i)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter({
    required this.start,
    required this.now,
    required this.existing,
    this.labels = const <String>[],
  });

  final Offset? start;
  final Offset? now;
  final List<Rect> existing;
  final List<String> labels;

  @override
  void paint(Canvas canvas, Size size) {
    // 选框走强调色（陶土橙）：它是**操作痕迹**，不是文档内容 ——
    // 和纸张墨迹那一套分开，一眼能看出"这是我框的，不是文件里的线"。
    final Paint stroke = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final Paint fill = Paint()
      ..color = AppColors.accent.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;

    for (int i = 0; i < existing.length; i++) {
      final Rect norm = existing[i];
      final Rect r = Rect.fromLTWH(
        norm.left * size.width,
        norm.top * size.height,
        norm.width * size.width,
        norm.height * size.height,
      );
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
      if (i < labels.length) _badge(canvas, r, labels[i]);
    }

    if (start != null && now != null) {
      final Rect r = Rect.fromPoints(start!, now!);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }
  }

  /// 框角上的序号：和下方「修改清单」一一对应。
  void _badge(Canvas canvas, Rect r, String text) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 10,
          height: 1,
          color: AppColors.onAccent,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final double w = math.max(14, tp.width + 8);
    final Rect box = Rect.fromLTWH(r.left, r.top, w, 14);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        box,
        topLeft: const Radius.circular(4),
        bottomRight: const Radius.circular(4),
      ),
      Paint()..color = AppColors.accent,
    );
    tp.paint(canvas, Offset(box.left + 4, box.top + 2));
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.start != start ||
      old.now != now ||
      old.existing != existing ||
      old.labels != labels;
}

// ------------------------------------------------------------------ 图片工具

Map<String, int> _imageInfo(String path) {
  final img.Image? im = img.decodeImage(File(path).readAsBytesSync());
  return <String, int>{'w': im?.width ?? 0, 'h': im?.height ?? 0};
}

String _cropImage(Map<String, dynamic> args) {
  final img.Image? src = img.decodeImage(
    File(args['src'] as String).readAsBytesSync(),
  );
  if (src == null) throw const FormatException('图片无法解码');
  final int x = (src.width * (args['x'] as num)).round().clamp(
    0,
    src.width - 1,
  );
  final int y = (src.height * (args['y'] as num)).round().clamp(
    0,
    src.height - 1,
  );
  final int w = (src.width * (args['w'] as num)).round().clamp(
    1,
    src.width - x,
  );
  final int h = (src.height * (args['h'] as num)).round().clamp(
    1,
    src.height - y,
  );
  final img.Image cropped = img.copyCrop(src, x: x, y: y, width: w, height: h);
  File(args['out'] as String).writeAsBytesSync(img.encodePng(cropped));
  return args['out'] as String;
}
