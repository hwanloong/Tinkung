import '../plugins/plugin.dart';
import 'folder_tool.dart';

/// 一条 `@` 引用指向的东西。
enum MentionKind {
  /// 文件夹工具（skill）。引用它会**把全文注入**这一轮。
  tool,

  /// 自定义插件。引用它会强调"这一轮请用它"。
  plugin,
}

/// 从输入框文本里解析出来的一条引用。
class Mention {
  const Mention({required this.kind, required this.id});

  final MentionKind kind;
  final String id;

  /// 写回输入框用的标记。
  String get token => '@${kind == MentionKind.tool ? 'tool' : 'plugin'}:$id';

  @override
  String toString() => token;

  @override
  bool operator ==(Object other) =>
      other is Mention && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// `@tool:名字` 或 `@plugin:名字`。
///
/// ## 为什么带前缀而不是光秃秃的 `@名字`
///
/// 光和插件名匹配的话，"@某人"这种正常文字会被当成引用（中文用户名很常见）。
/// 带 `tool:` / `plugin:` 之后，误判空间小得多，而且**一眼能看出引用的是什么**——
/// 用户看到 `@tool:pdf_merge` 就知道那是工具，不是某个人。
class MentionParser {
  const MentionParser._();

  /// 匹配 `@tool:xxx` / `@plugin:xxx`。
  ///
  /// 名字允许字母数字下划线连字符和中文（工具文件夹可能是中文名），
  /// 到空白或标点为止。
  static final RegExp pattern = RegExp(r'@(tool|plugin):([\w\u4e00-\u9fa5-]+)');

  static List<Mention> parse(String text) {
    final List<Mention> out = <Mention>[];
    for (final RegExpMatch m in pattern.allMatches(text)) {
      final MentionKind kind = m.group(1) == 'tool'
          ? MentionKind.tool
          : MentionKind.plugin;
      final Mention mention = Mention(kind: kind, id: m.group(2)!);
      if (!out.contains(mention)) out.add(mention);
    }
    return out;
  }

  /// 把文本里的引用标记去掉（发出去给模型看的时候不需要这些标记本身）。
  static String strip(String text) =>
      text.replaceAll(pattern, '').replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();

  /// 构造要追加到这一轮消息后面的**引用上下文**。
  ///
  /// ## 为什么工具是"注入全文"、插件是"点一句"
  ///
  /// · 工具（skill）的正文就是**做法本身**，不注入等于没引用；
  /// · 插件已经注册成工具了，模型本来就能调，重复贴一遍它的模板没有意义 ——
  ///   但**提醒**有意义：用户明确 `@` 了它，说明这一轮该用它，
  ///   而模型有时会绕开现成工具自己硬写。
  ///
  /// 返回空串表示没有可注入的东西（引用的东西被删了/停用了）。
  static String buildContext(
    String text, {
    required FolderToolStore tools,
    required PluginStore plugins,
  }) {
    final List<Mention> mentions = parse(text);
    if (mentions.isEmpty) return '';

    final StringBuffer sb = StringBuffer();

    for (final Mention m in mentions) {
      if (m.kind == MentionKind.tool) {
        final FolderTool? t = tools.byId(m.id);
        if (t == null || !t.enabled) continue;
        sb.writeln('===== 用户引用的工具：${t.id} =====');
        sb.writeln(tools.readForModel(t));
        sb.writeln('===== 引用结束 =====');
        sb.writeln();
      } else {
        final CustomPlugin? p = plugins.plugins
            .where((CustomPlugin e) => e.name == m.id)
            .firstOrNull;
        if (p == null || !p.enabled) continue;
        sb.writeln(
          '用户明确要求这一轮使用插件 `${p.name}`（${p.title}）。'
          '它就是一个普通工具，直接调用即可。',
        );
        sb.writeln();
      }
    }

    if (sb.isEmpty) return '';
    return '【用户通过 @ 引用指定了以下内容，请据此作答】\n\n$sb';
  }

  /// 引用在界面上显示的名字（工具用标题，插件用标题，找不到就退回 id）。
  static String label(
    Mention m, {
    required FolderToolStore tools,
    required PluginStore plugins,
  }) {
    if (m.kind == MentionKind.tool) {
      return tools.byId(m.id)?.title ?? m.id;
    }
    for (final CustomPlugin p in plugins.plugins) {
      if (p.name == m.id) return p.title;
    }
    return m.id;
  }

  /// 输入框里正在打的这个 `@` fragment 该怎么补全。
  ///
  /// 返回 `(前缀种类, 已输入的部分)`；不在 `@` 语境里返回 null。
  ///
  /// 只在**光标前**找，且要求 `@` 前面是空白或开头 ——
  /// 否则 `a@b.com` 这种邮箱会一直弹补全框。
  static ({MentionKind? kind, String query})? activeFragment(
    String text,
    int cursor,
  ) {
    if (cursor <= 0 || cursor > text.length) return null;
    final String before = text.substring(0, cursor);
    final int at = before.lastIndexOf('@');
    if (at < 0) return null;
    // `@` 前面必须是空白或开头
    if (at > 0 && !RegExp(r'\s').hasMatch(before[at - 1])) return null;

    final String frag = before.substring(at + 1);
    // 已经输入了空格/换行 → 不是在选引用
    if (RegExp(r'\s').hasMatch(frag)) return null;

    if (frag.startsWith('tool:')) {
      return (kind: MentionKind.tool, query: frag.substring(5));
    }
    if (frag.startsWith('plugin:')) {
      return (kind: MentionKind.plugin, query: frag.substring(7));
    }
    // 还在打前缀本身
    if ('tool:'.startsWith(frag)) return (kind: null, query: '');
    if ('plugin:'.startsWith(frag)) return (kind: null, query: '');
    return (kind: null, query: frag);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
