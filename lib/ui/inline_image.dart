import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/platform_files.dart';
import '../theme/app_theme.dart';

/// **正文里的一张图**：本地文件或网络图片都吃。
///
/// ## 为什么本地和网络要在同一个组件里判断
///
/// 模型给图有两种来源：自己生成的（本地绝对路径）和外部服务的
/// （`https://…`）。对写提示词的人来说只是"给个地址"，
/// 所以渲染端必须自己分辨 —— 让模型去想"这张该用哪种语法"是
/// 把实现细节泄漏给了它，而且它一定会写错。
///
/// 判定规则很简单：带 `://` 且以 `http` 开头就是网络图，其余当本地路径。
///
/// ## 为什么失败时要显示**具体原因**
///
/// 图片加载失败的原因差别很大：文件被清了 / 路径写错 / 网络不通 /
/// 服务返回 404。这些的处理方式完全不同，而一张破图图标谁也看不懂。
/// 所以这里把"路径 + 原因"都写出来。
class InlineImage extends StatelessWidget {
  const InlineImage({super.key, required this.src, this.alt = ''});

  /// 图片来源：本地绝对路径或 http(s) 地址。
  final String src;

  /// 替代文字。加载失败时显示，也用来当说明。
  final String alt;

  /// 高度上限。
  ///
  /// 不设上限的话，一张竖构图的长图会把整条消息撑到几屏高，
  /// 后面的文字要滚很久才看得到。400 足够看清内容，
  /// 想看细节可以点开全屏（见下面 `onTap`）。
  static const double _maxHeight = 400;

  bool get _isRemote => src.startsWith('http://') || src.startsWith('https://');

  /// 本地路径的几种写法统一成 File 能用的形式。
  ///
  /// `file://` 前缀要剥掉：模型有时会写成 URI 形式，
  /// 而 `File('file:///a.png')` 会报"文件不存在" —— 那条错误
  /// 看起来像"图没了"，实际只是多了个前缀。
  String get _localPath =>
      src.startsWith('file://') ? Uri.parse(src).toFilePath() : src;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.code),
        child: Container(
          decoration: BoxDecoration(
            color: s.codeBg,
            borderRadius: BorderRadius.circular(AppRadius.code),
            border: Border.all(color: s.border, width: 0.7),
          ),
          child: GestureDetector(
            // 点开全屏：正文里的宽度有限，图纸/截图里的字看不清。
            onTap: () => _openFullscreen(context),
            child: Stack(
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: _maxHeight),
                  child: _isRemote ? _network(s) : _local(s, context),
                ),
                // ---- 右下角「保存到本地」 ----
                //
                // 用户要的：正文里由 AI 给出来的图，要能直接存下来。
                // 以前只能点开全屏（全屏那边也刚加了保存），多一步；
                // 而且"这张图我要留着"是很直接的动作，不该藏在下一层。
                //
                // 放在图上而不是图下面：图本身高度不定，放下面会把行高
                // 撑出一块空白。半透明黑底保证在任何照片上都看得清。
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: GestureDetector(
                    onTap: () => _save(context),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        color: Color(0x99000000),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.download_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 存到系统相册（非图片进「下载」）。
  ///
  /// 网络图要**先下下来**：原生那侧只认本地文件，把 http 地址丢给它
  /// 只会得到一句"文件不存在"。
  Future<void> _save(BuildContext context) async {
    String? err;
    if (_isRemote) {
      File? tmp;
      try {
        final http.Response r = await http
            .get(Uri.parse(src))
            .timeout(const Duration(seconds: 60));
        if (r.statusCode != 200) {
          err = '下载失败：HTTP ${r.statusCode}';
        } else {
          final String name = _fileName();
          tmp = File('${Directory.systemTemp.path}/$name');
          await tmp.writeAsBytes(r.bodyBytes);
          err = await PlatformFiles.save(tmp.path, name: name);
        }
      } catch (e) {
        err = '下载失败：$e';
      } finally {
        try {
          await tmp?.delete();
        } catch (_) {}
      }
    } else {
      final String p = _localPath;
      err = await PlatformFiles.save(p, name: p.split('/').last);
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ?? '已保存到系统相册/下载目录'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 存盘用的文件名：取地址最后一段，去掉查询串；空的话给个兜底名。
  String _fileName() {
    if (!_isRemote) return _localPath.split('/').last;
    final Uri? u = Uri.tryParse(src);
    final String last = (u?.pathSegments.isNotEmpty ?? false)
        ? u!.pathSegments.last
        : '';
    if (last.isEmpty) return 'image.jpg';
    // 没有扩展名的（有些图床地址是纯 id）补一个，否则系统会当成未知类型
    return last.contains('.') ? last : '$last.jpg';
  }

  Widget _network(AppSurface s) {
    return Image.network(
      src,
      fit: BoxFit.contain,
      width: double.infinity,
      loadingBuilder:
          (BuildContext _, Widget child, ImageChunkEvent? progress) {
            if (progress == null) return child;
            return SizedBox(
              height: 140,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                    value: progress.expectedTotalBytes == null
                        ? null
                        : progress.cumulativeBytesLoaded /
                              progress.expectedTotalBytes!,
                  ),
                ),
              ),
            );
          },
      errorBuilder: (BuildContext _, Object e, StackTrace? _) =>
          _failed(s, '网络图片加载失败', src),
    );
  }

  Widget _local(AppSurface s, BuildContext context) {
    final File f = File(_localPath);
    // 先查存在性再交给 Image.file：`Image.file` 的 errorBuilder 给的
    // 异常信息在多平台上不一致，而且"文件不存在"这个最常见的原因
    // 值得单独说清楚。
    if (!f.existsSync()) {
      return _failed(s, '文件不存在', _localPath);
    }
    // 正文里的插图按**屏幕宽度**解码就够：原图动辄 4000px，
    // 按原分辨率解码一张就是几十兆位图，长图文页面会因此明显卡顿。
    final double dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    final double w = MediaQuery.maybeOf(context)?.size.width ?? 400;
    final int px = (w * dpr).round();
    return Image.file(
      f,
      fit: BoxFit.contain,
      width: double.infinity,
      cacheWidth: px,
      errorBuilder: (BuildContext _, Object e, StackTrace? _) =>
          _failed(s, '无法读取这个文件', '$_localPath\n$e'),
    );
  }

  /// 失败态：**把原因和路径都写出来**，而不是一个破图图标。
  Widget _failed(AppSurface s, String why, String detail) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
      color: s.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.broken_image_outlined, size: 22, color: s.muted),
          const SizedBox(height: 8),
          Text(
            alt.isEmpty ? why : '$why：$alt',
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 12.5, color: s.text, height: 1.4),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.code(size: 11, color: s.muted),
          ),
        ],
      ),
    );
  }

  void _openFullscreen(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => _ImageFullscreen(
          src: src,
          alt: alt,
          isRemote: _isRemote,
          localPath: _localPath,
        ),
      ),
    );
  }
}

/// 全屏看图：双指缩放 + 拖动。
///
/// 用 `InteractiveViewer` 而不是自己处理手势：缩放/平移的边界回弹、
/// 双指中心点这些细节自己写很容易做得"能缩放但手感很怪"。
class _ImageFullscreen extends StatelessWidget {
  const _ImageFullscreen({
    required this.src,
    required this.alt,
    required this.isRemote,
    required this.localPath,
  });

  final String src;
  final String alt;
  final bool isRemote;
  final String localPath;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Scaffold(
      // 看图用纯黑底：任何色调的背景都会影响对图片明暗的判断，
      // 而用户在这个页面上唯一的目的是"看清楚这张图"。
      backgroundColor: AppColors.imageBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          alt.isEmpty ? '图片' : alt,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.body(size: 14, color: Colors.white),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 6,
          child: isRemote
              ? Image.network(
                  src,
                  fit: BoxFit.contain,
                  errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                      _err(s),
                )
              : Image.file(
                  File(localPath),
                  fit: BoxFit.contain,
                  errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                      _err(s),
                ),
        ),
      ),
    );
  }

  Widget _err(AppSurface s) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      '打不开这张图\n$src',
      textAlign: TextAlign.center,
      style: AppFonts.body(size: 13, color: Colors.white70, height: 1.6),
    ),
  );
}
