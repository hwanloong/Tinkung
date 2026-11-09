import 'dart:convert';
import 'dart:io';

/// 「上一次在这儿点的是什么」—— 看图点坐标之后的记忆。
///
/// ## 它解决什么
///
/// 视觉方案（看着截图点坐标）是**最后一条永远可用的路**，但也是最贵的一条：
/// 要截图、要模型真去看那张图、还要对准像素。而同一个界面上的同一个东西，
/// 一个任务里往往要点好几次（翻页、展开、下一步）。
/// 每次都拿坐标去点是纯浪费 —— 而且比选择器脆得多：页面滚一点、横幅插进来，
/// 同一个坐标就不是同一个东西了。
///
/// 所以：**第一次**用坐标点中某样东西时，顺手把"怎么用非视觉的方式找到它"
/// 记下来（优先选择器，其次可见文字）。下次再点到同一片区域，
/// **先用记下来的方式点**；记的那条失效了（改版、元素没了），再退回坐标。
///
/// 这正是用户要的"点按之后记住这条路，下次先走非视觉方案"。
///
/// ## 两个刻意的设计
///
///  · **按格子记，不按精确像素**：第二次给坐标不会和第一次分毫不差，
///    差几十像素是常态。所以坐标按 [bucket] 分格，同一格算"同一个地方"。
///  · **认位置，不认死**：召回时还要核对"记下的那个元素**现在**还在不在这个
///    位置附近"。页面重新排版之后，同一个坐标可能变成了别的东西 ——
///    那时候宁可退回坐标重新看，也不能照着一份过期的记忆点下去
///    （点错比点不到更糟：点不到模型会换路，点错了它以为成了）。
///
/// 文件坏了、写不进去、目录不存在 —— 一律**当空记忆**处理，
/// 绝不能让"记笔记"这件事本身把一次点击搞失败。
class VisualMemo {
  VisualMemo({
    required this.file,
    this.limit = 200,
    this.bucket = 40,
    this.drift = 80,
  });

  final File file;

  /// 最多记多少条。满了淘汰最久没用过的 —— 一份无限长大的记忆，
  /// 最后会变成"每次都命中一条早就没用的记录"。
  final int limit;

  /// 坐标分格的边长（截图上的像素）。
  final double bucket;

  /// 召回时的容忍位移（截图上的像素）：记下的元素中心离这次点的位置
  /// 超过这个距离，就认为页面已经变了，不再用这条记忆。
  final double drift;

  /// key = `页面|格x,格y`，value = `{k, sel, txt, label, hits, ts}`。
  final Map<String, Map<String, dynamic>> _byKey =
      <String, Map<String, dynamic>>{};

  int get length => _byKey.length;

  /// 页面身份：**主机 + 路径**。
  ///
  /// 查询串不参与 —— 同一个页面换个 `?page=2` 还是同一个页面，
  /// 而"下一页"按钮永远在同一个地方。带上查询串的话，
  /// 记忆会在每次翻页后全部失配，等于没记。
  static String pageKeyOf(String url) {
    final String u = url.trim();
    if (u.isEmpty) return '';
    try {
      final Uri parsed = Uri.parse(u);
      if (parsed.host.isEmpty) return u.split('?').first;
      return '${parsed.host}${parsed.path}';
    } catch (_) {
      return u.split('?').first;
    }
  }

  String _keyOf(String url, double x, double y) {
    final int bx = (x / bucket).floor();
    final int by = (y / bucket).floor();
    return '${pageKeyOf(url)}|$bx,$by';
  }

  /// 查：这个页面、这个坐标附近，上次记下来的是什么。没有就返回 null。
  Map<String, dynamic>? recall(String url, double x, double y) {
    final String k = _keyOf(url, x, y);
    for (final String cand in <String>[
      k,
      // 差一格也算——人的手和模型的眼都不会每次都落在同一格里。
      // 但只做**相邻一格**：再多就漫游到别的按钮上去了。
      ..._neighbours(k),
    ]) {
      final Map<String, dynamic>? e = _byKey[cand];
      if (e == null) continue;
      final String sel = (e['sel'] ?? '').toString();
      final String txt = (e['txt'] ?? '').toString();
      if (sel.isEmpty && txt.isEmpty) continue;
      return e;
    }
    return null;
  }

  Iterable<String> _neighbours(String k) sync* {
    final int bar = k.lastIndexOf('|');
    if (bar < 0) return;
    final String page = k.substring(0, bar);
    final List<String> xy = k.substring(bar + 1).split(',');
    if (xy.length != 2) return;
    final int? bx = int.tryParse(xy[0]);
    final int? by = int.tryParse(xy[1]);
    if (bx == null || by == null) return;
    for (final List<int> d in <List<int>>[
      <int>[1, 0],
      <int>[-1, 0],
      <int>[0, 1],
      <int>[0, -1],
      <int>[1, 1],
      <int>[-1, -1],
      <int>[1, -1],
      <int>[-1, 1],
    ]) {
      yield '$page|${bx + d[0]},${by + d[1]}';
    }
  }

  /// 记下：这一下点在那个位置，它是谁、怎么用非视觉的方式找到它。
  ///
  /// [atX]/[atY] 是那个元素的中心在**文档坐标**里的位置（不是这次点的坐标）。
  /// 存它，是为了下次召回时能回答"它还在原来那一带吗" —— 页面重排之后，
  /// 同一个位置可能已经是别的东西了。
  void note(
    String url,
    double x,
    double y, {
    required String selector,
    required String text,
    required String label,
    double atX = 0,
    double atY = 0,
  }) {
    final String sel = selector.trim();
    final String txt = text.trim();
    // 两样都没有 = 这条记忆没用（下次拿什么找？），干脆不记。
    if (sel.isEmpty && txt.isEmpty) return;
    final String key = _keyOf(url, x, y);
    final Map<String, dynamic>? old = _byKey[key];
    _byKey[key] = <String, dynamic>{
      'k': key,
      'sel': sel,
      'txt': txt,
      'label': label.length > 60 ? label.substring(0, 60) : label,
      'at': <String, double>{'x': atX, 'y': atY},
      'hits': (old?['hits'] as int? ?? 0) + 1,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    _trim();
  }

  /// 召回失败了：这条记忆是过期的，删掉。
  ///
  /// 留着它的唯一后果就是"下次再白试一次"，连带让"这条记忆还准不准"
  /// 这件事变得没人说得清。
  void forget(String key) => _byKey.remove(key);

  void _trim() {
    if (_byKey.length <= limit) return;
    final List<String> keys = _byKey.keys.toList()
      ..sort(
        (String a, String b) => ((_byKey[a]?['ts'] as int?) ?? 0).compareTo(
          (_byKey[b]?['ts'] as int?) ?? 0,
        ),
      );
    for (final String k in keys.take(_byKey.length - limit)) {
      _byKey.remove(k);
    }
  }

  /// 从盘上读回来。文件不在 / 坏了 / 没权限 —— 都当"没有记忆"。
  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final dynamic decoded = jsonDecode(raw);
      final List<dynamic> list = decoded is Map && decoded['items'] is List
          ? decoded['items'] as List<dynamic>
          : (decoded is List ? decoded : <dynamic>[]);
      for (final dynamic item in list) {
        if (item is! Map) continue;
        final String k = (item['k'] ?? '').toString();
        if (k.isEmpty) continue;
        _byKey[k] = Map<String, dynamic>.from(item);
      }
      _trim();
    } catch (_) {
      // 记忆读不出来不该影响任何功能
    }
  }

  /// 写回盘上。写不进去（没权限、目录没了）就算了 —— 只是下次少一条捷径。
  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<String, dynamic>{'v': 1, 'items': _byKey.values.toList()}),
      );
    } catch (_) {
      // 同上
    }
  }

  /// 给模型看的一句话清单（`status` / 排查时用）。
  List<String> describe() => _byKey.values
      .map(
        (Map<String, dynamic> e) =>
            '${e['k']} → ${(e['sel'] ?? '').toString().isNotEmpty ? e['sel'] : '文字「${e['txt']}」'}'
            '${(e['label'] ?? '').toString().isEmpty ? '' : '（${e['label']}）'}',
      )
      .toList();
}
