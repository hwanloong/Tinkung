import 'dart:math' as math;

/// 一个可读的控件节点。
///
/// 只保留模型真正用得上的字段：类名、文本、描述、资源 id、可操作标记和
/// 屏幕坐标。原始 AccessibilityNodeInfo 里的几十个字段既贵又没用。
class UiNode {
  const UiNode({
    required this.index,
    required this.cls,
    required this.text,
    required this.desc,
    required this.rid,
    required this.clickable,
    required this.editable,
    required this.scrollable,
    required this.selected,
    required this.focused,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.hint = '',
  });

  final int index;
  final String cls;
  final String text;
  final String desc;
  final String rid;
  final bool clickable;
  final bool editable;
  final bool scrollable;
  final bool selected;
  final bool focused;
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// 输入框的占位文字（`hintText` / aria-label）。
  ///
  /// 空搜索框的 `text` 是空串 —— 它唯一的名字就是这个占位符。
  /// 不给模型看，它面对的就是一个"没有名字的输入框"。
  final String hint;

  double get width => math.max(0, right - left);
  double get height => math.max(0, bottom - top);
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  factory UiNode.fromMap(Map<dynamic, dynamic> m, int index) {
    final List<dynamic> b =
        (m['bounds'] as List<dynamic>?) ?? const <dynamic>[0, 0, 0, 0];
    double at(int i) => i < b.length ? (b[i] as num?)?.toDouble() ?? 0.0 : 0.0;
    return UiNode(
      index: index,
      cls: m['cls']?.toString() ?? '',
      text: m['text']?.toString() ?? '',
      desc: m['desc']?.toString() ?? '',
      rid: m['rid']?.toString() ?? '',
      clickable: m['clickable'] == true,
      editable: m['editable'] == true,
      scrollable: m['scrollable'] == true,
      selected: m['selected'] == true,
      focused: m['focused'] == true,
      hint: m['hint']?.toString() ?? '',
      left: at(0),
      top: at(1),
      right: at(2),
      bottom: at(3),
    );
  }

  bool get actionable => clickable || editable || scrollable;

  /// 越"能操作"分越高，截断时优先保留。
  int get score {
    int s = 0;
    if (editable) s += 5;
    if (clickable) s += 4;
    if (scrollable) s += 3;
    if (text.trim().isNotEmpty) s += 2;
    if (desc.trim().isNotEmpty) s += 1;
    // 占位文字同样是一种"名字"：搜索框只有它，不能因为 text 空就被截掉。
    if (hint.trim().isNotEmpty) s += 1;
    if (focused) s += 2;
    return s;
  }

  /// 紧凑文本行：`[1] EditText "搜索" rid=id/search editable`
  ///
  /// 输入框空着时 `text` 是空的，这时显示 `hint="搜索"` —— 否则模型看到的
  /// 是一行 `[3] EditText editable`，完全不知道它是搜索框还是验证码框。
  String line() {
    final StringBuffer sb = StringBuffer('[$index] ');
    final String name = shortClass(cls);
    if (name.isNotEmpty) sb.write('$name ');
    if (text.trim().isNotEmpty) sb.write('"${escape(text)}" ');
    if (desc.trim().isNotEmpty) sb.write('desc="${escape(desc)}" ');
    if (hint.trim().isNotEmpty && text.trim().isEmpty) {
      sb.write('hint="${escape(hint)}" ');
    }
    if (rid.trim().isNotEmpty) sb.write('rid=${rid.trim()} ');
    if (editable) sb.write('editable ');
    if (clickable) sb.write('clickable ');
    if (scrollable) sb.write('scrollable ');
    if (selected) sb.write('selected ');
    if (focused) sb.write('focused ');
    return sb.toString().trimRight();
  }

  static String shortClass(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return '';
    return s.substring(s.lastIndexOf('.') + 1);
  }

  static String escape(String raw, {int max = 40}) {
    String s = raw
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ')
        .replaceAll('"', "'")
        .trim();
    if (s.length > max) s = '${s.substring(0, max)}…';
    return s;
  }
}

/// 一次界面快照。
class UiSnapshot {
  const UiSnapshot({
    required this.package,
    required this.activity,
    required this.width,
    required this.height,
    required this.nodes,
    required this.total,
    required this.truncated,
  });

  final String package;
  final String activity;
  final double width;
  final double height;
  final List<UiNode> nodes;
  final int total;
  final bool truncated;

  bool get isEmpty => nodes.isEmpty;

  factory UiSnapshot.fromMap(Map<dynamic, dynamic> m) {
    final List<dynamic> raw =
        (m['nodes'] as List<dynamic>?) ?? const <dynamic>[];
    final List<UiNode> nodes = <UiNode>[];
    for (int i = 0; i < raw.length; i++) {
      final dynamic e = raw[i];
      if (e is Map) nodes.add(UiNode.fromMap(e, i + 1));
    }
    return UiSnapshot(
      package: m['package']?.toString() ?? '',
      activity: m['activity']?.toString() ?? '',
      width: (m['width'] as num?)?.toDouble() ?? 0,
      height: (m['height'] as num?)?.toDouble() ?? 0,
      nodes: nodes,
      total: (m['total'] as num?)?.toInt() ?? nodes.length,
      truncated: m['truncated'] == true,
    );
  }

  /// 指纹用于"界面有没有变化"的轻量判断。
  /// FNV-1a：不依赖 String.hashCode（它只保证进程内稳定，且容易撞）。
  String fingerprint() {
    int h = 0x811c9dc5;
    for (final UiNode n in nodes) {
      final String s =
          '${n.rid}|${n.text}|${n.desc}|${n.left},${n.top},${n.right},${n.bottom};';
      for (final int c in s.codeUnits) {
        h ^= c;
        h = (h * 0x01000193) & 0xffffffff;
      }
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// 压成给模型看的文本。超过 [limit] 时先按可操作性挑，再按原顺序排。
  String format({int limit = 40}) {
    final List<UiNode> picked;
    if (nodes.length <= limit) {
      picked = List<UiNode>.of(nodes);
    } else {
      picked = List<UiNode>.of(nodes)
        ..sort((UiNode a, UiNode b) {
          final int byScore = b.score.compareTo(a.score);
          return byScore != 0 ? byScore : a.index.compareTo(b.index);
        });
      picked.removeRange(limit, picked.length);
      picked.sort((UiNode a, UiNode b) => a.index.compareTo(b.index));
    }
    final StringBuffer sb = StringBuffer();
    for (final UiNode n in picked) {
      sb.writeln(n.line());
    }
    final int hidden = nodes.length - picked.length;
    if (hidden > 0) sb.writeln('（已截断 $hidden 个节点）');
    return sb.toString().trimRight();
  }

  /// 与原生 `findNode` 同一套优先级，供 `wait_for` 和离线测试使用。
  UiNode? findTarget(Map<String, dynamic> target) {
    String rid = target['rid']?.toString().trim() ?? '';
    final String text = target['text']?.toString().trim() ?? '';
    final String desc = target['desc']?.toString().trim() ?? '';
    final int index = (target['index'] as num?)?.toInt() ?? -1;

    if (rid.startsWith('id/')) rid = rid.substring(3);
    if (rid.contains(':id/')) rid = rid.substring(rid.indexOf(':id/') + 4);

    if (rid.isNotEmpty) {
      for (final UiNode n in nodes) {
        final String full = n.rid.contains(':id/')
            ? n.rid.substring(n.rid.indexOf(':id/') + 4)
            : (n.rid.startsWith('id/') ? n.rid.substring(3) : n.rid);
        if (full == rid) return n;
      }
    }
    if (text.isNotEmpty) {
      for (final UiNode n in nodes) {
        if (n.text.trim() == text) return n;
      }
      for (final UiNode n in nodes) {
        if (n.text.toLowerCase().contains(text.toLowerCase())) return n;
      }
    }
    if (desc.isNotEmpty) {
      for (final UiNode n in nodes) {
        if (n.desc.toLowerCase().contains(desc.toLowerCase())) return n;
      }
    }
    // 空输入框的 text 是空串，它的名字只剩占位文字 —— 只对可编辑节点生效，
    // 免得把一条写同样字样的标题当成输入框。
    if (text.isNotEmpty) {
      for (final UiNode n in nodes) {
        if (n.editable && n.hint.toLowerCase().contains(text.toLowerCase())) {
          return n;
        }
      }
      for (final UiNode n in nodes) {
        if (n.editable && n.desc.toLowerCase().contains(text.toLowerCase())) {
          return n;
        }
      }
    }
    if (index >= 0 && index < nodes.length) return nodes[index];
    return null;
  }
}

/// 画布矩形（屏幕像素）。
class CanvasRect {
  const CanvasRect(this.x, this.y, this.w, this.h);
  final double x;
  final double y;
  final double w;
  final double h;

  factory CanvasRect.fromMap(Map<dynamic, dynamic> m) => CanvasRect(
    (m['x'] as num?)?.toDouble() ?? 0,
    (m['y'] as num?)?.toDouble() ?? 0,
    (m['w'] as num?)?.toDouble() ?? 0,
    (m['h'] as num?)?.toDouble() ?? 0,
  );

  bool get valid => w > 1 && h > 1;

  /// 把归一化路径（0–1）映射到屏幕坐标。超出范围的点直接夹住，
  /// 避免一笔画到屏幕外触发系统手势。
  List<List<List<double>>> mapNormalized(List<List<List<double>>> strokes) {
    return strokes
        .map(
          (List<List<double>> s) => s
              .map(
                (List<double> p) => <double>[
                  x + p[0].clamp(0.0, 1.0).toDouble() * w,
                  y + p[1].clamp(0.0, 1.0).toDouble() * h,
                ],
              )
              .toList(),
        )
        .toList();
  }
}

/// 简单校验：每笔至少两个点、总数不超上限。
String? validateStrokes(
  List<List<List<double>>> strokes, {
  int maxPoints = 4000,
}) {
  if (strokes.isEmpty) return 'strokes 不能为空';
  int count = 0;
  for (int i = 0; i < strokes.length; i++) {
    final List<List<double>> s = strokes[i];
    if (s.length < 2) return '第 ${i + 1} 笔至少需要两个点';
    count += s.length;
  }
  if (count > maxPoints) return '点数 $count 超过上限 $maxPoints，请先简化路径';
  return null;
}

/// 把 `[[x,y],[x,y]]` 解析成点列。
List<List<double>> parseStroke(dynamic raw) {
  if (raw is! List) return <List<double>>[];
  final List<List<double>> out = <List<double>>[];
  for (final dynamic item in raw) {
    if (item is! List || item.length < 2) continue;
    final double? x = (item[0] as num?)?.toDouble();
    final double? y = (item[1] as num?)?.toDouble();
    if (x == null || y == null) continue;
    out.add(<double>[x, y]);
  }
  return out;
}

/// 接受三种 JSON 形态：
/// `{"strokes":[[[x,y],...]]}`、`[[[x,y],...]]`、`{"points":[[x,y],...]}`。
List<List<List<double>>> parseStrokes(dynamic raw) {
  dynamic src = raw;
  if (raw is Map) {
    src = raw['strokes'] ?? raw['points'] ?? raw['path'];
  }
  if (src is! List || src.isEmpty) return <List<List<double>>>[];
  final List<dynamic> list = src;

  // 扁平的一笔：[[x,y],[x,y]]
  final bool single =
      list.first is List &&
      (list.first as List).isNotEmpty &&
      (list.first as List)[0] is num;
  if (single) {
    final List<List<double>> one = parseStroke(list);
    return one.isEmpty ? <List<List<double>>>[] : <List<List<double>>>[one];
  }

  return list
      .map((dynamic s) => parseStroke(s))
      .where((List<List<double>> s) => s.isNotEmpty)
      .toList();
}

/// 计算一笔手势的建议时长：按路径长度 / 速度，夹在 120–8000ms。
int strokeDuration(List<List<double>> points, {double speed = 900}) {
  double len = 0;
  for (int i = 1; i < points.length; i++) {
    final double dx = points[i][0] - points[i - 1][0];
    final double dy = points[i][1] - points[i - 1][1];
    len += math.sqrt(dx * dx + dy * dy);
  }
  return (len / speed * 1000).round().clamp(120, 8000).toInt();
}
