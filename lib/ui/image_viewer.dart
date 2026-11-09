import 'dart:io';

import 'package:flutter/material.dart';

import '../core/platform_files.dart';

/// 全屏看图：点消息里的图片就进来。
///
/// ## 为什么必须有一个（而不是"点一下打开系统相册/图库"）
///
/// 聊天里的图有两类来源：用户自己选的（在私有目录里）和 agent 生成/下载的
/// （也在私有目录里）。**系统图库看不到这些路径** —— 让用户"去相册找"
/// 等于告诉他这张图看不了。所以应用自己得能看：看得清（可缩放）、
/// 退得出（点一下关掉）。
///
/// 用**不透明路由 + 半透明遮罩**而不是 `showDialog`：图要占满整屏、
/// 背景压暗但还能看出"我还在对话里"。
Future<void> showImageViewer(
  BuildContext context, {
  required String path,
  String title = '',
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black.withValues(alpha: 0.92),
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (BuildContext _, Animation<double> _, Animation<double> _) =>
          _ImageViewer(path: path, title: title),
      transitionsBuilder: (
        BuildContext _,
        Animation<double> a,
        Animation<double> _,
        Widget child,
      ) => FadeTransition(opacity: a, child: child),
    ),
  );
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.path, required this.title});

  final String path;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 底色交给路由的 barrier —— 这样对话仍隐约可见，
      // 用户知道自己没"被弹到另一个应用里"。
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                // 点空白处退出（大图上点一下也是退出 —— 这是看图页的惯例，
                // 缩放开合交给双指，别和"点一下"抢）。
                onTap: () => Navigator.of(context).maybePop(),
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 6,
                  child: Center(
                    child: Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                          const _Broken(),
                    ),
                  ),
                ),
              ),
            ),
            // ---- 右上角：保存 / 关闭 ----
            //
            // 这里原来还有一行**文件名**。问题有两个：
            //  · 它和右边的按钮不在一条线上（一个是 `top: 16` 的正文，
            //    一个是 48 高的按钮，基线永远差半个）；
            //  · 看图的时候名字其实没什么用 —— 图已经在眼前了。
            // 所以按用户的意思：**去掉名字，加一个"保存到本地"**。
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.download_rounded),
                    iconSize: 22,
                    tooltip: '保存到本地',
                    color: Colors.white,
                    onPressed: () => _save(context),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    iconSize: 22,
                    tooltip: '关闭',
                    color: Colors.white,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 存到「图片/Zeus」（非图片进「下载」）。
  ///
  /// 成功/失败都要说一句：这个动作在系统里是"没有界面的"，
  /// 不给反馈用户只会以为按钮没反应。
  Future<void> _save(BuildContext context) async {
    final String? err = await PlatformFiles.save(path, name: title);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ?? '已保存到系统相册/下载目录'),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

/// 图打不开时说的话 —— 和别处一致：**事实**，不是"加载失败"。
class _Broken extends StatelessWidget {
  const _Broken();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.broken_image_outlined, size: 34, color: Colors.white70),
          SizedBox(height: 10),
          Text(
            '这张图读不出来了。\n'
            '常见原因：文件被清理掉了（存储空间里删过），或者当初没复制进应用目录。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12.5,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
