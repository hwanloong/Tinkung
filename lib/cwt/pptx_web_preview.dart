import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 用 `pptx-preview`（npm, ISC）在 WebView 里渲染 PPT。
///
/// ## 为什么用它
///
/// 自己解析 OOXML 只能覆盖一部分结构：图表、SmartArt、主题样式、旋转、
/// 裁剪、艺术字……越补越多，而且永远追不上真 Office 的排版。这里换成一个
/// 专门做 PPTX 预览的前端库：它把整份 pptx 解析成 HTML/CSS（文字、图片、
/// 形状、表格、图表都能画），我们只负责把文件喂进去、控制页码、取框选文字。
///
/// ## 资源加载（踩过的坑）
///
/// `InAppWebView.initialFile` / `loadFile` 的 **不是任意文件路径**，
/// 而是 **Flutter asset 路径**：插件会用 `flutterAssets.getAssetFilePathByName`
/// 去找包内的 `flutter_assets/...`。所以这里传
/// `assets/pptx_viewer/viewer.html`，同目录的 `pptx-preview.umd.js` 由
/// `<script src>` 相对加载。之前传的是工作目录里的绝对路径，插件找不到，
/// 页面根本没加载 —— 于是每次都悄悄退回内置渲染，看起来就是"PPT 还是不全"。
///
/// ## 数据怎么过去
///
/// 不走网络，也不让 WebView 直接读文件：Flutter 把 pptx 读成字节，
/// 按 256 KB 分块 base64 通过 JS 桥传给页面，页面拼回 `ArrayBuffer` 再交给
/// 库。这样大文件不会因为 `file://` 的跨域限制读不到，也不需要起本地服务。
///
/// ## 选择框
///
/// WebView 只负责"画"；框选层仍然是 Flutter 盖在上面的 `_selectionLayer`。
/// 需要在框里取文字时调用 [PptxWebPreviewState.pickText]（页面里遍历 DOM）。
class PptxWebPreview extends StatefulWidget {
  const PptxWebPreview({
    super.key,
    required this.path,
    required this.width,
    required this.height,
    required this.slideIndex,
    this.onReady,
    this.onError,
  });

  final String path;
  final double width;
  final double height;
  final int slideIndex;

  /// 首次渲染完成（参数是幻灯片总数）。
  final ValueChanged<int>? onReady;

  /// 初始化失败：调用方应退回内置的简化渲染。
  final ValueChanged<String>? onError;

  /// 随 APK 打包的 viewer 页面（Flutter asset 路径，**不是**文件系统路径）。
  static const String assetPath = 'assets/pptx_viewer/viewer.html';

  @override
  State<PptxWebPreview> createState() => PptxWebPreviewState();
}

class PptxWebPreviewState extends State<PptxWebPreview> {
  InAppWebViewController? _web;
  Timer? _timeout;

  bool _pageLoaded = false;
  bool _sent = false;
  bool _ready = false;
  bool _failed = false;
  bool _reportedError = false;
  int _reloadKey = 0;
  String _lastError = '';

  static const int _chunkBytes = 256 * 1024;

  bool get isReady => _ready;
  String get lastError => _lastError;

  @override
  void initState() {
    super.initState();
    _armTimeout();
  }

  @override
  void didUpdateWidget(PptxWebPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slideIndex != widget.slideIndex) {
      showSlide(widget.slideIndex);
    }
    if (oldWidget.path != widget.path ||
        (oldWidget.width - widget.width).abs() > 1 ||
        (oldWidget.height - widget.height).abs() > 1) {
      // 换文件 / 尺寸变化：重建 WebView 最稳（库内部按 width/height 排版）
      _restart();
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  void _armTimeout() {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 90), () async {
      if (_ready) return;
      // 超时前先问页面一句"到哪一步了"：如果库都没加载 / 文件没收到，
      // 那就是环境问题；如果已经收到但还在排版，就是文件太大。
      // 三种情况给用户的下一步完全不同，不能都报"渲染超时"。
      final String diag = await _diagnose();
      _fail(diag.isEmpty ? '渲染超时' : '渲染超时（$diag）');
    });
  }

  void _restart() {
    _web = null;
    _pageLoaded = false;
    _sent = false;
    _ready = false;
    _failed = false;
    _reportedError = false;
    _lastError = '';
    setState(() => _reloadKey++);
    _armTimeout();
  }

  void _fail(String why) {
    if (_reportedError || _ready) return;
    _reportedError = true;
    _lastError = why;
    _timeout?.cancel();
    if (mounted) setState(() => _failed = true);
    widget.onError?.call(why);
  }

  Future<dynamic> _eval(String js) async {
    try {
      return await _web?.evaluateJavascript(source: js);
    } catch (e) {
      _lastError = '$e';
      return null;
    }
  }

  Future<void> _sendPptx() async {
    if (_sent || !_pageLoaded) return;
    _sent = true;
    try {
      final Uint8List bytes = await File(widget.path).readAsBytes();
      final int total = math.max(1, (bytes.length / _chunkBytes).ceil());
      // 把**总字节数**一并传过去：页面据此一次性分配缓冲区。
      // 不给的话它只能边收边长（每块都重新分配 + 拷贝），27 MB 的 PPT
      // 峰值内存会翻倍，手机上的 WebView 很容易被系统杀掉 —— 表现出来
      // 就是"PPT 打不开"，而 Dart 只看到超时。
      final dynamic begun = await _eval(
        'window.beginPptx($total, ${bytes.length})',
      );
      if (begun == null && _lastError.isNotEmpty) {
        _fail('预览页初始化失败：$_lastError');
        return;
      }
      for (int i = 0; i < total; i++) {
        final int start = i * _chunkBytes;
        final int end = math.min(start + _chunkBytes, bytes.length);
        final String b64 = base64Encode(
          Uint8List.sublistView(bytes, start, end),
        );
        await _eval('window.addChunk("$b64")');
        // 每块之间让出一次事件循环：100+ 次 evaluateJavascript 如果
        // 一个接一个地挤在同一帧里，主线程会被 JS 解析串占满，
        // 用户看到的是"点了没反应"。
        if (i % 8 == 7) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      await _eval('window.finishPptx()');
    } catch (e) {
      _fail('读取文件失败：$e');
    }
  }

  /// 问页面一句"你到哪一步了"。
  ///
  /// 超时/失败时把这一步的结果塞进错误文案：否则用户只看到一句
  /// "渲染失败"，既不知道是库没加载、还是文件没有页面、还是内存不够。
  Future<String> _diagnose() async {
    final dynamic raw = await _eval(
      'JSON.stringify(window.pptxDiag ? window.pptxDiag() : null)',
    );
    if (raw is! String || raw.isEmpty || raw == 'null') return '';
    try {
      final dynamic j = jsonDecode(raw);
      if (j is! Map) return '';
      if (j['lib'] != true) return '预览组件没加载';
      final String err = (j['lastError'] ?? '').toString();
      if (err.isNotEmpty) return err;
      final int received = (j['received'] as num?)?.toInt() ?? 0;
      final int slides = (j['slides'] as num?)?.toInt() ?? 0;
      if (received == 0) return '文件内容没有送达预览页';
      if (slides > 0) return '已解析 $slides 页，排版未结束';
      return '文件已收到 ${(received / 1024).round()} KB，仍在解析';
    } catch (_) {
      return '';
    }
  }

  Future<void> showSlide(int index) async {
    if (!_ready) return;
    await _eval('window.showSlide($index)');
  }

  /// 取框选矩形（归一化 0..1）里的文字。取不到返回空串，由调用方兜底。
  Future<String> pickText(Rect norm) async {
    if (!_ready) return '';
    final double w = widget.width;
    final double h = widget.height;
    final String js =
        'window.pickText(${norm.left * w},${norm.top * h},'
        '${norm.right * w},${norm.bottom * h})';
    final dynamic res = await _eval(js);
    return (res is String ? res : '').trim();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    return InAppWebView(
      key: ValueKey<String>('pptx-web-$_reloadKey'),
      // **asset 路径**，不是绝对文件路径：插件会把它映射到
      // file:///android_asset/flutter_assets/... 后加载。
      initialFile: PptxWebPreview.assetPath,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        transparentBackground: true,
        supportZoom: false,
        disableVerticalScroll: true,
        disableHorizontalScroll: true,
        mediaPlaybackRequiresUserGesture: false,
        useHybridComposition: true,
        disableContextMenu: true,
        disableLongPressContextMenuOnLinks: true,
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        _web = controller;
        controller.addJavaScriptHandler(
          handlerName: 'pptx_ready',
          callback: (List<dynamic> args) {
            int count = 0;
            if (args.isNotEmpty && args.first is Map) {
              final dynamic c = (args.first as Map)['count'];
              if (c is num) count = c.toInt();
            }
            if (!mounted || _ready) return null;
            _ready = true;
            _timeout?.cancel();
            setState(() {});
            widget.onReady?.call(count);
            showSlide(widget.slideIndex);
            return null;
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'pptx_error',
          callback: (List<dynamic> args) {
            _fail(args.isEmpty ? '渲染失败' : args.first.toString());
            return null;
          },
        );
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) {
        _web = controller;
        _pageLoaded = true;
        unawaited(_sendPptx());
      },
      onReceivedError:
          (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceError error,
          ) {
            if (request.isForMainFrame == true) {
              _fail('预览页面加载失败：${error.description}');
            }
          },
    );
  }
}
