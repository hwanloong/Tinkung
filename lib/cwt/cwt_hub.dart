import 'dart:async';
import 'dart:ui';

/// AI 请求打开 ChangeWhatYouThink。
class CwtRequest {
  const CwtRequest({
    required this.convId,
    required this.path,
    required this.brief,
  });

  final String convId;
  final String path;
  final String brief;
}

/// 一个选框。
class CwtBox {
  const CwtBox({
    required this.rect,
    required this.description,
    this.page = 0,
    this.location = '',
    this.selectedText = '',
    this.cropPath = '',
  });

  /// 归一化坐标（0..1），相对于**预览内容本身**，不是屏幕。
  final Rect rect;
  final String description;

  /// 预览的分页编号（0 开始）。图片固定 0；Excel 是「工作表×1000 + 屏」。
  final int page;

  /// 给模型看的位置标签，如「幻灯片 3」「成绩 第 2 屏」「第 4 页」。
  final String location;

  /// Office 预览里框到的文字（给模型最可靠的定位）。
  final String selectedText;

  /// 图片 / PDF 局部截图，模型可以 read_image 看细节。
  final String cropPath;
}

/// ChangeWhatYouThink 的结果：一次可能有多处修改。
class CwtResult {
  const CwtResult({required this.path, required this.boxes});

  final String path;
  final List<CwtBox> boxes;

  /// 变成给模型的**结构化修改请求**。发送到聊天里时原样带上。
  String toPrompt() {
    final StringBuffer sb = StringBuffer();
    sb.writeln('【ChangeWhatYouThink 修改请求】');
    sb.writeln('文件：$path');
    for (int i = 0; i < boxes.length; i++) {
      final CwtBox b = boxes[i];
      String pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
      sb.writeln(
        '选框 ${i + 1}：x=${pct(b.rect.left)} y=${pct(b.rect.top)} '
        'w=${pct(b.rect.width)} h=${pct(b.rect.height)}'
        '${b.location.isNotEmpty ? ' · ${b.location}' : (b.page > 0 ? ' · 第 ${b.page + 1} 页' : '')}',
      );
      sb.writeln('修改要求：${b.description.trim()}');
      if (b.selectedText.trim().isNotEmpty) {
        final String t = b.selectedText.trim();
        sb.writeln('选中的原文：${t.length > 800 ? '${t.substring(0, 800)}…' : t}');
      }
      if (b.cropPath.trim().isNotEmpty) {
        sb.writeln('局部截图：${b.cropPath}（可用 read_image 查看）');
      }
    }
    sb.writeln(
      '请按以上要求修改这个文件：只改选框覆盖的范围/内容，保留其它部分；'
      '改完说明改了哪里。源文件与备份都不要删。',
    );
    return sb.toString();
  }
}

/// CWT 的打开请求通道（工具在 AgentRunner 里，拿不到 ChatPage 的 context）。
class CwtHub {
  CwtHub._();

  static final CwtHub instance = CwtHub._();

  final StreamController<CwtRequest> _opens =
      StreamController<CwtRequest>.broadcast();

  Stream<CwtRequest> get opens => _opens.stream;

  void open(CwtRequest request) => _opens.add(request);
}
