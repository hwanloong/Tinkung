import 'dart:convert';
import 'dart:io';

import '../core/a11y.dart';
import '../core/models.dart';
import '../core/ui_tree.dart';
import '../shizuku/shizuku_service.dart';
import 'tool.dart';

const String _a11yHint =
    '无障碍服务未开启：设置 → 无障碍 → 已下载的服务 → Zeus 手机控制。'
    'Android 13+ 若显示「受限设置」，先到应用信息里允许受限设置。';

/// 读取当前界面的控件树。
///
/// 输出是紧凑文本，不是 XML/JSON —— 40 行足够模型定位，原始 XML
/// 动辄几千 token，还会把注意力淹掉。
class UiTreeTool extends AgentTool {
  const UiTreeTool();

  /// 同一场对话里上一次的指纹。界面没变时不重复输出整棵树，
  /// 这是最便宜的 token 保护。
  static final Map<String, String> _last = <String, String>{};

  @override
  String get name => 'ui_tree';

  @override
  String get title => '界面控件';

  @override
  String get description =>
      '读取当前手机界面的**控件树**（紧凑文本）。做手机操作前先用它，'
      '不要靠截图猜坐标。返回前台包名、屏幕尺寸和最多 40 个可操作/有文字的控件，'
      '每行格式：[序号] 类名 "文本" desc="描述" hint="占位" rid=资源ID 标记。\n'
      '**输入框空着时它的文本就是空的**，这时看 hint="…" —— 那就是界面上'
      '显示的灰字提示（搜索框、验证码框都靠它区分）。'
      '把 hint 的文字传给 ui_action 的 target.text 就能定位。\n'
      '界面没变化时会返回一句「与上次相同」，需要重新确认可传 force=true。\n'
      '如果返回「没有可读控件」，说明是游戏/地图/视频这类画布界面，'
      '改用 screen_capture + read_image 看截图。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'limit': <String, dynamic>{
        'type': 'integer',
        'description': '最多输出多少个节点，默认 40，上限 80',
      },
      'force': <String, dynamic>{
        'type': 'boolean',
        'description': 'true 时即使和上次相同也完整输出，默认 false',
      },
    },
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) => '读取界面控件';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final UiSnapshot? snap = await A11y.dump();
    if (snap == null) {
      return '读取失败。$_a11yHint';
    }
    if (snap.nodes.isEmpty) {
      return '当前界面（${snap.package}）没有可读控件。\n'
          '这通常是游戏、地图、视频或自绘画布 —— 请用 screen_capture 截图，'
          '再 read_image 观察，然后用 ui_action 的 xy 兜底点击。';
    }
    if (snap.nodes.length < 2) {
      // 画布类界面经常只剩一个 SurfaceView / 根容器。继续按控件操作
      // 只会让模型对着一条无意义节点打转，直接提示它换截图。
      return '当前界面只读到 ${snap.nodes.length} 个控件（${snap.package}），'
          '多半是画布类界面。\n${snap.format(limit: 5)}\n'
          '请改用 screen_capture + read_image 看画面，再用 ui_action 的 xy 兜底。';
    }

    final String fp = snap.fingerprint();
    final String key = ctx.conversation.id;
    final bool same = _last[key] == fp;
    _last[key] = fp;
    if (same && args['force'] != true) {
      return '界面与上次相同（指纹 $fp），未重复输出。\n'
          '直接基于上一条控件树继续操作；确实要重看就传 force=true。';
    }

    final int limit = ((args['limit'] as num?)?.toInt() ?? 40)
        .clamp(1, 80)
        .toInt();
    final StringBuffer sb = StringBuffer();
    sb.writeln('前台：${snap.package}');
    if (snap.activity.isNotEmpty) sb.writeln('窗口：${snap.activity}');
    sb.writeln('屏幕：${snap.width.round()}×${snap.height.round()}');
    sb.writeln(snap.format(limit: limit));
    if (snap.truncated) sb.writeln('（原生侧还有节点未返回）');
    return sb.toString().trimRight();
  }
}

/// 语义动作：不猜坐标，按 rid / text / desc 找控件。
class UiActionTool extends AgentTool {
  const UiActionTool();

  @override
  String get name => 'ui_action';

  @override
  String get title => '手机操作';

  @override
  String get description =>
      '在手机界面上执行一个动作。target 按 rid → text 精确 → text 包含 → '
      'desc → hint（输入框占位文字）→ index → xy 的顺序找控件，找到后用无障碍语义点击；'
      '控件不响应时自动改成点它的中心坐标。\n'
      'op 取值：click、set_text、scroll_forward、scroll_backward、'
      'swipe、tap、back、home、recents、wait_for、launch、open_url。\n'
      '**输入框空着时用 hint 认它**：ui_tree 里形如 `EditText hint="搜索" editable`，'
      '把 hint 的文字传给 target.text 即可（不区分大小写、可只给一部分）。\n'
      '执行后会回读界面并告诉你有没有变化；返回「未变化」时不要原样重试，'
      '先 ui_tree 看当前状态。\n'
      'index 就是 ui_tree 行首的序号。xy 是屏幕像素，只作最后兜底。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'op': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'click',
          'set_text',
          'scroll_forward',
          'scroll_backward',
          'swipe',
          'tap',
          'back',
          'home',
          'recents',
          'wait_for',
          'launch',
          'open_url',
        ],
      },
      'target': <String, dynamic>{
        'type': 'object',
        'description':
            '控件目标，可组合 rid/text/desc/index；'
            '也可给 x/y（tap）或 x1/y1/x2/y2（swipe）',
        'properties': <String, dynamic>{
          'rid': <String, dynamic>{'type': 'string'},
          'text': <String, dynamic>{'type': 'string'},
          'desc': <String, dynamic>{'type': 'string'},
          'index': <String, dynamic>{'type': 'integer'},
          'x': <String, dynamic>{'type': 'number'},
          'y': <String, dynamic>{'type': 'number'},
          'x1': <String, dynamic>{'type': 'number'},
          'y1': <String, dynamic>{'type': 'number'},
          'x2': <String, dynamic>{'type': 'number'},
          'y2': <String, dynamic>{'type': 'number'},
        },
      },
      'value': <String, dynamic>{
        'type': 'string',
        'description': 'set_text 要写入的文本；launch 的包名；open_url 的网址',
      },
      'duration': <String, dynamic>{
        'type': 'integer',
        'description': 'swipe 时长（毫秒），默认 400',
      },
      'steps': <String, dynamic>{
        'type': 'integer',
        'description': 'swipe 轨迹点数，默认 12；连续拖动可调大',
      },
      'timeout': <String, dynamic>{
        'type': 'integer',
        'description': 'wait_for 超时秒数，默认 5',
      },
    },
    'required': <String>['op'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    final String op = args['op']?.toString() ?? '';
    if (op == 'set_text' ||
        op == 'swipe' ||
        op == 'launch' ||
        op == 'open_url') {
      return const RiskAssessment(RiskLevel.caution, <String>['会改变其他应用的状态']);
    }
    return RiskAssessment.safe;
  }

  /// 手机操作的价值就在连续执行；每一步都弹确认框会把自动化变成点按练习。
  /// 风险等级照实显示，关掉的只是确认框。
  @override
  bool get autoApprove => true;

  @override
  String summarize(Map<String, dynamic> args) {
    final String op = args['op']?.toString() ?? '';
    final Map<String, dynamic> t =
        (args['target'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    final String what =
        t['rid']?.toString() ??
        t['text']?.toString() ??
        t['desc']?.toString() ??
        args['value']?.toString() ??
        '';
    return what.isEmpty ? op : '$op $what';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String op = args['op']?.toString() ?? '';
    final Map<String, dynamic> target =
        (args['target'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};

    switch (op) {
      case 'back':
      case 'home':
      case 'recents':
        final A11yResult r = await A11y.action(op: op);
        return _result(r);

      case 'launch':
        return _launch(ctx, args['value']?.toString().trim() ?? '');

      case 'open_url':
        return _openUrl(ctx, args['value']?.toString().trim() ?? '');

      case 'wait_for':
        return _waitFor(target, args['timeout'] as num?);

      case 'swipe':
        return _swipe(target, args);

      case 'tap':
        final double? x = (target['x'] as num?)?.toDouble();
        final double? y = (target['y'] as num?)?.toDouble();
        if (x == null || y == null) {
          return 'BAD_ARG：tap 需要 target.x 和 target.y';
        }
        final A11yResult r = await A11y.tapAt(x, y);
        return _result(r);

      case 'click':
        // 只给了 xy 的点击不必进控件树查找 —— 直接按坐标点。
        if (target['x'] is num &&
            target['y'] is num &&
            target['rid'] == null &&
            target['text'] == null &&
            target['desc'] == null &&
            target['index'] == null) {
          final A11yResult tapped = await A11y.tapAt(
            (target['x'] as num).toDouble(),
            (target['y'] as num).toDouble(),
          );
          return _result(tapped);
        }
        return _act(ctx, op, target, args['value']?.toString() ?? '');

      case 'set_text':
      case 'scroll_forward':
      case 'scroll_backward':
        if (target.isEmpty && op.startsWith('scroll')) {
          // 没给目标就滚当前窗口的根滚动容器
        } else if (target.isEmpty) {
          return 'BAD_ARG：$op 需要 target（rid / text / desc / index / xy）';
        }
        return _act(ctx, op, target, args['value']?.toString() ?? '');

      default:
        return 'BAD_ARG：未知 op「$op」';
    }
  }

  /// **按键兜底**：用 `input text` 把文字送进当前聚焦的输入框。
  ///
  /// 返回说明文本表示成功发出去了，返回 `null` 表示这条路走不通
  /// （没 Shizuku / 含非 ASCII / 命令失败）。
  ///
  /// ## 为什么它排在最后
  ///
  /// 它会**真的按键**，副作用比节点写入大（可能触发输入法的联想、
  /// 自动格式化、甚至搜索建议）。只有前面三条路都失败时才用它。
  ///
  /// ## 为什么中文不能用它
  ///
  /// `input text` 底层是往当前输入法"注入按键"，只认 ASCII。
  /// 中文/emoji 发过去会变成乱码或直接报错 —— 与其把乱码写进用户的
  /// 输入框，不如如实说"这条路不行"。
  Future<String?> _inputTextFallback(
    ToolContext ctx,
    Map<String, dynamic> target,
    String value,
  ) async {
    if (value.isEmpty) return null;

    // 非 ASCII（中文/emoji）走不了 input text
    if (value.codeUnits.any((int c) => c > 127)) {
      return null;
    }

    // **必须走 Shizuku 的 shell**，不能用 TerminalSession。
    //
    // `input` 是 Android 自带的命令（`/system/bin/input`），
    // 而 TerminalSession 默认跑在自带的 Alpine 里 —— 那里的 busybox
    // 没有 `input`，会报 command not found，看起来像"兜底也没用"。
    final ShizukuService shizuku = ctx.shizuku;
    if (!shizuku.ready) return null;

    // `input text` 的两个坑：
    //  1. **空格**要写成 `%s`，否则会被当成参数分隔；
    //  2. shell 元字符要转义，否则 `&`、`;`、`(` 会被 shell 解释。
    final String escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(' ', '%s')
        .replaceAll(r'&', r'\&')
        .replaceAll(r'<', r'\<')
        .replaceAll(r'>', r'\>')
        .replaceAll(r'(', r'\(')
        .replaceAll(r')', r'\)')
        .replaceAll(r'|', r'\|')
        .replaceAll(r';', r'\;')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`');

    final ExecResult run = await shizuku.exec(
      "input text '$escaped'",
      timeoutMs: 20000,
    );
    if (run.code != 0) return null;

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final UiSnapshot? after = await A11y.dump();
    final String now = after?.findTarget(target)?.text ?? '';
    if (now.contains(value)) {
      return '✅ 已用按键兜底写入（input text）：输入框现在是 "$now"';
    }
    return '⚠ 已尝试按键兜底（input text）但没读到预期内容：\n'
        '输入框现在：${now.isEmpty ? '(空)' : '"$now"'}';
  }

  Future<String> _act(
    ToolContext ctx,
    String op,
    Map<String, dynamic> target,
    String value,
  ) async {
    final UiSnapshot? before = await A11y.dump();
    if (before == null) return '操作失败。$_a11yHint';

    final String nativeOp = switch (op) {
      'click' => 'click',
      'set_text' => 'set_text',
      _ => 'scroll',
    };
    final A11yResult r = await A11y.action(
      op: nativeOp,
      target: target,
      value: value,
      backward: op == 'scroll_backward',
    );

    // ---- 输入框写不进去时的**最后一层兜底** ----
    //
    // 原生侧已经试过三条路（ACTION_SET_TEXT / 全选粘贴 / 清空后粘贴），
    // 都失败说明这个控件压根不吃节点级写入（自绘编辑框最典型）。
    // 这时候唯一还剩的办法是**真的发按键事件**：`input text` 把字符
    // 送进当前获得焦点的输入框，走的是输入法那条通道。
    //
    // 代价和限制必须说清：
    //  · 它只认 **ASCII** —— `input text` 不支持中文/表情，发过去是乱码或报错；
    //  · 依赖当前焦点，所以要先确保那个输入框是聚焦的（原生侧已经 focus 过）；
    //  · 需要 Shizuku 或自带 Linux 才跑得动。
    if (op == 'set_text' && !r.ok) {
      final String? viaInput = await _inputTextFallback(ctx, target, value);
      if (viaInput != null) return viaInput;
      // 输入框找不到时，最可能的原因是"它是空的，所以没有 text"。
      // 直接给出可执行的两步，比让模型反复用同一个 target 重试有用。
      final List<UiNode> boxes = before.nodes
          .where((UiNode n) => n.editable)
          .toList();
      if (boxes.isNotEmpty) {
        final String lines = boxes
            .take(6)
            .map((UiNode n) => n.line())
            .join('\n');
        return '${_result(r)}\n'
            '这个界面里有 ${boxes.length} 个输入框，按行首序号或 hint 直接指定：\n'
            '$lines\n'
            '空输入框没有文本，用 hint="…" 里那句灰色提示来认它；'
            '也可以 target.index 用行首序号。';
      }
      return _result(r);
    }

    if (!r.ok) return _result(r);

    // 等界面稳定再回读。有些列表动画要 200ms 才落位。
    await Future<void>.delayed(const Duration(milliseconds: 280));
    final UiSnapshot? after = await A11y.dump();
    if (after == null) return '${_result(r)}\n（界面回读失败，无法确认结果）';

    final StringBuffer sb = StringBuffer(_result(r));
    if (op == 'set_text') {
      final UiNode? node = after.findTarget(target);
      final String now = node?.text ?? '';
      sb.write('\n输入框现在：${now.isEmpty ? '(空)' : '"$now"'}');
      // 原生侧已经回读校验过一次；这里再读一次是因为**界面可能异步回填**
      // （例如输入法联想、控件自己的格式化）。仍然不一致就再试按键兜底。
      if (value.isNotEmpty && !now.contains(value)) {
        final String? viaInput = await _inputTextFallback(ctx, target, value);
        if (viaInput != null) return '$sb\n\n$viaInput';
        sb.write(
          '\n⚠ 文本没有完整写进去，可能被输入法/校验拦截。'
          '\n可以试试先点一下这个输入框让它聚焦，再用 set_text；'
          '或者用 ui_tree 找一个可以点击的替代入口。',
        );
      }
      return sb.toString();
    }

    final bool changed = before.fingerprint() != after.fingerprint();
    sb.write(changed ? '\n界面：已变化' : '\n界面：未变化');
    if (!changed) {
      sb.write(
        '\n没变化不代表一定失败（例如只是聚焦），但不要原样重试；'
        '先用 ui_tree 看当前状态，或改用 index/xy 兜底。',
      );
    }
    return sb.toString();
  }

  Future<String> _swipe(
    Map<String, dynamic> target,
    Map<String, dynamic> args,
  ) async {
    final UiSnapshot? before = await A11y.dump();
    if (before == null) return '滑动失败。$_a11yHint';

    double x1 = (target['x1'] as num?)?.toDouble() ?? 0;
    double y1 = (target['y1'] as num?)?.toDouble() ?? 0;
    double x2 = (target['x2'] as num?)?.toDouble() ?? 0;
    double y2 = (target['y2'] as num?)?.toDouble() ?? 0;

    // 没给坐标就按目标控件的中线从下往上划一屏的 40%。
    if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0) {
      final UiNode? node = before.findTarget(target);
      if (node != null) {
        x1 = node.centerX;
        x2 = node.centerX;
        y1 = node.bottom - node.height * 0.2;
        y2 = node.top + node.height * 0.2;
      } else {
        x1 = before.width / 2;
        x2 = before.width / 2;
        y1 = before.height * 0.75;
        y2 = before.height * 0.35;
      }
    }

    final int steps = ((args['steps'] as num?)?.toInt() ?? 12)
        .clamp(2, 60)
        .toInt();
    final int duration = ((args['duration'] as num?)?.toInt() ?? 400)
        .clamp(80, 10000)
        .toInt();
    final List<List<double>> points = <List<double>>[];
    for (int i = 0; i <= steps; i++) {
      final double t = i / steps;
      points.add(<double>[x1 + (x2 - x1) * t, y1 + (y2 - y1) * t]);
    }
    final A11yResult r = await A11y.gesture(points, duration: duration);
    if (!r.ok) return _result(r);

    await Future<void>.delayed(const Duration(milliseconds: 320));
    final UiSnapshot? after = await A11y.dump();
    final bool changed =
        after != null && before.fingerprint() != after.fingerprint();
    return 'OK · ${r.raw['method'] ?? 'gesture'}\n'
        '从 (${x1.round()},${y1.round()}) 到 (${x2.round()},${y2.round()})，'
        '$steps 段 / ${duration}ms\n'
        '界面：${changed ? '已变化' : '未变化（可能到头了，或页面不接受滑动）'}';
  }

  Future<String> _waitFor(Map<String, dynamic> target, num? timeout) async {
    final int seconds = (timeout?.toInt() ?? 5).clamp(1, 30).toInt();
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < Duration(seconds: seconds)) {
      final UiSnapshot? snap = await A11y.dump();
      if (snap == null) return '等待失败。$_a11yHint';
      final UiNode? node = snap.findTarget(target);
      if (node != null) {
        return 'OK · 元素已出现（${clock.elapsedMilliseconds}ms）\n${node.line()}';
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    return 'TIMEOUT：${seconds}s 内没有等到目标。\n'
        '不要无限重试；先 ui_tree 看界面是否变了，或检查目标文字是否准确。';
  }

  Future<String> _launch(ToolContext ctx, String pkg) async {
    if (pkg.isEmpty) return 'BAD_ARG：launch 需要 value=包名';
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.]+$').hasMatch(pkg)) {
      return 'BAD_ARG：包名格式不对「$pkg」';
    }
    final A11yResult r = await A11y.launch(pkg);
    if (r.ok) return 'OK · 已启动 $pkg';

    if (ctx.shizuku.ready) {
      final r2 = await ctx.shizuku.exec(
        'monkey -p $pkg -c android.intent.category.LAUNCHER 1',
        timeoutMs: 8000,
      );
      if (r2.code == 0 && !r2.stdout.contains('No activities found')) {
        return 'OK · 已通过 shell 启动 $pkg';
      }
      return '启动失败：${r.message}\n${r2.stdout}${r2.stderr}';
    }
    return '启动失败：${r.message.isEmpty ? _a11yHint : r.message}';
  }

  Future<String> _openUrl(ToolContext ctx, String url) async {
    if (url.isEmpty) return 'BAD_ARG：open_url 需要 value=网址';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return 'BAD_ARG：只接受 http/https 链接';
    }
    final A11yResult r = await A11y.openUrl(url);
    if (r.ok) return 'OK · 已交给系统打开 $url';

    if (ctx.shizuku.ready) {
      final r2 = await ctx.shizuku.exec(
        'am start -a android.intent.action.VIEW -d ${shQuote(url)}',
        timeoutMs: 8000,
      );
      if (r2.code == 0) return 'OK · 已通过 shell 打开 $url';
      return '打开失败：${r2.stdout}${r2.stderr}';
    }
    return '打开失败：${r.message.isEmpty ? _a11yHint : r.message}';
  }

  String _result(A11yResult r) {
    if (!r.ok) {
      if (r.code == 'NO_ACCESSIBILITY') return _a11yHint;
      return '${r.code}${r.message.isEmpty ? '' : '：${r.message}'}';
    }
    final Map<dynamic, dynamic> hit =
        (r.raw['hit'] as Map<dynamic, dynamic>?) ?? const <dynamic, dynamic>{};
    final StringBuffer sb = StringBuffer('OK');
    if (r.raw['method'] != null) sb.write(' · ${r.raw['method']}');
    if (hit['found'] == true) {
      final UiNode n = UiNode.fromMap(hit, 0);
      sb.write('\n命中：${n.line().replaceFirst('[0] ', '')}');
    }
    if (r.message.isNotEmpty) sb.write('\n${r.message}');
    return sb.toString();
  }
}

/// Python 生成路径 → 在别的 App 里连续画出来。
class DrawPathTool extends AgentTool {
  const DrawPathTool();

  @override
  String get name => 'draw_path';

  @override
  String get title => '按路径绘制';

  @override
  String get description =>
      '把一组笔画连续画到当前屏幕（通常先 launch 打开绘图 App）。\n'
      '路径可以来自 Python：让 python 把 JSON 写到工作目录，再在这里传 path_file。'
      '相对路径按应用工作目录解析；Linux 里的 `/shared/x.json` 在这里写 `shared/x.json`。'
      'JSON 形如 {"strokes":[[[0.1,0.2],[0.2,0.3]],[[0.5,0.5],[0.6,0.6]]]}，'
      '每个点是 [x,y]；coordinate=normalized（默认）时取 0–1，'
      'coordinate=screen 时直接用屏幕像素。\n'
      'rect 指定画布区域（屏幕像素 {x,y,w,h}），不给则用整屏。'
      '每一笔是一次真正的连续手势，需要无障碍服务。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'path_file': <String, dynamic>{
        'type': 'string',
        'description': '工作目录下的 JSON 路径文件；与 strokes 二选一',
      },
      'strokes': <String, dynamic>{
        'type': 'array',
        'description': '直接给笔画数组：[[[x,y],...], ...]',
        'items': <String, dynamic>{'type': 'array'},
      },
      'coordinate': <String, dynamic>{
        'type': 'string',
        'enum': <String>['normalized', 'screen'],
        'description': '默认 normalized（0–1）',
      },
      'rect': <String, dynamic>{
        'type': 'object',
        'description': '画布矩形（屏幕像素）',
        'properties': <String, dynamic>{
          'x': <String, dynamic>{'type': 'number'},
          'y': <String, dynamic>{'type': 'number'},
          'w': <String, dynamic>{'type': 'number'},
          'h': <String, dynamic>{'type': 'number'},
        },
      },
      'launch_package': <String, dynamic>{
        'type': 'string',
        'description': '可选：先启动这个绘图 App，等 900ms 再画',
      },
      'speed': <String, dynamic>{
        'type': 'number',
        'description': '绘制速度（屏幕像素/秒），默认 900；越小越慢越稳',
      },
      'duration_ms': <String, dynamic>{
        'type': 'integer',
        'description': '每一笔固定时长；不填则按路径长度自动计算',
      },
      'gap_ms': <String, dynamic>{
        'type': 'integer',
        'description': '两笔之间停顿，默认 120ms',
      },
    },
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) =>
      const RiskAssessment(RiskLevel.caution, <String>['会在其他应用里模拟绘制']);

  @override
  bool get autoApprove => true;

  @override
  String summarize(Map<String, dynamic> args) {
    final String f = args['path_file']?.toString() ?? '';
    if (f.isNotEmpty) return '绘制路径 $f';
    final List<dynamic> s =
        (args['strokes'] as List<dynamic>?) ?? const <dynamic>[];
    return '绘制 ${s.length} 笔';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final bool hasFile =
        (args['path_file']?.toString().trim() ?? '').isNotEmpty;
    final bool hasInline =
        (args['strokes'] as List<dynamic>?)?.isNotEmpty == true;
    if (!hasFile && !hasInline) {
      return 'BAD_ARG：需要 path_file 或 strokes';
    }

    final String launch = args['launch_package']?.toString().trim() ?? '';
    if (launch.isNotEmpty) {
      final A11yResult r = await A11y.launch(launch);
      if (!r.ok) {
        return '启动绘图应用失败：${r.message.isEmpty ? _a11yHint : r.message}';
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }

    dynamic raw;
    if (hasFile) {
      final String name = args['path_file']!.toString().trim();
      final bool absolute = name.startsWith('/') || name.contains(':');
      final File f = File(absolute ? name : '${ctx.workDir}/$name');
      if (!await f.exists()) return '找不到路径文件：${f.path}';
      try {
        raw = jsonDecode(await f.readAsString());
      } catch (e) {
        return '路径文件不是合法 JSON：$e';
      }
    } else {
      raw = args['strokes'];
    }

    final List<List<List<double>>> strokes = parseStrokes(raw);
    final String? bad = validateStrokes(strokes);
    if (bad != null) return 'BAD_ARG：$bad';

    final bool normalized =
        (args['coordinate']?.toString() ?? 'normalized') != 'screen';
    final UiSnapshot? snap = await A11y.dump();
    if (snap == null) return '绘制失败。$_a11yHint';

    CanvasRect canvas = CanvasRect(0, 0, snap.width, snap.height);
    final Map<String, dynamic>? rect = (args['rect'] as Map?)
        ?.cast<String, dynamic>();
    if (rect != null) {
      final CanvasRect r = CanvasRect.fromMap(rect);
      if (!r.valid) return 'BAD_ARG：rect 宽高必须大于 1';
      canvas = r;
    }
    final List<List<List<double>>> screen = normalized
        ? canvas.mapNormalized(strokes)
        : strokes;

    final int? fixed = (args['duration_ms'] as num?)?.toInt();
    final double speed = (args['speed'] as num?)?.toDouble() ?? 900;
    final List<int> durations = screen
        .map((List<List<double>> s) => fixed ?? strokeDuration(s, speed: speed))
        .toList();
    final int gap = ((args['gap_ms'] as num?)?.toInt() ?? 120)
        .clamp(16, 2000)
        .toInt();

    final A11yResult r = await A11y.draw(
      screen,
      durations: durations,
      gap: gap,
    );
    if (!r.ok) {
      return '绘制失败：${r.code}${r.message.isEmpty ? '' : '：${r.message}'}';
    }
    final int points = strokes.fold<int>(
      0,
      (int n, List<List<double>> s) => n + s.length,
    );
    return 'OK · 已画 ${r.raw['accepted'] ?? '?'}/${r.raw['total'] ?? strokes.length} 笔，'
        '$points 个点\n'
        '画布：${canvas.x.round()},${canvas.y.round()} ${canvas.w.round()}×${canvas.h.round()}，'
        '坐标：${normalized ? '归一化' : '屏幕像素'}\n'
        '建议随后 screen_capture + read_image 检查实际效果。';
  }
}
