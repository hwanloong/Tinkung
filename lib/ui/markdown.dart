import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../core/text_marks.dart';
import '../theme/app_theme.dart';
import 'cards.dart';
import 'inline_image.dart';
import 'latex_compat.dart';
import 'shimmer.dart';

/// 轻量 Markdown 渲染器。
///
/// 为什么不直接用 flutter_markdown：那份实现会把字体交给它自己的默认值，
/// 没法保证「英文 Times、中文宋体、代码 Consolas」这套混排落到每个 span 上。
/// 这里自己解析，样式完全可控。
///
/// 支持：标题、段落、无序/有序列表、引用、分割线、围栏代码块、
/// **表格**，以及行内的 **加粗**、*斜体*、`行内代码`、[链接](url)、~~删除线~~。
///
/// 还要支持**长按选取 → 引用 / 标记**，所以这里是 `StatefulWidget` ——
/// 需要把"当前选中的文字"记在 state 里（见 [onSelectionChanged] 的注释）。
class MarkdownView extends StatefulWidget {
  const MarkdownView({
    super.key,
    required this.text,
    this.baseSize = 15,
    this.onOpenLink,
    this.enableCards = true,
    this.streaming = false,
    this.marks = const <TextMark>[],
    this.onQuote,
    this.onMark,
    this.onUnmark,
    this.onRegenerate,
    this.onEdit,
    this.onDelete,
  });

  final String text;
  final double baseSize;
  final void Function(String url)? onOpenLink;

  /// 长按这条消息时，菜单里的「重新生成」（只对 AI 回复出现）。
  ///
  /// 为什么放进**选区菜单**而不是自己做 `GestureDetector(onLongPress:)`：
  /// 正文是可选中的文字，`TextField`/`SelectableRegion` 在 Flutter 的
  /// 手势竞技场里**子节点优先**，外层套长按识别器永远抢不到
  /// （输入框那边踩过同一个坑，见 `_armLongPress` 的注释）。
  /// 而长按文字本来就会弹这个菜单 —— 加进去正好是"长按气泡就能看到"。
  final VoidCallback? onRegenerate;

  /// 菜单里的「修改」：把这条消息放回输入框，改完再发。
  final VoidCallback? onEdit;

  /// 菜单里的「删除」：删掉这条消息本身（会先确认）。
  final VoidCallback? onDelete;

  /// 这条消息上的**文字标记**（荧光笔底色）和**引用锚点**（虚线）。
  ///
  /// 渲染方式是"按原文查找"而不是按偏移量 —— 原因见 [TextMark]：
  /// 流式输出会让偏移量当场失效，而原文不会。
  final List<TextMark> marks;

  /// 用户在选区菜单里点「引用」。
  final void Function(String selected)? onQuote;

  /// 用户在选区菜单里点某个颜色的「标记」。参数是选中文字 + 底色。
  final void Function(String selected, MarkColor color)? onMark;

  /// 用户在面板里点「取消标记」。参数是选中的原文。
  final void Function(String selected)? onUnmark;

  /// 是否把 `card:` 代码块渲染成富卡片。
  ///
  /// **流式输出期间必须传 false。** 原因：
  /// `InAppWebView` 的 `initialData` **只在创建时读一次**，
  /// 之后即使传入新 HTML 也不会重新加载。
  /// 所以流式过程中创建的 WebView 拿到的是**半截 HTML**，
  /// 而流式结束后它又不会重载 —— 表现为"卡片不显示，重启应用才出现"。
  ///
  /// 关掉之后，未完成的卡片先以代码块形式显示，等流式结束
  /// 再切换成卡片 —— 那时 WebView 才第一次创建，拿到的是完整内容。
  final bool enableCards;

  /// 这条消息**还在流式输出**。
  ///
  /// 两个作用：
  ///  · 给最后一块正文套扫光，让"正在长出来的字"和已定稿的部分区分开；
  ///  · 代码块 / 表格 / 图片这些**卡片类块先不渲染** —— 半截内容建出来的
  ///    表格列数、图片地址都可能是错的，等整条消息结束再一次性出现。
  ///    `card:` 富卡片另见 [enableCards]。
  final bool streaming;

  /// 解析结果缓存 —— **这是流式输出卡顿的主因**。
  ///
  /// 每个 token 触发一次 setState，整棵消息列表重建，
  /// 于是**每条历史消息都要重新解析一遍 markdown**。
  /// 50 条消息 × 每个 token = O(n²)，越聊越卡。
  ///
  /// 缓存"文本没变就不重解析"之后，只有正在流式的那一条会真正解析，
  /// 历史消息直接命中缓存。
  ///
  /// 用单个槽位而不是 Map：实际访问模式是"同一条消息反复重建"，
  /// 一个槽位就够，而且不会让缓存无限增长（长会话下 Map 会吃掉大量内存）。

  /// 把 markdown 源文转成**渲染器真正会显示的那段文字**（去掉 `**`、
  /// `- `、列表符号、链接地址这些语法）。
  ///
  /// ## 为什么需要它（用户报的"标记飘到其他地方的相同字了"）
  ///
  /// 标记靠"文字 + 第几次出现"定位。这个"第几次"**必须在渲染后的正文上算**，
  /// 因为渲染器数的就是那份文本；而原文里还夹着语法字符 ——
  /// `[文档](https://x.com/的)` 这种一下就让计数错位（链接地址里的那个字
  /// 在原文里算一次、在渲染结果里根本不存在），于是标记落到同一文字的另一处。
  ///
  /// 代码块 / 公式 / 图片 / 分隔线不算：渲染器**不会**在这些块上盖标记
  /// （它们不走行内解析，也就进不了那本"出现次数"的流水账），
  /// 所以计数基准里也不能有它们。
  ///
  /// [s] 只用来取链接的颜色之类的样式 —— 对**文字**没有影响，
  /// 所以任何一份 `AppSurface` 都行（测试里直接传 `AppSurface.light`）。
  static String plainTextOf(String text, AppSurface s) {
    final TextStyle base = AppFonts.read(size: 15);
    final TextStyle code = AppFonts.code(size: 13);
    final StringBuffer sb = StringBuffer();

    void add(String piece) {
      for (final InlineSpan sp in _plainInline(piece, base, code, s, null)) {
        sb.write(sp.toPlainText());
      }
      // 块之间用换行隔开：避免"跨块的巧合匹配"被算成一次出现。
      sb.write('\n');
    }

    for (final _Block b in _blocksFor(text)) {
      switch (b) {
        case _Paragraph p:
          add(p.text);
        case _Heading h:
          add(h.text);
        case _Quote q:
          add(q.text);
        case _ListBlock l:
          for (final _Item i in l.items) {
            add(i.text);
          }
        case _TableBlock t:
          for (final String h in t.headers) {
            add(h);
          }
          for (final List<String> row in t.rows) {
            for (final String cell in row) {
              add(cell);
            }
          }
        // 下面这些块渲染时不走行内解析 → 不进计数基准（见方法注释）
        case _CodeBlock _:
        case _MathBlock _:
        case _ImageBlock _:
        case _Hr _:
          continue;
      }
    }
    return sb.toString();
  }

  /// 解析结果的小缓存：文本 → 块列表。
  ///
  /// ## 为什么必须从"单槽位"改成"多槽位 LRU"
  ///
  /// 原来只有一个 `_cacheKey/_cacheBlocks`。当时假设"访问模式是同一条
  /// 消息反复重建"，但**实际不是**：一屏里同时渲染 N 条消息，
  /// 每一条都会调一次 `_blocksFor`，于是缓存每帧都被下一条顶掉 ——
  /// 单槽位等于**永远命中不了**，所有消息每帧全量重解析一遍。
  ///
  /// 消息越长解析越贵，而流式输出时整页每秒重建 ~30 次 ——
  /// 这就是"AI 跑起来就卡、连输入法都一卡一卡"的直接原因：
  /// 主 isolate 被 markdown 解析占满，键盘的文本回显排在后面。
  ///
  /// 换成有上限的 Map：命中率从 0 变成接近 100%（只有正在流式那一条
  /// 的 key 会变），而条目数有上限，长会话也不会把内存吃穿。
  static final Map<String, List<_Block>> _cache = <String, List<_Block>>{};

  /// 最多缓存多少条消息的解析结果。
  ///
  /// 一屏能同时出现在渲染树里的消息数量级就是几十条，128 足够覆盖
  /// "往上翻一点"的情况；每条 block 列表只持有索引和字符串切片，
  /// 不持有 Widget，所以这个量级的内存可以接受。
  static const int _cacheLimit = 128;

  static List<_Block> _blocksFor(String text) {
    final List<_Block>? hit = _cache[text];
    if (hit != null) {
      // 命中就把它挪到末尾（LRU：末尾是最近用的）
      _cache.remove(text);
      _cache[text] = hit;
      return hit;
    }
    final List<_Block> b = _parseBlocks(text);
    _cache[text] = b;
    if (_cache.length > _cacheLimit) {
      // 丢掉最久没用的那一条（Map 保持插入顺序，first 就是最旧的）
      _cache.remove(_cache.keys.first);
    }
    return b;
  }

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

/// 渲染一个公式，**带缓存**。
///
/// ## 为什么必须缓存（"有公式就卡"的真因）
///
/// `Math.tex()` 每次调用都会把 LaTeX **重新解析成语法树**，那是个纯 CPU 的
/// 递归下降解析器。而聊天流式输出时整条消息每秒重建约 30 次 ——
/// 只要正文里有一个公式，解析器每秒就跑 30 遍，主 isolate 被占满，
/// 表现就是"一有公式就卡、连输入法都一顿"。
///
/// 解析结果只取决于 `(latex, mathStyle, 字号, 颜色)` 四个输入，
/// 所以按这四个做键缓存 Widget 完全安全 —— 公式是**无状态的静态内容**，
/// 不像 TextField 那样持有焦点/控制器。
///
/// 上限 64 条：一屏同时可见的公式不会有这么多，再多的部分是滚动历史，
/// 重建时会重新解析一次，代价可接受。
Widget _mathWidget(
  String latex,
  MathStyle style,
  TextStyle textStyle,
  AppSurface s, {
  required double fallbackSize,
}) {
  // ⚠️ 这里**先查缓存再规整**。
  //
  // 以前是反过来的：每帧先跑一遍 `normalizeLatex()`（十几正则 + 多趟
  // 字符串扫描），拿结果拼 key，再去查缓存。于是"缓存命中"只省下了
  // `Math.tex` 的解析，规整那部分照跑不误 —— 而流式输出每秒重建
  // 30 次、每个公式各跑一遍，主 isolate 就被这十几正则吃满了。
  // 用户看到的现象就是"正文一有公式就开始卡"。规整的结果只取决于
  // 原文，所以按**原文**缓存一次即可。
  final String clean = _normalizeCached(latex);
  final String key =
      '${style.index}|${textStyle.fontSize}|'
      '${textStyle.color?.toARGB32()}|$clean';
  final Widget? hit = _mathCache.remove(key);
  if (hit != null) {
    // 挪到末尾（LRU）：Map 保持插入顺序，末尾是最近用过的
    _mathCache[key] = hit;
    // 缓存里存的已经是 RepaintBoundary（见下面构造时），直接复用，
    // 不再套第二层 —— 之前每次命中都新包一层，命中即等于没命中。
    return hit;
  }

  // ---- 解析失败必须降级，不能让整条消息空白 ----
  //
  // `Math.tex` 的 onErrorFallback 只覆盖"解析器报错"，覆盖不到
  // 构建期抛出的其它异常（比如某个宏在布局阶段炸）。那类异常会冒泡到
  // 上层，整块 Markdown 直接渲染失败 —— 用户看到的就是"带公式的聊天
  // 打开是空白"。所以这里自己兜住。
  //
  // 顺序：规整后的原文 → 抢救版 → 可读纯文本。
  // 前两步都拿 `Math` 的 `parseError` 判定，只有解析通过才用。
  //
  // ⚠️ 兜底做成**闭包**：`Math` 的 onErrorFallback 是构建期才调用的，
  // 解析成功的公式一辈子用不到它。以前这里在最前面就无条件造了一份
  // （`latexToPlain` 是完整宏展开 + 十几趟替换），绝大多数公式明明
  // 一次就解析通过 —— 那份兜底文案是白算的，也是"有公式就卡"的第二个来源。
  Widget fallback() => _mathFallback(latexToPlain(clean), s, fallbackSize);

  Widget? built = _tryMath(clean, style, textStyle, fallback);
  if (built == null) {
    final String repaired = repairLatex(clean);
    if (repaired != clean) {
      built = _tryMath(repaired, style, textStyle, fallback);
    }
  }
  built ??= fallback();

  final Widget wrapped = RepaintBoundary(child: built);
  _mathCache[key] = wrapped;
  if (_mathCache.length > 64) _mathCache.remove(_mathCache.keys.first);
  return wrapped;
}

/// `normalizeLatex` 的记忆化版本。
///
/// 规整是**纯函数**，同一个公式在一次会话里会被反复问上千次
/// （流式输出每帧一次 + 滚动重建），而它的输出只取决于输入。
/// 缓存掉之后，稳定下来的消息连"规整"这一步都不用再付。
///
/// 上限 256：正文里出现过的不同公式数不会更多，再多也只是重算一次。
final Map<String, String> _normalizeCache = <String, String>{};

String _normalizeCached(String latex) {
  final String? hit = _normalizeCache[latex];
  if (hit != null) return hit;
  final String out = normalizeLatex(latex);
  _normalizeCache[latex] = out;
  if (_normalizeCache.length > 256) {
    _normalizeCache.remove(_normalizeCache.keys.first);
  }
  return out;
}

/// 尝试解析一次；解析失败返回 null（交给下一档兜底）。
///
/// [fallback] 是**闭包**而不是 Widget：它只在构建期真的出错时才会被调用，
/// 解析成功的公式一辈子用不到它。传 Widget 会逼着调用方提前把它造出来 ——
/// 而造它要跑一遍 `latexToPlain()`（完整的宏展开 + 十几趟替换），
/// 在流式输出里就是每个公式每帧白烧一次 CPU。
Widget? _tryMath(
  String latex,
  MathStyle style,
  TextStyle textStyle,
  Widget Function() fallback,
) {
  try {
    final Math w = Math.tex(
      latex,
      mathStyle: style,
      textStyle: textStyle,
      onErrorFallback: (FlutterMathException _) => fallback(),
    );
    // `Math.tex` 是同步解析的：这里能直接知道这一遍有没有过。
    if (w.parseError != null) return null;
    return w;
  } catch (_) {
    return null;
  }
}

final Map<String, Widget> _mathCache = <String, Widget>{};

class _MarkdownViewState extends State<MarkdownView> {
  /// 这一遍渲染里，每个被标记的文字**前面那些块里已经出现过几次**。
  ///
  /// ## 它修的是什么（用户报的"标一个字，别处相同的字也被标上"）
  ///
  /// 渲染是**按块**进行的（一个段落调一次 `inline()`），而 `occurrence` 是在
  /// **整条消息**的原文上算出来的 —— 两个语境根本不是一回事。于是一条
  /// `occurrence = 0` 的标记，会在**每一个含有这段文字的块里各点亮一处**：
  /// 标一个「的」，五个段落里的第一个「的」全都亮了。
  ///
  /// 所以这里记一本账：每渲染完一块，就把这一块里各文字出现的次数累加进去。
  /// 下一块就能靠它把"全文第 N 次"换算成"本块第几次"（见 [_applyMarks]）。
  /// 这样一条标记**只会盖在一处**，而且盖的正是当初标的那一处。
  final Map<String, int> _seenRuns = <String, int>{};

  /// **当前选中的文字**。
  ///
  /// ## 为什么要自己存一份
  ///
  /// 选区菜单里点「引用 / 标记」时需要拿到选中的文本，但
  /// `SelectableRegionState` **没有公开**"给我选区文本"的方法
  /// （内部的 `getSelectedContent()` 不在公开 API 上）。
  ///
  /// 官方留的口子是 `SelectionArea.onSelectionChanged` ——
  /// 每次选区变化它都会把新的选中内容回调过来。
  /// 所以这里订阅它、存一份，菜单里直接用存下来的值。
  String _selected = '';

  /// **块级 widget 缓存**：流式输出时只有最后一块在变，前面已完成
  /// 的块直接复用**同一个 widget 实例**。
  ///
  /// ## 为什么需要它（用户报的"前面写出来了，还要等到后面才显示 markdown"）
  ///
  /// 之前为了省算力，流式期间只要正文超过 600 字或含公式，就**整段先用
  /// 纯文本显示**，等流结束再套一层 markdown。代价是：用户眼看着一段
  /// 排版好的文字先变成"一堆星号和井号"，滚到结尾才突然变成正文。
  ///
  /// 真正的原因不是"markdown 渲染太贵"，而是**每一帧都在重排所有块**。
  /// 流式是**追加**的：第 0..n-1 块的内容永远不变，只有最后一块在长。
  /// 所以按块缓存 widget 实例之后，每帧只需重排最后一块 ——
  /// 既保住了流式的性能，又让已完成的部分立刻是 markdown。
  ///
  /// ## 为什么有标记时不用缓存
  ///
  /// 标记依赖一本"文字出现次数"的账（见 [_seenRuns]），而账是**按块顺序
  /// 边渲染边累加**的。复用缓存会跳过累加，后面块的标记就会错位。
  /// 标记是用户手动加的、很罕见，所以有标记时走原来的全量路径。
  final List<_CachedBlock> _blockCache = <_CachedBlock>[];

  /// 缓存对应的"主题 + 字号"快照。任何一项变了就整体作废。
  String _blockCacheStyle = '';

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final List<_Block> blocks = MarkdownView._blocksFor(widget.text);
    // 每一遍渲染都要把"已用掉的标记"清空：块是一遍之内顺序渲染的，
    // 而下一遍（内容变了、主题变了）必须重新从头分配。
    _seenRuns.clear();

    final List<Widget> built = _buildBlocks(context, blocks, s, dark: dark);

    // ---- 流式扫光 ----
    //
    // 只包**最后一块**，而且只包文字块：上面的块已经定稿，不需要动；
    // 卡片类块在流式期间根本不渲染（见 `_buildBlock`），也就没有可扫的东西。
    //
    // 包装层放在块缓存**外面**：缓存里存的仍然是原始 widget，
    // 动画帧重建的只是这层 ShaderMask，不会污染缓存、也不会让
    // 已定稿的块每帧重排。
    if (widget.streaming && built.isNotEmpty && _isTextBlock(blocks.last)) {
      built[built.length - 1] = ShimmerMask(
        base: s.text,
        // 高光偏暖（和强调色同族），扫过去时像笔尖刚写到这里。
        highlight: Color.lerp(s.text, AppColors.accent, 0.72)!,
        duration: const Duration(milliseconds: 2200),
        child: built.last,
      );
    }

    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: built,
    );

    // ---- 长按选中 / 复制正文 ----
    //
    // 用户要的是"AI 回复里任意一段都能选中复制"。
    //
    // ## 为什么用 `SelectionArea` 包住整个 column
    //
    // 而不是把每个 `Text` 换成 `SelectableText`：
    //  · 前者是**一次包裹**，段落 / 标题 / 列表 / 引用 / 表格全部自动可选，
    //    不用逐个改（那是一百多处）；
    //  · 它还支持**跨块选择**（从一段选到下一段），
    //    而各自独立的 `SelectableText` 做不到。
    //
    // ## ⚠️ 光包一层是不够的：里面的叶子必须是 `Text` 系组件
    //
    // 这里是**踩过的坑**。原来段落和标题用的是**裸 `RichText`**，
    // 而 `SelectionArea` 依赖下层组件把自己注册进 `SelectionRegistrar` ——
    // 裸 `RichText` **不注册**，于是包了 `SelectionArea` 也一点都选不中，
    // 表现为"加了选中功能但还是复制不了"。
    //
    // 所以本文件里所有裸 `RichText` 都换成了 `Text.rich`
    // （前者只是后者的内部实现，后者才带选择支持）。
    // **以后往这个渲染器里加新块时：用 `Text` / `Text.rich`，
    // 不要用裸 `RichText`。**
    //
    // 作用域只在一条消息内（每条消息各渲染一个 `MarkdownView`），
    // 选择不会跨消息 —— 想整段复制仍然有「复制」按钮。
    //
    // `contextMenuBuilder` 是给选区菜单**加两项**的地方：
    // 「引用」和「标记」。
    //
    // 为什么不自己做一个长按浮层：`SelectionArea` 已经处理了选区、
    // 拖动手柄、放大镜、跨 span 选取这些事，自己重做一遍必然不如它稳。
    // 官方留的这个钩子拿得到 `SelectableRegionState`，也就能拿到
    // `contextMenuButtonItems`（系统那几项）和当前选中的文字 ——
    // 在系统项后面追加我们自己的即可。
    return SelectionArea(
      // 每次选区变化都记下来，菜单里点「引用 / 标记」时用它。
      //
      // 参数类型写 `dynamic` 是因为 `SelectedContent` 只由
      // `package:flutter/rendering.dart` 导出，material / widgets 都不转出它。
      // 为了一个回调去 import 整个 rendering 层会引入一堆同名符号
      // （`TextSelection`、`SelectionRect`…）和 material 打架，不值。
      // 这里只读 `.plainText`，用 dynamic 一次调用即可。
      onSelectionChanged: (dynamic c) {
        _selected = (c?.plainText as String?) ?? '';
      },
      contextMenuBuilder: (BuildContext ctx, SelectableRegionState state) {
        final List<ContextMenuButtonItem> items =
            List<ContextMenuButtonItem>.from(state.contextMenuButtonItems);

        // **插到最前面**，而不是追加到最后。
        //
        // 系统那几项（剪切/复制/粘贴/全选）在小屏上会横向排开，
        // 追加到末尾意味着「引用 / 标记」经常被挤到看不见的地方、
        // 要横向划一下才露出来（用户反馈"跑太后面了"）。
        // 我们这项是**这个应用特有的主功能**，优先级本来就该高于
        // 系统那几项通用操作。
        // ---- 「引用」和「标记」是**两项**，不是一个合并项 ----
        //
        // 原来它们合成一个「引用 / 标记」，点进去再选。用户的要求是分开：
        // 引用是"就这句话回一句"（一次性、没有参数可挑），标记是"把这段涂上
        // 颜色"（要先选颜色）—— 两件事的心理模型不一样，合并成一项等于让人
        // 每次都得先点进去才知道里面有两条路。
        //
        // 所以：引用**直接执行**，标记才弹面板（面板里只剩选颜色和取消标记）。
        // 两项都插到最前面 —— 先插「标记」再插「引用」，于是引用在最左。
        // 它们是这个应用特有的主功能，优先级本来就高于系统那几项通用操作
        // （见上面那段"为什么插到最前面"）。
        void takeSelection(void Function(String selected) act) {
          // 用 state 里存好的选区（见 `_selected` 的注释）。
          // 必须**在关菜单之前**取走 —— 关掉之后选区会被清空。
          final String selected = _selected;
          state.hideToolbar();
          if (selected.trim().isEmpty) return;
          act(selected);
        }

        if (widget.onMark != null) {
          items.insert(
            0,
            ContextMenuButtonItem(
              onPressed: () => takeSelection(
                (String selected) => _showMarkSheet(ctx, selected),
              ),
              label: '标记',
            ),
          );
        }
        if (widget.onQuote != null) {
          items.insert(
            0,
            ContextMenuButtonItem(
              onPressed: () =>
                  takeSelection((String selected) => widget.onQuote!(selected)),
              label: '引用并回复',
            ),
          );
        }

        // ---- 「重新生成 / 修改」：整条消息的动作，不需要选区 ----
        //
        // 它们和上面三项的差别：那三项都是"对选中的这段文字做事"，
        // 这两项是"对整条消息做事"。所以点了之后要**立刻关掉选区菜单**，
        // 不能走 `takeSelection`（那会因为没有选区而直接 return，
        // 用户点了没反应 —— 最容易被当成 bug 的一种空操作）。
        if (widget.onRegenerate != null) {
          items.insert(
            0,
            ContextMenuButtonItem(
              onPressed: () {
                state.hideToolbar();
                widget.onRegenerate!();
              },
              label: '重新生成',
            ),
          );
        }
        if (widget.onEdit != null) {
          items.insert(
            0,
            ContextMenuButtonItem(
              onPressed: () {
                state.hideToolbar();
                widget.onEdit!();
              },
              label: '修改',
            ),
          );
        }
        if (widget.onDelete != null) {
          items.insert(
            0,
            ContextMenuButtonItem(
              onPressed: () {
                state.hideToolbar();
                widget.onDelete!();
              },
              label: '删除',
            ),
          );
        }

        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: items,
        );
      },
      child: column,
    );
  }

  /// 逐块构建，能复用就复用（见 [_blockCache]）。
  List<Widget> _buildBlocks(
    BuildContext context,
    List<_Block> blocks,
    AppSurface s, {
    required bool dark,
  }) {
    // 有标记时走全量路径：标记的"出现次数账本"必须按顺序累加，
    // 复用会跳过累加（见 [_blockCache] 的说明）。
    if (widget.marks.isNotEmpty) {
      _blockCache.clear();
      return blocks
          .map((_Block b) => _buildBlock(context, b, s, dark: dark))
          .toList();
    }

    // 主题 / 字号 / 卡片开关变了，整批作废。
    final String style =
        '$dark|${s.text.toARGB32()}|${s.muted.toARGB32()}|'
        '${s.codeBg.toARGB32()}|${s.border.toARGB32()}|'
        '${s.chipBg.toARGB32()}|${AppFonts.scale}|${widget.baseSize}|'
        '${widget.enableCards}|${widget.streaming}';
    if (style != _blockCacheStyle) {
      _blockCacheStyle = style;
      _blockCache.clear();
    }

    final List<Widget> out = <Widget>[];
    for (int i = 0; i < blocks.length; i++) {
      final _Block b = blocks[i];
      final String sig = _blockSignature(b);
      final _CachedBlock? hit = i < _blockCache.length ? _blockCache[i] : null;
      if (hit != null && hit.sig == sig) {
        out.add(hit.widget);
        continue;
      }
      final Widget w = _buildBlock(context, b, s, dark: dark);
      if (i < _blockCache.length) {
        _blockCache[i] = _CachedBlock(sig, w);
      } else {
        _blockCache.add(_CachedBlock(sig, w));
      }
      out.add(w);
    }
    // 正文变短（重新生成 / 换消息）时把多余的缓存清掉。
    if (_blockCache.length > blocks.length) {
      _blockCache.removeRange(blocks.length, _blockCache.length);
    }
    return out;
  }

  /// 流式扫光只包文字块。代码 / 表格 / 图片 / 公式不扫：
  ///  · 代码块是等宽字体，扫光会让整段代码变色，读起来像语法高亮坏了；
  ///  · 表格和图片在流式期间不渲染（见 `_buildBlock`）；
  ///  · 公式是 `flutter_math_fork` 自己画的，`ShaderMask` 盖上去会连
  ///    分数线一起染色。
  static bool _isTextBlock(_Block b) =>
      b is _Paragraph || b is _Heading || b is _Quote || b is _ListBlock;

  /// 一块的渲染签名：块类型 + 它的全部数据。
  ///
  /// 只用数据不用位置 —— 同一个块换了位置仍然可以复用，
  /// 而内容变了签名就会变。块的数据量都不大（段落文字而已），
  /// 拼一个字符串比重新排版一棵 Widget 树便宜几个数量级。
  static String _blockSignature(_Block b) {
    return switch (b) {
      _Paragraph p => 'p:${p.text}',
      _Heading h => 'h${h.level}:${h.text}',
      _CodeBlock c => 'code:${c.lang}:${c.code}',
      _MathBlock m => 'math:${m.latex}',
      _Quote q => 'q:${q.text}',
      _Hr() => 'hr',
      _ListBlock l =>
        'ul:${l.items.map((_Item i) => '${i.indent}|${i.marker}|${i.text}').join('\u0001')}',
      _TableBlock t =>
        'tb:${t.headers.join('\u0001')}::'
            '${t.rows.map((List<String> r) => r.join('\u0002')).join('\u0001')}',
      _ImageBlock img => 'img:${img.src}:${img.alt}',
    };
  }

  /// 弹出「标记」面板：选底色 + 取消标记。
  ///
  /// **引用不在这里** —— 它已经在选区菜单上单独一项、点了就直接生效
  /// （见 `contextMenuBuilder`）。这个面板只服务于"标记"那件事：
  /// 选颜色、以及取消已经标上的那段。
  void _showMarkSheet(BuildContext context, String selected) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Text(
                // 只显示一小段，长选区不把面板撑爆
                selected.length > 80
                    ? selected.substring(0, 80)
                    : selected,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                  size: 13,
                  color: AppSurface.of(ctx).muted,
                  height: 1.5,
                ),
              ),
            ),
            if (widget.onMark != null) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
                child: Text(
                  '标记底色',
                  style: AppFonts.body(
                    size: 12.5,
                    color: AppSurface.of(ctx).muted,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                child: Wrap(
                  spacing: 12,
                  children: <Widget>[
                    for (final MarkColor c in MarkColor.values)
                      GestureDetector(
                        onTap: () {
                          Navigator.of(ctx).pop();
                          widget.onMark!(selected, c);
                        },
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: c.background(
                              dark: Theme.of(ctx).brightness == Brightness.dark,
                            ),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppSurface.of(ctx).border,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            // ---- 取消标记 ----
            //
            // 放在**面板里**（而不是另一个长按菜单项）：标记是"再点一次
            // 同一个颜色就覆盖"的语义，取消也属于同一组操作，
            // 摆在一起才找得到。
            //
            // 按**选中的文字**去删，所以不需要用户记住当初标的是哪一段。
            if (widget.onUnmark != null)
              ListTile(
                leading: const Icon(Icons.format_color_reset_rounded),
                title: const Text('取消这段的标记'),
                subtitle: const Text('只取消这段文字上的高亮'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onUnmark!(selected);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBlock(
    BuildContext context,
    _Block block,
    AppSurface s, {
    required bool dark,
  }) {
    final TextStyle base = AppFonts.read(size: widget.baseSize, color: s.text);
    final TextStyle inlineCode = AppFonts.code(
      size: widget.baseSize - 1.6,
      color: s.text,
      height: 1.5,
    );

    /// 行内文本的统一出口：解析完之后**统一盖一次标记**。
    ///
    /// 所有行内文本都从这里过，所以标记能生效在段落、标题、列表项、
    /// 引用、表格单元格上 —— 一处都不用改。
    ///
    /// [style] 用来覆盖基础字形（标题要大、引用要灰），
    /// 但它**不影响标记** —— 标记是后盖上去的，跟着走。
    List<InlineSpan> inline(String src, {TextStyle? style}) => _applyMarks(
      _inlineSpans(src, style ?? base, inlineCode, s, widget.onOpenLink),
      widget.marks,
      s,
      dark,
      _seenRuns,
    );

    switch (block) {
      case final _CodeBlock b:
        // `card:` 富卡片在流式期间**完全不渲染**：半截 HTML / JSON
        // 建出来的卡片必然显示错误，等整条消息结束再出现。
        if (widget.streaming && b.lang.startsWith('card:')) {
          return const SizedBox.shrink();
        }
        // 语言标签以 `card:` 开头就当富卡片渲染（图片 / mermaid / 内嵌 HTML）。
        // 返回 null 表示类型不认识 —— **降级成普通代码块**，
        // 这样以后加新卡片类型时，旧版应用也不会把它显示成空白。
        final Widget? card = widget.enableCards
            ? MarkdownCards.build(
                lang: b.lang,
                content: b.code,
                baseSize: widget.baseSize,
              )
            : null;
        if (card != null) return card;
        return _CodeBlockView(
          block: b,
          surface: s,
          // 流式期间代码块只显示**裸代码**：没有卡片底、没有语言栏、
          // 没有复制按钮。卡片元素等定稿后再出现。
          defer: widget.streaming,
        );

      case final _MathBlock m:
        // 手机上宽公式必然超出屏幕，所以外面套横向滚动，而不是让它被裁掉
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _mathWidget(
              m.latex,
              MathStyle.display,
              AppFonts.read(size: widget.baseSize, color: s.text),
              s,
              fallbackSize: widget.baseSize,
            ),
          ),
        );

      case final _TableBlock b:
        // 表格在流式期间**不渲染**：列数、列宽都会随着后续行变化，
        // 先画出来再不停重排，既闪又容易显示错位。
        if (widget.streaming) return const SizedBox.shrink();
        return _TableView(
          block: b,
          surface: s,
          baseSize: widget.baseSize,
          onOpenLink: widget.onOpenLink,
          marks: widget.marks,
          dark: dark,
          seenRuns: _seenRuns,
        );

      case final _Heading h:
        final double size = switch (h.level) {
          1 => widget.baseSize + 7,
          2 => widget.baseSize + 4.5,
          3 => widget.baseSize + 2.5,
          _ => widget.baseSize + 1,
        };
        return Padding(
          padding: EdgeInsets.only(top: h.level <= 2 ? 14 : 10, bottom: 5),
          child: Text.rich(
            TextSpan(
              children: inline(
                h.text,
                style: AppFonts.read(
                  size: size,
                  weight: FontWeight.w600,
                  color: s.text,
                  height: 1.35,
                ),
              ),
            ),
          ),
        );

      case _Hr():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Divider(color: s.border, height: 0.8, thickness: 0.8),
        );

      case final _ImageBlock img:
        // 图片地址可能还没输出完；流式期间先不建图片控件，
        // 避免半截 URL 触发一次必然失败的加载。
        if (widget.streaming) return const SizedBox.shrink();
        return InlineImage(src: img.src, alt: img.alt);

      case final _Quote q:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: s.border, width: 3)),
            ),
            child: Text.rich(
              TextSpan(
                children: inline(q.text, style: base.copyWith(color: s.muted)),
              ),
            ),
          ),
        );

      case final _ListBlock lb:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lb.items.map((_Item it) {
              return Padding(
                padding: EdgeInsets.only(
                  left: 4.0 + it.indent * 14.0,
                  top: 2.5,
                  bottom: 2.5,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 22,
                      child: Text(
                        it.marker,
                        style: AppFonts.read(
                          size: widget.baseSize,
                          color: s.muted,
                          height: 1.62,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text.rich(TextSpan(children: inline(it.text))),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        );

      case final _Paragraph p:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text.rich(TextSpan(children: inline(p.text))),
        );
    }
  }
}

// ---------------------------------------------------------------- 行内解析

final RegExp _inlinePattern = RegExp(
  r'(\*\*(.+?)\*\*)' // 1,2 加粗
  r'|(`([^`]+?)`)' // 3,4 行内代码
  // 5,6,7 链接。地址里**允许一层括号** —— 维基那种
  // `.../wiki/Foo_(bar)` 以前会让整条链接匹配失败，
  // 于是原文 `[文字](https://…_(bar))` 原样显示出来（用户看到的就是
  // "有时候 markdown 里的地址不变成链接"）。
  r'|(\[([^\]]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\))'
  r'|(\*([^*\n]+?)\*)' // 8,9 斜体
  r'|(~~(.+?)~~)' // 10,11 删除线
  // 12：**裸链接**（没写成 `[文字](地址)` 的那种）。
  //
  // 模型给地址时经常直接甩一串 `https://…` 在句子里，以前这种既不是链接、
  // 点不了，用户还得手动框选复制。放在**最后**：先让加粗/代码/标准链接
  // 这些明确写法优先，剩下的才当裸链接。
  r'|((?:https?://|www\.)[^\s<>"\]\u3000]+)',
);

/// 一段行内文本里，标准链接（`[文字](地址)`）的**地址**有哪些。
///
/// 给测试用的单一出口：以后链接规则再改，测试跟着这一个函数走，
/// 不用去碰私有的正则。
List<String> inlineLinkTargets(String src) {
  final List<String> out = <String>[];
  for (final RegExpMatch m in _inlinePattern.allMatches(src)) {
    final String? url = m.group(7);
    if (url != null && url.isNotEmpty) out.add(url);
  }
  return out;
}

/// 剥掉裸链接末尾的标点。
///
/// 正文里的地址常常紧跟标点："见 https://a.com/x。" 整段匹配下来最后
/// 那个句号也会被吞进链接里，点进去就是 404。
///
/// 只剥**明显不属于链接**的尾巴；`?a=1&b=2` 这种不动。
/// 右括号单独处理：成对的括号留在链接里（`https://x/a_(b)`），
/// 包围用的那个剥掉（`(见 https://x/a)`）。
String trimUrlTail(String url) {
  const String punct = '.,;:!?、。，；：！？）】》」’”；"\'';
  String u = url;
  while (u.isNotEmpty) {
    final String c = u[u.length - 1];
    if (c == ')') {
      final int open = '('.allMatches(u).length;
      final int close = ')'.allMatches(u).length;
      if (close <= open) break; // 括号是配对的，属于链接本身
      u = u.substring(0, u.length - 1);
      continue;
    }
    if (!punct.contains(c)) break;
    u = u.substring(0, u.length - 1);
  }
  return u;
}

/// 行内数学公式：`$...$`、`$$...$$`、`\(...\)`、`\[...\]`。
///
/// 用「开 `$` 后不能紧跟空白、闭 `$` 前不能是空白、闭 `$` 后不能紧跟数字」
/// 这条通用规则，这样「价格是 $5 到 $10」不会被误判成公式。
/// 刻意不用 lookbehind —— Dart 的 RegExp 在各平台上对它的支持不一致。
///
/// `$$...$$` / `\[...\]` 必须排在最前面：否则一句话中间的 `$$x$$`
/// 会被当成两个 `$...$`，屏幕上留下两个孤零零的美元符号
/// （这正是"有些公式渲染不出来"的常见来源之一）。
final RegExp _inlineMathPattern = RegExp(
  r'\$\$((?:\\.|[^$\\])+?)\$\$'
  r'|\\\[((?:\\.|[^\\])+?)\\\]'
  r'|\$(?!\s)((?:\\.|[^$\\\n])*?[^\s$\\])\$(?!\d)'
  r'|\\\(((?:\\.|[^\\\n])+?)\\\)',
);

/// 数学解析失败时的兜底：把原始 LaTeX 显示出来，而不是整块渲染崩掉。
Widget _mathFallback(String latex, AppSurface s, double size) {
  return Text(
    latex,
    style: AppFonts.code(size: size - 1, color: s.muted),
  );
}

List<InlineSpan> _inlineSpans(
  String src,
  TextStyle base,
  TextStyle code,
  AppSurface s,
  void Function(String url)? onOpenLink,
) {
  // 先按行内公式切分：公式段直接交给 KaTeX 渲染，
  // 其余段落再走常规的行内解析。这样公式里的 `*` `_` 不会被当成强调标记。
  if (!src.contains(r'$') && !src.contains(r'\(') && !src.contains(r'\[')) {
    return _plainInline(src, base, code, s, onOpenLink);
  }

  final List<InlineSpan> spans = <InlineSpan>[];
  int last = 0;

  for (final RegExpMatch m in _inlineMathPattern.allMatches(src)) {
    if (m.start > last) {
      spans.addAll(
        _plainInline(src.substring(last, m.start), base, code, s, onOpenLink),
      );
    }

    // 第 1、2 组是 `$$...$$` / `\[...\]`（整行公式），3、4 组是行内形式
    final bool display = m.group(1) != null || m.group(2) != null;
    final String latex =
        (m.group(1) ?? m.group(2) ?? m.group(3) ?? m.group(4) ?? '').trim();
    if (latex.isEmpty) {
      spans.add(TextSpan(text: src.substring(m.start, m.end), style: base));
    } else {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _mathWidget(
            latex,
            display ? MathStyle.display : MathStyle.text,
            base,
            s,
            fallbackSize: base.fontSize ?? 15,
          ),
        ),
      );
    }
    last = m.end;
  }

  if (last < src.length) {
    spans.addAll(_plainInline(src.substring(last), base, code, s, onOpenLink));
  }
  return spans;
}

/// 把一段已解析好的行内 span 列表**按标记重新切分**。
///
/// ## 为什么做成"事后切分"而不是在解析时处理
///
/// 标记（荧光笔）和引用锚点（虚线）要能盖在**任意**行内元素上：
/// 加粗、斜体、行内代码、链接…如果塞进 `_plainInline` 的正则流程里，
/// 就得在每一条分支里都考虑一次标记边界，代码会翻倍还容易漏。
///
/// 换个思路：先照常解析出 spans，再把它们**摊平成"逐字符 + 样式"的数组**，
/// 然后在字符数组上盖标记 —— 最后把相同样式合并回 spans。
/// 解析逻辑一行都不用动，标记也天然支持所有行内样式。
///
/// 摊平之后偏移量问题也自动消失：查找直接在**完整的可见文本**上做，
/// 不用担心原本跨了三个 span。
///
/// ⚠️ 公式（`Math.tex`）是 `WidgetSpan`，没法拆到字符级，所以
/// **公式内部画不了标记**。可接受：标记是用来标正文的。
List<InlineSpan> _applyMarks(
  List<InlineSpan> spans,
  List<TextMark> marks,
  AppSurface s,
  bool dark,
  Map<String, int> seen,
) {
  if (marks.isEmpty || spans.isEmpty) return spans;

  // ---- 1. 摊平成"逐字符 + 样式" ----
  final StringBuffer buf = StringBuffer();
  final List<TextStyle?> styles = <TextStyle?>[];
  // WidgetSpan 没法拆字，整体保留，位置记下来
  final Map<int, WidgetSpan> widgets = <int, WidgetSpan>{};

  for (final InlineSpan sp in spans) {
    if (sp is WidgetSpan) {
      widgets[buf.length] = sp;
      // 占一个位置，保证后面字符的索引和 widgets 的 key 对得上
      buf.write('\u0000');
      styles.add(null);
      continue;
    }
    final String t = sp is TextSpan ? (sp.text ?? '') : sp.toPlainText();
    final TextStyle? st = sp is TextSpan ? sp.style : null;
    for (int i = 0; i < t.length; i++) {
      buf.write(t[i]);
      styles.add(st);
    }
  }

  final String plain = buf.toString();
  final List<TextStyle?> out = List<TextStyle?>.from(styles);

  // ---- 2. 在字符上盖标记 ----
  //
  // 每条标记只盖**它自己那一处**（`occurrence` = "全文第几次出现"）。
  //
  // ## 关键：这个函数是**按块**调用的，而次序是**全文**的
  //
  // 一个段落调一次 `_applyMarks`，但 `occurrence` 是创建标记时在整条消息的
  // 原文上算出来的。两个语境对不上，于是（用户报的）一条 `occurrence = 0`
  // 的标记会在**每个含这段文字的块里各亮一处** —— 标一个「的」，
  // 五个段落里的第一个「的」全亮了。
  //
  // 所以这里维护一本账 `seen`：**前面那些块里，这个文字已经出现过几次**。
  // 把全局次序换算成本块内的次序：
  //
  //     local = occurrence - 前面出现过几次
  //
  // `0 <= local < 本块出现次数` → 命中，盖在本块第 (local + 1) 个上；
  // `local < 0` → 这一处已经过去了，跳过。
  //
  // 账本**先一次性推进**（每个 needle 只算一次），再按算好的 `before` 盖 ——
  // 顺序反了的话，同一块里两条标记会互相把对方的基准算歪。
  final Map<String, int> before = <String, int>{};
  final Set<String> needles = <String>{
    for (final TextMark m in marks)
      if (m.text.isNotEmpty) m.text,
  };
  for (final String needle in needles) {
    before[needle] = seen[needle] ?? 0;
    int count = 0;
    int at = 0;
    while (true) {
      final int k = plain.indexOf(needle, at);
      if (k < 0) break;
      count++;
      at = k + needle.length;
    }
    seen[needle] = before[needle]! + count;
  }

  for (final TextMark m in marks) {
    final String needle = m.text;
    if (needle.isEmpty) continue;

    final int local = m.occurrence - (before[needle] ?? 0);
    if (local < 0) continue; // 那一处在前面的块里，已经过去了

    // 走到本块内第 local 次出现的下标
    int idx = -1;
    int from = 0;
    for (int n = 0; n <= local; n++) {
      idx = plain.indexOf(needle, from);
      if (idx < 0) break;
      from = idx + needle.length;
    }
    // 本块里次数不够 → 跳过（会在后面的块里对上）
    if (idx < 0) continue;

    for (int k = idx; k < idx + needle.length && k < out.length; k++) {
      if (out[k] == null) continue; // 公式占位，跳过
      out[k] = switch (m.kind) {
        // 引用锚点：一道**虚线**下划线。
        // 为什么用虚线而不是底色：底色已经被"标记"占用了，
        // 而同一个位置可能既被标记又被引用，两种都要能同时看出来。
        MarkKind.quote => out[k]!.copyWith(
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dashed,
          decorationColor: s.muted,
          decorationThickness: 1.6,
        ),
        MarkKind.mark => out[k]!.copyWith(
          backgroundColor: m.color.background(dark: dark),
        ),
      };
    }
  }

  // ---- 3. 把相邻同样式合并回去 ----
  //
  // 不合并的话每个字符都是一个 TextSpan —— 一段 500 字的正文会变成
  // 500 个 span，布局开销大得离谱。
  final List<InlineSpan> result = <InlineSpan>[];
  final StringBuffer run = StringBuffer();
  TextStyle? runStyle;

  void flush() {
    if (run.isEmpty) return;
    result.add(TextSpan(text: run.toString(), style: runStyle));
    run.clear();
  }

  for (int i = 0; i < out.length; i++) {
    final WidgetSpan? w = widgets[i];
    if (w != null) {
      flush();
      result.add(w);
      runStyle = null;
      continue;
    }
    if (run.isEmpty) {
      runStyle = out[i];
      run.write(plain[i]);
    } else if (out[i] == runStyle) {
      run.write(plain[i]);
    } else {
      flush();
      runStyle = out[i];
      run.write(plain[i]);
    }
  }
  flush();

  return result;
}

/// 不含公式的常规行内解析
List<InlineSpan> _plainInline(
  String src,
  TextStyle base,
  TextStyle code,
  AppSurface s,
  void Function(String url)? onOpenLink,
) {
  final List<InlineSpan> spans = <InlineSpan>[];
  int last = 0;

  for (final RegExpMatch m in _inlinePattern.allMatches(src)) {
    if (m.start > last) {
      spans.add(TextSpan(text: src.substring(last, m.start), style: base));
    }

    if (m.group(2) != null) {
      spans.add(
        TextSpan(
          text: m.group(2),
          style: base.copyWith(fontWeight: FontWeight.w600),
        ),
      );
    } else if (m.group(4) != null) {
      spans.add(TextSpan(text: ' ${m.group(4)} ', style: code));
    } else if (m.group(6) != null) {
      final String label = m.group(6)!;
      final String url = m.group(7)!;
      final TextStyle linkStyle = base.copyWith(
        color: AppColors.accent,
        decoration: TextDecoration.underline,
        decorationColor: AppColors.accent.withValues(alpha: 0.4),
      );
      // 用 WidgetSpan 承载点击：在 StatelessWidget 里持有 TapGestureRecognizer
      // 没法可靠 dispose，会泄漏。
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: onOpenLink == null ? null : () => onOpenLink(url),
            child: Text(label, style: linkStyle),
          ),
        ),
      );
    } else if (m.group(9) != null) {
      spans.add(
        TextSpan(
          text: m.group(9),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    } else if (m.group(11) != null) {
      spans.add(
        TextSpan(
          text: m.group(11),
          style: base.copyWith(decoration: TextDecoration.lineThrough),
        ),
      );
    } else if (m.group(12) != null) {
      // 裸链接：显示原文，点开时补全协议（`www.x.com` 要变成 https）。
      final String raw = m.group(12)!;
      final String shown = trimUrlTail(raw);
      final String url = shown.startsWith('www.') ? 'https://$shown' : shown;
      final TextStyle linkStyle = base.copyWith(
        color: AppColors.accent,
        decoration: TextDecoration.underline,
        decorationColor: AppColors.accent.withValues(alpha: 0.4),
      );
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: onOpenLink == null ? null : () => onOpenLink(url),
            child: Text(shown, style: linkStyle),
          ),
        ),
      );
      // 被剥掉的尾巴（句号、逗号…）要**原样留在正文里**，
      // 否则"见 https://a.com。"会变成"见 https://a.com"少一个句号。
      if (shown.length < raw.length) {
        spans.add(TextSpan(text: raw.substring(shown.length), style: base));
      }
    }

    last = m.end;
  }

  if (last < src.length) {
    spans.add(TextSpan(text: src.substring(last), style: base));
  }
  return spans;
}

// ---------------------------------------------------------------- 代码块

class _CodeBlockView extends StatelessWidget {
  const _CodeBlockView({
    required this.block,
    required this.surface,
    this.defer = false,
  });

  final _CodeBlock block;
  final AppSurface surface;

  /// 流式期间为 true：**只画裸代码**。
  ///
  /// 卡片底、语言栏、复制按钮都先不出现 —— 这些是"定稿后的代码块"才有的
  /// 元素，半截代码套上它们会显得像已经生成完了，而且每来一个 token
  /// 都要重排一次卡片。等消息结束、`streaming` 变 false，同一块会切回
  /// 完整样式。
  final bool defer;

  @override
  Widget build(BuildContext context) {
    if (defer) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            block.code,
            style: AppFonts.code(size: 13, color: surface.text),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // ---- 语言标签 + 复制按钮，都在代码框**外面** ----
          //
          // 复制按钮原来浮在代码框**内部**的右上角（`Stack` + `Positioned`）。
          // 那样有三个毛病：
          //  · 它压住了代码本身（所以代码右侧必须留 46px 空白，
          //    短代码看着右边空一大块）；
          //  · 代码横向滚动时它不动，看着像"贴在代码上的一个异物"；
          //  · 长代码第一行最右边几个字符会被它挡住。
          //
          // 移到外面的同一行：左边语言名、右边复制按钮，代码框保持完整。
          Row(
            children: <Widget>[
              if (block.lang.isNotEmpty)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      block.lang,
                      style: AppFonts.body(
                        size: 11.5,
                        weight: FontWeight.w600,
                        color: surface.muted,
                        height: 1.2,
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
              IconButton(
                iconSize: 15,
                // 紧凑一点：它已经不在代码框里了，不需要 30px 的点击区
                // 去和代码争空间。
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: '复制代码',
                icon: Icon(Icons.copy_rounded, color: surface.muted),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: block.code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制'),
                      duration: Duration(milliseconds: 1200),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: surface.codeBg,
              borderRadius: BorderRadius.circular(AppRadius.code),
              border: Border.all(color: surface.border, width: 0.7),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // 右边不再留出按钮的位置 —— 按钮已经出去了
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              child: Text(
                block.code,
                style: AppFonts.code(size: 13, color: surface.text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 表格

/// 表格渲染。
///
/// 手机上表格放不下是常态，所以：
///  · 整表可横向滚动；
///  · 单列宽度按内容估算并限幅，超长的单元格自动换行而不是把表格撑到天边。
class _TableView extends StatelessWidget {
  const _TableView({
    required this.block,
    required this.surface,
    required this.baseSize,
    this.onOpenLink,
    this.marks = const <TextMark>[],
    this.dark = false,
    this.seenRuns,
  });

  final _TableBlock block;
  final AppSurface surface;
  final double baseSize;
  final void Function(String url)? onOpenLink;

  /// 表格单元格里的文字也要能带标记（见 [MarkdownView.marks]）
  final List<TextMark> marks;
  final bool dark;

  /// 外层那一遍渲染的**出现次数账本**（见 `_MarkdownViewState._seenRuns`）。
  /// 表格是独立 widget，只能把这份状态传进来 —— 不传的话单元格里的
  /// "第几次出现"就无从换算（"标一个字，表格里那个也被标上"）。
  final Map<String, int>? seenRuns;

  /// 粗估一段文本的像素宽度：CJK/全角按 1 em，其余按 0.56 em。
  /// 不需要精确——只用来给列定个合理宽度。
  static double _estimate(String text, double fontSize) {
    double w = 0;
    for (final int r in text.runes) {
      final bool wide =
          (r >= 0x1100 && r <= 0x115F) ||
          (r >= 0x2E80 && r <= 0xA4CF) ||
          (r >= 0xAC00 && r <= 0xD7A3) ||
          (r >= 0xF900 && r <= 0xFAFF) ||
          (r >= 0xFE30 && r <= 0xFE6F) ||
          (r >= 0xFF00 && r <= 0xFF60) ||
          (r >= 0xFFE0 && r <= 0xFFE6);
      w += fontSize * (wide ? 1.0 : 0.56);
    }
    return w;
  }

  List<double> _columnWidths() {
    final int cols = block.headers.length;
    final List<double> widths = List<double>.filled(cols, 0);

    for (int c = 0; c < cols; c++) {
      double w = _estimate(block.headers[c], baseSize - 1.5);
      for (final List<String> row in block.rows) {
        if (c < row.length) {
          final double rw = _estimate(row[c], baseSize - 1.5);
          if (rw > w) w = rw;
        }
      }
      // +20 是左右内边距，再夹在 [58, 240] 之间
      widths[c] = (w + 22).clamp(58.0, 240.0);
    }
    return widths;
  }

  @override
  Widget build(BuildContext context) {
    final List<double> widths = _columnWidths();
    final TextStyle headStyle = AppFonts.read(
      size: baseSize - 1.5,
      weight: FontWeight.w600,
      color: surface.text,
      height: 1.45,
    );
    final TextStyle cellStyle = AppFonts.read(
      size: baseSize - 1.5,
      color: surface.text,
      height: 1.45,
    );
    final TextStyle codeStyle = AppFonts.code(
      size: baseSize - 2.3,
      color: surface.text,
      height: 1.45,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.code),
          border: Border.all(color: surface.border, width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildRow(
                block.headers,
                widths,
                headStyle,
                codeStyle,
                isHeader: true,
              ),
              for (int i = 0; i < block.rows.length; i++)
                _buildRow(
                  block.rows[i],
                  widths,
                  cellStyle,
                  codeStyle,
                  isHeader: false,
                  isLast: i == block.rows.length - 1,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(
    List<String> cells,
    List<double> widths,
    TextStyle style,
    TextStyle codeStyle, {
    required bool isHeader,
    bool isLast = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isHeader ? surface.surface : null,
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: surface.gridLine, width: 0.7)),
      ),
      child: IntrinsicHeight(
        // 必须包一层 IntrinsicHeight：横向滚动容器里高度约束是无穷的，
        // 直接给 Row 用 CrossAxisAlignment.stretch 会触发
        // 「BoxConstraints forces an infinite height」。
        // IntrinsicHeight 先把行高算出来，再让各单元格等高。
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < widths.length; i++)
              Container(
                width: widths[i],
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: i == 0
                    ? null
                    : BoxDecoration(
                        border: Border(
                          left: BorderSide(color: surface.gridLine, width: 0.7),
                        ),
                      ),
                child: Text.rich(
                  TextSpan(
                    children: _applyMarks(
                      _inlineSpans(
                        i < cells.length ? cells[i] : '',
                        style,
                        codeStyle,
                        surface,
                        onOpenLink,
                      ),
                      marks,
                      surface,
                      dark,
                      // 表格也共用外层这一遍的"已用掉"集合 ——
                      // 不传的话同一个标记会在表格单元格里再标一遍。
                      seenRuns ?? <String, int>{},
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 解析

/// 解析结果的一个**只读快照**，给测试用。
///
/// ## 为什么不直接把 `_Block` 暴露出去
///
/// `_Block` 是私有的 sealed 类族，7 个子类各自带着不同的构造参数。
/// 把它整个公开等于把内部结构变成公开 API —— 以后想调整解析器的
/// 数据形状就会变成破坏性改动。
///
/// 测试真正关心的只有三件事：**块的种类、里面的文字、图片的地址**。
/// 所以只暴露这三样，内部怎么改都不影响测试。
class MdBlockInfo {
  const MdBlockInfo({required this.kind, this.text, this.src, this.alt});

  /// `paragraph` / `heading` / `code` / `image` / `list` / `quote` /
  /// `table` / `math` / `hr`
  final String kind;

  /// 文字内容（图片块为 null，列表块是各条拼起来）
  final String? text;

  /// 图片地址（只有 `image` 有）
  final String? src;

  /// 图片说明（只有 `image` 有）
  final String? alt;
}

/// 把 Markdown 解析成块列表，供测试断言。
///
/// 加它是因为图片识别有个**静默失败**模式：正则写错时不会抛异常，
/// 图片只是退化成一段 `![x](y)` 原文 —— 那看起来像"模型没按格式写"，
/// 而实际是解析器的问题。没有这个钩子就只能靠肉眼看渲染结果。
@visibleForTesting
List<MdBlockInfo> debugParseBlocks(String src) {
  return _parseBlocks(src).map((_Block b) {
    return switch (b) {
      _Paragraph p => MdBlockInfo(kind: 'paragraph', text: p.text),
      _Heading h => MdBlockInfo(kind: 'heading', text: h.text),
      _CodeBlock c => MdBlockInfo(kind: 'code', text: c.code),
      _MathBlock m => MdBlockInfo(kind: 'math', text: m.latex),
      _Quote q => MdBlockInfo(kind: 'quote', text: q.text),
      _Hr() => const MdBlockInfo(kind: 'hr'),
      _ListBlock l => MdBlockInfo(
        kind: 'list',
        text: l.items.map((_Item i) => i.text).join('\n'),
      ),
      _TableBlock t => MdBlockInfo(
        kind: 'table',
        text: <String>[...t.headers, ...t.rows.expand((r) => r)].join('|'),
      ),
      _ImageBlock i => MdBlockInfo(kind: 'image', src: i.src, alt: i.alt),
    };
  }).toList();
}

sealed class _Block {
  const _Block();
}

/// 块级 widget 缓存的一格（见 `_MarkdownViewState._blockCache`）。
class _CachedBlock {
  const _CachedBlock(this.sig, this.widget);

  /// 这一块的渲染签名（块类型 + 全部数据）。
  final String sig;

  /// 上一帧构建出来的 widget 实例。**同一个实例**交回去时，
  /// Flutter 的 `updateChild` 会跳过整棵子树的更新与布局。
  final Widget widget;
}

class _Paragraph extends _Block {
  const _Paragraph(this.text);
  final String text;
}

class _Heading extends _Block {
  const _Heading(this.level, this.text);
  final int level;
  final String text;
}

class _CodeBlock extends _Block {
  const _CodeBlock(this.lang, this.code);
  final String lang;
  final String code;
}

/// 块级数学公式（`$$...$$` 或 `\[...\]`）
class _MathBlock extends _Block {
  const _MathBlock(this.latex);
  final String latex;
}

class _Quote extends _Block {
  const _Quote(this.text);
  final String text;
}

class _Hr extends _Block {
  const _Hr();
}

class _Item {
  const _Item(this.indent, this.marker, this.text);
  final int indent;
  final String marker;
  final String text;
}

class _ListBlock extends _Block {
  const _ListBlock(this.items);
  final List<_Item> items;
}

class _TableBlock extends _Block {
  const _TableBlock(this.headers, this.rows);
  final List<String> headers;
  final List<List<String>> rows;
}

/// **正文里的一张图片**（`![说明](地址)` 单独占一行）。
///
/// ## 为什么不复用 `card:image`
///
/// `card:image` 是"整块卡片"：带来源标注、点开全屏、上下留白很大。
/// 它适合"这张图就是整个回答"，但用户真正要的是**图插在文字中间**
/// —— 先说一段、给出图、再讲这段图。
///
/// 所以这里做成一个普通块：跟着文字流走，和段落同样的间距。
/// 模型写 Markdown 图片语法是最自然的表达方式，不该逼它改用代码块。
class _ImageBlock extends _Block {
  const _ImageBlock(this.src, this.alt);
  final String src;
  final String alt;
}

final RegExp _reFence = RegExp(r'^\s*```(.*)$');
final RegExp _reHeading = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _reHr = RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$');
final RegExp _reList = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');
final RegExp _reQuote = RegExp(r'^\s*>\s?(.*)$');

/// 独立成行的 Markdown 图片：`![说明](地址)`，允许前后有空白。
///
/// ## 为什么要求**整行只有图**
///
/// 行内混排（"见下图 ![x](y) 所示"）在 Flutter 里要做成 `WidgetSpan`
/// 并参与文字基线对齐 —— 图片一大就会把行高撑得很难看，
/// 而且 `SelectionArea` 选中跨越 WidgetSpan 的行为在各版本上不一致
/// （用户本来就反馈过复制有问题）。
///
/// 让模型把图单独放一行是**低成本且符合习惯**的约定：
/// Markdown 里插图本来绝大多数就是独占一行。
/// 混排时退化成普通文字（含 `![](...)` 原文），可见且不丢信息。
final RegExp _reImageLine = RegExp(r'^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*$');

/// 表格分隔行：只由 | - : 空格组成，且至少有一个短横
final RegExp _reTableSep = RegExp(r'^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$');

bool _startsBlock(String line) {
  final String t = line.trimLeft();
  return t.startsWith('```') ||
      t.startsWith(r'$$') ||
      t.startsWith(r'\[') ||
      t.startsWith(r'\begin{') ||
      _reHeading.hasMatch(line) ||
      _reHr.hasMatch(line) ||
      _reList.hasMatch(line) ||
      _reImageLine.hasMatch(line) ||
      t.startsWith('>');
}

/// 拆一行表格单元格，容忍首尾竖线可有可无
List<String> _splitTableRow(String line) {
  String s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|')) s = s.substring(0, s.length - 1);
  return s.split('|').map((String c) => c.trim()).toList();
}

bool _isTableSeparator(String line) {
  final String s = line.trim();
  if (!s.contains('-')) return false;
  if (!s.contains('|') && !_reHr.hasMatch(s)) {
    // 没有竖线时只认 `---` 这种，避免把普通文本当分隔行
    return false;
  }
  return _reTableSep.hasMatch(s);
}

/// 判断第 [i] 行是否是一张表的开始（当前行有内容 + 下一行是分隔行）
bool _isTableStart(List<String> lines, int i) {
  if (i + 1 >= lines.length) return false;
  final String head = lines[i].trim();
  if (head.isEmpty) return false;
  if (!head.contains('|')) return false;
  return _isTableSeparator(lines[i + 1]);
}

List<_Block> _parseBlocks(String src) {
  final List<String> lines = src.replaceAll('\r\n', '\n').split('\n');
  final List<_Block> blocks = <_Block>[];
  int i = 0;

  while (i < lines.length) {
    final String line = lines[i];

    // 围栏代码块
    final RegExpMatch? fence = _reFence.firstMatch(line);
    if (fence != null) {
      final String lang = fence.group(1)!.trim();
      final List<String> buf = <String>[];
      i++;
      while (i < lines.length && !_reFence.hasMatch(lines[i])) {
        buf.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // 跳过收尾的 ```
      blocks.add(_CodeBlock(lang, buf.join('\n')));
      continue;
    }

    // 块级公式：$$ ... $$（可跨行）或 \[ ... \]
    final String trimmed = line.trim();
    if (trimmed.startsWith(r'$$') || trimmed.startsWith(r'\[')) {
      final bool dollar = trimmed.startsWith(r'$$');
      final String open = dollar ? r'$$' : r'\[';
      final String close = dollar ? r'$$' : r'\]';

      // 同一行就收尾：$$x = 1$$ —— 公式后面如果还跟着说明文字，
      // 不能让它把后文一起吞掉（模型很爱写 `$$E=mc^2$$ 其中 E 是能量`）。
      final int closeAt = trimmed.indexOf(close, open.length);
      if (closeAt > open.length - 1) {
        final String inner = trimmed.substring(open.length, closeAt).trim();
        final String tail = trimmed.substring(closeAt + close.length).trim();
        if (inner.isNotEmpty) blocks.add(_MathBlock(inner));
        if (tail.isNotEmpty) blocks.add(_Paragraph(tail));
        i++;
        continue;
      }

      // 多行形式：一直读到收尾标记
      final List<String> buf = <String>[];
      final String rest = trimmed.substring(open.length).trim();
      if (rest.isNotEmpty) buf.add(rest);
      i++;
      while (i < lines.length && !lines[i].trim().endsWith(close)) {
        buf.add(lines[i]);
        i++;
      }
      if (i < lines.length) {
        final String tail = lines[i].trim();
        final String inner = tail
            .substring(0, tail.length - close.length)
            .trim();
        if (inner.isNotEmpty) buf.add(inner);
        i++;
      }
      blocks.add(_MathBlock(buf.join('\n').trim()));
      continue;
    }

    // 裸的 LaTeX 环境：模型经常直接写 `\begin{align}…\end{align}`，
    // 外面不套 `$$`。以前这会被当成普通段落，原样显示成一串反斜杠。
    if (trimmed.startsWith(r'\begin{')) {
      final RegExpMatch? env = RegExp(r'^\\begin\{([a-zA-Z]+\*?)\}')
          .firstMatch(trimmed);
      if (env != null && mathEnvs.contains(env.group(1))) {
        final String name = env.group(1)!;
        final String end = '\\end{$name}';
        final List<String> buf = <String>[trimmed];
        i++;
        while (i < lines.length && !lines[i].contains(end)) {
          buf.add(lines[i]);
          i++;
        }
        if (i < lines.length) {
          buf.add(lines[i]);
          i++;
        }
        blocks.add(_MathBlock(buf.join('\n')));
        continue;
      }
    }

    // 表格：必须排在段落之前，否则表头和分隔行会被当成两段普通文字
    if (_isTableStart(lines, i)) {
      final List<String> headers = _splitTableRow(lines[i]);
      i += 2; // 表头 + 分隔行
      final List<List<String>> rows = <List<String>>[];
      while (i < lines.length) {
        final String t = lines[i].trim();
        if (t.isEmpty || !t.contains('|')) break;
        // 遇到新的块级语法就停
        if (_reHeading.hasMatch(t) || _reFence.hasMatch(t)) break;
        rows.add(_splitTableRow(t));
        i++;
      }
      blocks.add(_TableBlock(headers, rows));
      continue;
    }

    final RegExpMatch? h = _reHeading.firstMatch(line);
    if (h != null) {
      blocks.add(_Heading(h.group(1)!.length, h.group(2)!.trim()));
      i++;
      continue;
    }

    // 独立成行的图片。
    //
    // 必须排在**段落**之前：段落的收集循环靠 `_startsBlock` 判断边界，
    // 而图片行已经加进 `_startsBlock` 了，所以这里只要在到达段落分支前
    // 把它消费掉就行。
    final RegExpMatch? img = _reImageLine.firstMatch(line);
    if (img != null) {
      blocks.add(_ImageBlock(img.group(2)!.trim(), img.group(1)!.trim()));
      i++;
      continue;
    }

    if (_reHr.hasMatch(line)) {
      blocks.add(const _Hr());
      i++;
      continue;
    }

    // 列表：连续的行合并成一个列表块
    final RegExpMatch? l = _reList.firstMatch(line);
    if (l != null) {
      final List<_Item> items = <_Item>[];
      while (i < lines.length) {
        final RegExpMatch? m = _reList.firstMatch(lines[i]);
        if (m == null) break;
        final int indent = (m.group(1)!.length / 2).floor();
        final String token = m.group(2)!;
        final bool ordered = RegExp(r'^\d').hasMatch(token);
        items.add(
          _Item(
            indent,
            ordered ? token.replaceAll(')', '.').trim() : '·',
            m.group(3)!.trim(),
          ),
        );
        i++;
      }
      blocks.add(_ListBlock(items));
      continue;
    }

    final RegExpMatch? q = _reQuote.firstMatch(line);
    if (q != null) {
      final List<String> buf = <String>[];
      while (i < lines.length) {
        final RegExpMatch? m = _reQuote.firstMatch(lines[i]);
        if (m == null) break;
        buf.add(m.group(1)!.trim());
        i++;
      }
      blocks.add(_Quote(buf.join(' ')));
      continue;
    }

    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // 普通段落：一直吃到空行或下一个块开始
    final List<String> buf = <String>[];
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !_startsBlock(lines[i]) &&
        !_isTableStart(lines, i)) {
      buf.add(lines[i].trim());
      i++;
    }
    if (buf.isNotEmpty) blocks.add(_Paragraph(buf.join(' ')));
  }

  return blocks;
}
