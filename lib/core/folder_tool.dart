import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// **一个"工具"（Tool）**：一个文件夹，里面至少有一个 `tool.md`。
///
/// ## 它和 Rule、Plugin 的分工
///
/// 三者都是"给 agent 增加能力/约束"，但作用完全不同，混在一起会很难用：
///
/// | | 存在形式 | 生效方式 | 用来解决 |
/// |---|---|---|---|
/// | **Rule** | `rules.json` 里一条文本 | 每轮**无条件**进系统提示词 | "以后回答简短点"这类**约束** |
/// | **Plugin** | `plugins.json` 里一条模板 | 注册成一个**新工具**，模型直接调用 | "加一个查天气的工具"这类**新动作** |
/// | **Tool**（这个） | `tools/<名字>/tool.md` + 附件 | 模型按需**读取**，然后按里面的步骤做 | "怎么把这件事做好"这类**方法/流程** |
///
/// 为什么 Tool 不直接注册成工具：一套流程可能几十行说明、还带几个脚本，
/// 注册成工具会让**每一轮**的工具列表都背着它（工具列表越长，模型选错的
/// 概率越高）。所以 Tool 是"按需取用"的：提示词里只放一句索引，
/// 模型觉得相关才去读全文。
///
/// ## 为什么是文件夹而不是一个文件
///
/// 因为"流程"经常要带东西：一段示例脚本、一个模板、一份字段说明、
/// 几张参考图。单文件只能塞进 markdown 里，模型要自己从正文里抠出来
/// 再写到磁盘上才能跑 —— 多一步，而且容易抠错。
///
/// 文件夹形态下这些文件**原样就在**，模型读到的路径是真的，
/// 直接能用 `shell` / `file_read` 去操作。
class FolderTool {
  FolderTool({
    required this.id,
    required this.title,
    this.description = '',
    this.whenToUse = '',
    this.version = 1,
    this.body = '',
    this.intro = '',
    this.files = const <String>[],
    this.iconPath = '',
    required this.folderPath,
    this.enabled = true,
  });

  /// 文件夹名，也是引用时用的名字（`@tool:pdf_merge`）。
  final String id;

  final String title;

  /// 一句话说明"这是什么"。进系统提示词的索引里。
  final String description;

  /// **什么时候该用它**。索引里也会带，因为它决定模型会不会想到它。
  final String whenToUse;

  final int version;

  /// `tool.md` 去掉 frontmatter 之后的正文（真正的步骤说明）。
  final String body;

  /// **备注**（`intro.md` 的全文）。
  ///
  /// ## 为什么要单独一个文件，而不是写进 `tool.md`
  ///
  /// `tool.md` 是**给模型看的执行说明**，而这一个是**给人看的备注**：
  /// 这个工具从哪来、为什么要做、有哪些坑、改过什么。
  ///
  /// 混在一起会互相干扰：
  ///  · 备注写进 `tool.md`，模型每一轮读到的说明就掺了这些"背景故事"，
  ///    占上下文还容易把它当成指令；
  ///  · 反过来，`tool.md` 里那些命令细节摆在给人看的备注区也很难读。
  ///
  /// 所以分成两个文件、两种读者，各自干净。
  final String intro;

  /// 文件夹里的其它文件（相对路径），不含 `tool.md` 和 `intro.md`。
  final List<String> files;

  /// 图标文件的**绝对路径**，空串表示这个工具没有图标。
  ///
  /// 文件本身叫 `tool.icon`（见 [FolderToolStore.iconName]）。为什么存绝对路径
  /// 而不是"有/没有"的布尔：界面上要直接把它交给 `Image.file`，
  /// 拼路径的地方越少，越不容易出现"图标明明在却显示不出来"。
  final String iconPath;

  bool get hasIcon => iconPath.isNotEmpty;

  /// 绝对路径，给模型读附件时用。
  final String folderPath;

  bool enabled;

  /// 备注里**第一行有内容的话**，用来在列表/`@` 面板里显示一行摘要。
  ///
  /// ## 为什么要专门抽一行，而不是直接用整篇 intro
  ///
  /// `intro.md` 是给自己写的工作笔记：可能几十行、带标题、带
  /// `<!-- -->` 模板注释。塞进列表的一行里会：
  ///  · 把 `<!--` 这种给人看的标记也显示出来（很难看）；
  ///  · 第一行是 `# 标题`，和外面的标题重复。
  ///
  /// 所以规则是：**跳过 HTML 注释块、跳过标题行、取第一行真正的文字**。
  /// 拿不到就返回空串，由调用方回退到 `description`。
  String get noteLine {
    if (intro.trim().isEmpty) return '';

    String text = intro;
    // 去掉 <!-- ... -->（可能跨行）
    text = text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '\n');

    for (final String raw in text.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) continue; // 标题
      if (line.startsWith('---')) continue; // frontmatter 残留
      return line.replaceAll(RegExp(r'\s+'), ' ');
    }
    return '';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'description': description,
    'whenToUse': whenToUse,
    'version': version,
    'enabled': enabled,
  };

  static FolderTool fromJson(Map<String, dynamic> j, {String dir = ''}) =>
      FolderTool(
        id: j['id']?.toString() ?? '',
        title: j['title']?.toString() ?? j['id']?.toString() ?? '',
        description: j['description']?.toString() ?? '',
        whenToUse: j['whenToUse']?.toString() ?? '',
        version: (j['version'] as num?)?.toInt() ?? 1,
        enabled: j['enabled'] != false,
        folderPath: dir,
      );
}

/// 解析 `tool.md` 的 frontmatter。
///
/// 只支持"`---` 包住的一段 `key: value`"，**不引入 YAML 库**：
/// 多一个依赖只为读六个键不值，而且真 YAML 的嵌套/锚点在这里也用不上。
/// 复杂需求应该写在正文里，那本来就是给模型看的。
class FrontMatter {
  const FrontMatter(this.meta, this.body);
  final Map<String, String> meta;
  final String body;

  static FrontMatter parse(String raw) {
    final String text = raw.replaceAll('\r\n', '\n');
    if (!text.startsWith('---')) return FrontMatter(<String, String>{}, text);

    final List<String> lines = text.split('\n');
    // 找收尾的 ---（从第二行开始找，第 0 行是开头那个）
    int end = -1;
    for (int i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        end = i;
        break;
      }
    }
    if (end < 0) {
      // 没有收尾 → 当成没有 frontmatter。
      // 这里**不能**直接报错：用户手写时很容易漏掉那一行，
      // 而漏掉之后整个文件被当成"空正文"才是更难查的失败。
      return FrontMatter(<String, String>{}, text);
    }

    final Map<String, String> meta = <String, String>{};
    for (int i = 1; i < end; i++) {
      final String line = lines[i];
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final int colon = line.indexOf(':');
      if (colon <= 0) continue;
      final String key = line.substring(0, colon).trim();
      String value = line.substring(colon + 1).trim();
      // 去掉成对的引号
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      if (key.isNotEmpty) meta[key] = value;
    }

    final String body = lines.sublist(end + 1).join('\n').trim();
    return FrontMatter(meta, body);
  }
}

/// 一个附件的**元信息**：多大、能不能当文本编辑。
///
/// 为什么单独一个类型而不是两个返回值：判定"能不能编辑"要**读文件头**
/// （异步 IO），而详情页的列表是同步构建的 —— 混在一起会把 IO 塞进渲染路径。
class ToolFileStat {
  const ToolFileStat({required this.size, required this.isText});

  /// 字节数；`-1` = 拿不到（文件不存在/读不了）。
  final int size;

  /// 能不能安全地当文本送进编辑器（判据见 `FolderToolStore._looksText`）。
  final bool isText;

  /// 拿不到信息时的兜底。
  ///
  /// 方向选"文本"是因为它可恢复：编辑器里看到乱码还能退出来删掉；
  /// 反过来把一个其实能编辑的 `.txt` 判成二进制，用户就彻底改不了它了。
  /// （真正决定要不要进编辑器的是点击时那次 `statFile`，不是这个兜底。）
  static const ToolFileStat missing = ToolFileStat(size: -1, isText: true);

  bool get exists => size >= 0;
}

/// 全部 Tool 的仓库。
///
/// 用单例：它在"构建系统提示词"和"注册工具"两条路径上都要读，
/// 而那两条路径在 AgentRunner 深处，一路透传要改十几个文件。
/// （和 RuleStore / MemoryStore 同一个理由。）
class FolderToolStore extends ChangeNotifier {
  FolderToolStore._();

  static final FolderToolStore instance = FolderToolStore._();

  Directory? _dir;
  bool _loaded = false;

  final List<FolderTool> tools = <FolderTool>[];

  bool get loaded => _loaded;

  /// 可用（启用）的那些。
  List<FolderTool> get enabled =>
      tools.where((FolderTool t) => t.enabled).toList();

  static const String manifestName = 'tool.md';

  /// 备注文件名。和 `tool.md` 并列，但**只给人看**。
  static const String introName = 'intro.md';

  // ---------------------------------------------------------------- 工具图标
  //
  // ## 约定：文件夹里放一个 `tool.icon`，它就是图标
  //
  // 为什么不用 frontmatter 里的 `icon: xxx.png` 指路：
  //  · 那个键得手写、得对得上文件名，写错了不会报错，只会"图标不见了"；
  //  · 而这个功能最大的用处是**从相册里挑张图当图标** —— 挑完直接存成
  //    固定名字就有，用户不用回来改一行配置。
  //
  // ## 认哪些格式
  //
  // **认内容，不认扩展名**：Flutter 的 `Image.file` 是按字节解码的，
  // 文件叫 `tool.icon` 还是 `tool.icon.png` 都能显示。所以：
  //  · 恰好叫 `tool.icon` → 直接用它（PNG / JPEG / WebP / GIF / BMP 都行）；
  //  · 叫 `tool.icon.<ext>` → 只有 [iconExtensions] 里的位图格式才算数。
  //
  // **SVG 明确不支持**：它是矢量格式，Flutter 自带的解码器读不了，
  // 要支持就得引入 `flutter_svg`。与其让用户放进去一个永远不显示的图标，
  // 不如在文档和界面里说清楚只收位图 —— `.svg` 会退回默认文件夹图标。

  /// 图标文件名（固定叫这个，不需要扩展名）。
  static const String iconName = 'tool.icon';

  /// 也认 `tool.icon.<ext>` 这种带扩展名的写法（大小写不敏感）。
  static const List<String> iconExtensions = <String>[
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    'bmp',
  ];

  /// 找工具文件夹里的图标文件，返回绝对路径；没有就返回 `null`。
  ///
  /// 只看文件夹**第一层**：图标要的是"一眼能认出来的那一个"，
  /// 允许深层查找只会让"到底哪张在生效"变模糊。
  static String? iconPathIn(Directory dir) {
    try {
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final String lower = _baseName(e.path).toLowerCase();
        // 恰好叫 tool.icon：格式由内容决定，先收下，解码失败时界面会退回字形
        if (lower == iconName) return e.path;
        if (!lower.startsWith('$iconName.')) continue;
        final String ext = lower.substring(iconName.length + 1);
        if (iconExtensions.contains(ext)) return e.path;
      }
    } catch (_) {
      // 目录读不了就当没有图标 —— 列表照常显示，不该因为图标挂掉
    }
    return null;
  }

  /// 取路径最后一段（`/` 和 `\` 都算分隔符；`Uri` 只认前者）。
  static String _baseName(String path) =>
      path.split(RegExp(r'[/\\]')).where((String s) => s.isNotEmpty).last;

  // ------------------------------------------------------------ 外来文件导入
  //
  // ## 为什么要有这一套
  //
  // 工具文件夹里最值钱的东西往往是**从外面拿进来的**：一段已经调通的脚本、
  // 公司给的表单模板、一张参考图。只支持"在编辑器里敲文本"等于要求用户
  // 把 shell 脚本背下来重敲一遍 —— 那不现实。
  //
  // ## 单个文件的上限
  //
  // 8 MB。不是存储的考虑，而是这两条路的实际约束：
  //  · agent 那条路要把文件塞进 base64 再塞进一次工具调用（体积 ×1.33），
  //    再大就不是"写个脚本"，而是在对话里传文件；
  //  · 界面这条路存的是应用私有目录，用户后来想拿走也不方便。
  // 真需要放大文件，用文件管理器直接拷进那个文件夹 —— 文件夹格式本来就是
  // 为了这个才选的。

  static const int maxImportBytes = 8 * 1024 * 1024;

  /// 把字节写进工具文件夹（界面导入和 agent 的 `import_file` 共用这条路）。
  ///
  /// 返回**给用户看的错误文本**，成功是 `null`。故意不抛异常：
  /// 两条调用路径（界面 / 模型）都要把失败原因原样显示出来，
  /// 抛异常的话调用方还得各自决定要不要 catch。
  ///
  /// ### 路径一律过 `_resolveInside`
  ///
  /// 这里的文件名来自**外部**（文件选择器给的显示名、模型给的名字），
  /// 不是用户一个字一个字敲的，所以更不能信。`../../notes.json`、
  /// `/data/data/...` 这类名字必须在**这一层**挡掉：界面、agent、
  /// 以后可能加的批量导入都是调用方，只在界面里清洗等于每加一条路就漏一个洞。
  ///
  /// ### 默认不覆盖
  ///
  /// 同名文件已存在时返回错误而不是静默替换。导入的语义是"把外面的东西拿进来"，
  /// 用户没打算删掉原来那份；覆盖是不可逆的，必须由调用方明确表示
  /// （界面上会先弹一次确认，agent 得显式传 `overwrite`）。
  Future<String?> importBytes(
    FolderTool t,
    String rel,
    Uint8List bytes, {
    bool overwrite = false,
  }) async {
    final File f;
    try {
      f = _resolveInside(t, rel);
    } catch (e) {
      return _plain(e);
    }
    if (bytes.length > maxImportBytes) {
      return '文件太大（${humanSize(bytes.length)}），'
          '单个文件上限 ${humanSize(maxImportBytes)}。'
          '更大的文件请用文件管理器直接拷进这个文件夹。';
    }
    if (f.existsSync() && !overwrite) {
      return '文件夹里已经有 `$rel` 了。要替换它得先确认覆盖。';
    }
    try {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      // 重扫：附件清单和图标都要跟着变（导进来的可能正是 tool.icon）
      await load();
      return null;
    } catch (e) {
      return '写入失败：$e';
    }
  }

  /// 工具文件夹里有没有这个相对路径（界面覆盖前先问一次，别等写失败）。
  bool hasFile(FolderTool t, String rel) {
    try {
      return _resolveInside(t, rel).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// `Exception` 的 `toString()` 会带一个 `Exception: ` 前缀。这些文本是
  /// **直接显示给用户**的（SnackBar / agent 的返回），多出来那个前缀看着像内部错误。
  static String _plain(Object e) {
    final String s = '$e';
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }

  /// 人类可读的大小。`-1` 表示拿不到（文件不存在/读不了）。
  static String humanSize(int bytes) {
    if (bytes < 0) return '大小未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 读一个附件的**大小**和**能不能当文本编辑**。
  ///
  /// 给界面用：非文本文件绝不能送进编辑器（见 `_looksText` 的说明）。
  Future<ToolFileStat> statFile(FolderTool t, String rel) async {
    final File f;
    try {
      f = _resolveInside(t, rel);
      if (!f.existsSync()) return ToolFileStat.missing;
      final int size = await f.length();
      return ToolFileStat(size: size, isText: await _looksText(f, size));
    } catch (_) {
      return ToolFileStat.missing;
    }
  }

  /// 批量版（详情页一次列出所有文件，逐个 await 会排成一串小 IO）。
  Future<Map<String, ToolFileStat>> statFiles(
    FolderTool t,
    List<String> rels,
  ) async {
    final Map<String, ToolFileStat> out = <String, ToolFileStat>{};
    for (final String rel in rels) {
      out[rel] = await statFile(t, rel);
    }
    return out;
  }

  /// 嗅探的字节数。4KB 足够看出 NUL 和编码问题，又不至于为了一个列表
  /// 把几百 KB 的脚本整个读进来。
  static const int _sniffBytes = 4096;

  /// 这个文件能不能安全地当文本打开。
  ///
  /// ## 为什么看内容而不是看扩展名
  ///
  /// 导入进来的文件扩展名会骗人：`.txt` 里可能是张图、`tool.icon` 根本没有
  /// 扩展名、`install.sh` 可能是编译好的二进制。判错的代价不对称：
  ///
  ///  · 把二进制当文本 → 编辑器显示一屏乱码，而用户**只要按一次保存**，
  ///    乱码就会被原样写回去，那个文件就真毁了；
  ///  · 把文本当二进制 → 少一个编辑入口，还能用「打开方式」。
  ///
  /// 所以判据用**内容**：出现 NUL 字节 → 二进制；按 UTF-8 解不开 → 二进制。
  ///
  /// ## 代价：GBK 文本会被判成二进制
  ///
  /// 这是**故意**的。GBK 的中文送进编辑器就是一屏乱码，而乱码改完存回去
  /// 等于毁文件。那种文件应该用「打开方式」交给别的应用。
  static Future<bool> _looksText(File f, int size) async {
    if (size == 0) return true; // 空文件：在编辑器里写内容是正常操作
    RandomAccessFile? raf;
    try {
      raf = await f.open();
      final Uint8List head = await raf.read(
        size < _sniffBytes ? size : _sniffBytes,
      );
      for (final int b in head) {
        if (b == 0) return false;
      }
      // `head` 是**我们截出来的窗口**，不是整份文件：文件比窗口长的时候，
      // 末尾那个多字节字符十有八九被切了一半。所以这种情况允许从尾巴上
      // 一次退一个字节再试（最多退 3 个 = UTF-8 序列最长长度）。
      //
      // 文件整个都在手上时（size <= 窗口）**不退**：那时解码失败就是内容
      // 真的有问题，退字节等于给坏文件开后门。
      final bool truncated = size > _sniffBytes;
      final int maxTrim = truncated ? 3 : 0;
      for (int trim = 0; trim <= maxTrim && trim < head.length; trim++) {
        final Uint8List body = trim == 0
            ? head
            : head.sublist(0, head.length - trim);
        try {
          utf8.decode(body);
          return true;
        } catch (_) {
          // 退一个字节再试
        }
      }
      return false;
    } catch (_) {
      // 读不了就按文本处理：交给编辑器报出真正的原因，比"点不开"好查
      return true;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  Future<void> configure(Directory dir) async {
    _dir = dir;
    await load();
  }

  /// 扫描目录，重建索引。
  ///
  /// 每次调用都**重新扫盘**而不是增量合并：用户可能在文件管理器里
  /// 直接增删文件夹（这正是文件夹格式的意义），增量合并会漏掉那些改动。
  Future<void> load() async {
    final Directory? dir = _dir;
    if (dir == null) return;
    tools.clear();

    try {
      await dir.create(recursive: true);
      final List<FileSystemEntity> entries = dir.listSync();
      for (final FileSystemEntity e in entries) {
        if (e is! Directory) continue;
        final File manifest = File('${e.path}/$manifestName');
        if (!manifest.existsSync()) continue;

        String raw;
        try {
          raw = manifest.readAsStringSync();
        } catch (_) {
          continue; // 单个读不了就跳过，别让整库挂掉
        }
        final FrontMatter fm = FrontMatter.parse(raw);
        final String id = e.uri.pathSegments
            .where((String s) => s.isNotEmpty)
            .last;

        // 附件清单：递归列出，但**跳过隐藏文件和 node_modules 这类**
        // 明显的垃圾目录 —— 用户要是把整个项目拷进来，清单会长到
        // 把上下文吃光。
        final List<String> files = <String>[];
        try {
          for (final FileSystemEntity f in e.listSync(recursive: true)) {
            if (f is! File) continue;
            final String rel = f.path.substring(e.path.length + 1);
            if (rel == manifestName || rel == introName) continue;
            if (rel
                .split(RegExp(r'[/\\]'))
                .any((String s) => s.startsWith('.'))) {
              continue;
            }
            if (rel.contains('node_modules')) continue;
            files.add(rel);
          }
        } catch (_) {}

        // 备注可能不存在（老工具、或者用户没写）—— 那就是空串
        String intro = '';
        try {
          final File introFile = File('${e.path}/$introName');
          if (introFile.existsSync()) intro = introFile.readAsStringSync();
        } catch (_) {}

        tools.add(
          FolderTool(
            id: id,
            title: fm.meta['title']?.trim().isNotEmpty == true
                ? fm.meta['title']!
                : (fm.meta['name']?.isNotEmpty == true ? fm.meta['name']! : id),
            description: fm.meta['description'] ?? '',
            whenToUse: fm.meta['when_to_use'] ?? fm.meta['whenToUse'] ?? '',
            version: int.tryParse(fm.meta['version'] ?? '') ?? 1,
            enabled: fm.meta['enabled']?.toLowerCase() != 'false',
            body: fm.body,
            intro: intro,
            files: files,
            iconPath: iconPathIn(e) ?? '',
            folderPath: e.path,
          ),
        );
      }
    } catch (_) {
      // 整个目录都读不了 → 当空库，界面会显示"还没有工具"
    }

    tools.sort((FolderTool a, FolderTool b) => a.id.compareTo(b.id));
    _loaded = true;
    notifyListeners();
  }

  /// 把随包带的**内置工具**铺到工具目录里。
  ///
  /// ## 现在**一个内置工具都没有**
  ///
  /// 唯一的一个是 `autopilot`（自动化任务）。它已经整个移除：
  /// 没有调度器、没有常驻脚本、没有对应界面。留着这份 `tool.md`
  /// 的危害不是"多一个用不上的工具"，而是**模型会真的去调它** ——
  /// 它在系统提示词里占着一行"什么时候该用"，于是用户说"每隔几分钟
  /// 帮我看着点"时，模型会去读那份说明、然后调用一个不存在的调度器。
  ///
  /// ## 已经播种到磁盘上的副本要**主动删掉**
  ///
  /// 关键点：删掉资产只影响**新装的包**。老用户手机上的
  /// `<应用私有目录>/tools/autopilot/` 是之前某次启动写下去的，
  /// 它和资产没有任何联系 —— 不删的话，升级之后模型**照样**能在
  /// 工具索引里看到它。这就是"代码里明明删干净了，AI 还是会调用"的原因。
  ///
  /// 所以这里做一次清理：只删 **id 恰好是 `autopilot`** 且 `tool.md`
  /// 里的 `name` 也是 autopilot 的目录 —— 用户自己建的同名工具
  /// 不会被误伤（那种情况 id 会是别的，或者他改过 frontmatter）。
  static const List<String> _removed = <String>['autopilot'];

  Future<void> seedFromAssets() async {
    final Directory? dir = _dir;
    if (dir == null) return;
    await _purgeRemoved(dir);
    await load();
  }

  /// 删掉历史上播种过、现在已经下线的内置工具。
  Future<void> _purgeRemoved(Directory dir) async {
    for (final String id in _removed) {
      final Directory folder = Directory('${dir.path}/$id');
      if (!folder.existsSync()) continue;
      final File manifest = File('${folder.path}/$manifestName');
      // 只删"确实是我们播出去的那份"：frontmatter 里的 name 必须对得上。
      // 用户自己建的工具（哪怕文件夹恰好叫 autopilot）frontmatter 是他写的，
      // 里面不会有我们当年那份说明 —— 但为了稳妥，宁可多确认一步。
      try {
        if (manifest.existsSync()) {
          final String raw = await manifest.readAsString();
          final FrontMatter fm = FrontMatter.parse(raw);
          if ((fm.meta['name'] ?? '').trim() != id) continue;
        }
        await folder.delete(recursive: true);
      } catch (_) {
        // 删不掉不该拦住启动；下次启动再试一次
      }
    }
  }

  FolderTool? byId(String id) {
    final String key = id.trim();
    for (final FolderTool t in tools) {
      if (t.id == key) return t;
    }
    return null;
  }

  /// 新建一个工具文件夹 + 一个模板 `tool.md`。
  ///
  /// 返回错误文本（成功时是 null）。**不覆盖已有的** ——
  /// 覆盖等于把用户写好的东西删了，而这是不可撤销的。
  Future<String?> create(String id) async {
    final Directory? dir = _dir;
    if (dir == null) return '工具目录还没就绪';
    final String name = id.trim();
    if (name.isEmpty) return '名字不能为空';
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name)) {
      return '名字只能用字母、数字、下划线、连字符（它会是文件夹名）';
    }
    final Directory target = Directory('${dir.path}/$name');
    if (target.existsSync()) return '已经有一个叫 $name 的工具了';

    try {
      await target.create(recursive: true);
      await File('${target.path}/$manifestName').writeAsString(_template(name));
      await load();
      return null;
    } catch (e) {
      return '创建失败：$e';
    }
  }

  Future<String?> remove(String id) async {
    final FolderTool? t = byId(id);
    if (t == null) return '找不到这个工具';
    try {
      await Directory(t.folderPath).delete(recursive: true);
      await load();
      return null;
    } catch (e) {
      return '删除失败：$e';
    }
  }

  /// 切换启用。写回 `tool.md` 的 frontmatter 而不是另存一个状态文件 ——
  /// 状态跟着工具走，拷走文件夹时它一起过去，不会出现"拷过去变成启用了"。
  Future<String?> setEnabled(String id, bool enabled) async {
    final FolderTool? t = byId(id);
    if (t == null) return '找不到这个工具';
    final File manifest = File('${t.folderPath}/$manifestName');
    try {
      final FrontMatter fm = FrontMatter.parse(await manifest.readAsString());
      final Map<String, String> meta = Map<String, String>.from(fm.meta);
      meta['enabled'] = enabled ? 'true' : 'false';
      await manifest.writeAsString(_rebuild(meta, fm.body));
      await load();
      return null;
    } catch (e) {
      return '保存失败：$e';
    }
  }

  /// 改**显示名称**（`tool.md` frontmatter 里的 `title`）。
  ///
  /// 只动 title 一个键，其它 frontmatter 原样保留 —— 用 `_rebuild` 重建，
  /// 不整体重写文件，否则用户手写的其它键（version / enabled /
  /// 自定义字段）会被悄悄抹掉。
  Future<String?> setTitle(String id, String title) async {
    final String name = title.trim();
    if (name.isEmpty) return '名称不能为空';
    final FolderTool? t = byId(id);
    if (t == null) return '找不到这个工具';
    return _patchMeta(t, <String, String>{'title': name});
  }

  /// 改**标识名**（= 文件夹名 = `@tool:xxx` 里用的那个）。
  ///
  /// ## 为什么允许改，但要把代价说清楚
  ///
  /// 标识是引用的锚点：改完之后，**历史消息里 `@tool:旧名` 会失效**
  /// （引用解析找不到那个 id 就静默跳过）。所以界面上必须提示这一点，
  /// 而不是让它悄悄发生。
  ///
  /// 不自动改写历史消息：那要遍历所有会话并改文本，
  /// 一旦用户只是想换个名字，却把聊天气泡里的原文也改了，
  /// 那是更严重的越权。
  Future<String?> renameId(String oldId, String newId) async {
    final String target = newId.trim();
    if (target.isEmpty) return '标识不能为空';
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(target)) {
      return '标识只能用字母、数字、下划线、连字符（它会是文件夹名）';
    }
    if (target == oldId) return null;

    final FolderTool? t = byId(oldId);
    if (t == null) return '找不到这个工具';
    final Directory? root = _dir;
    if (root == null) return '工具目录还没就绪';

    final Directory dst = Directory('${root.path}/$target');
    if (dst.existsSync()) return '已经有叫「$target」的工具了';

    try {
      await Directory(t.folderPath).rename(dst.path);
    } catch (e) {
      return '重命名失败：$e';
    }

    // 顺手把 frontmatter 里的 `name` 也改掉 —— 它和文件夹名重复，
    // 但不改的话读出来会显示一个和文件夹不一致的旧名字。
    try {
      final File manifest = File('${dst.path}/$manifestName');
      final FrontMatter fm = FrontMatter.parse(await manifest.readAsString());
      final Map<String, String> meta = Map<String, String>.from(fm.meta);
      meta['name'] = target;
      await manifest.writeAsString(_rebuild(meta, fm.body));
    } catch (_) {
      // frontmatter 改不了不算失败：文件夹已经改好了，功能照常
    }

    await load();
    return null;
  }

  /// 往 frontmatter 里打补丁（只覆盖给定的键）。
  Future<String?> _patchMeta(FolderTool t, Map<String, String> patch) async {
    final File manifest = File('${t.folderPath}/$manifestName');
    try {
      final FrontMatter fm = FrontMatter.parse(await manifest.readAsString());
      final Map<String, String> meta = Map<String, String>.from(fm.meta);
      meta.addAll(patch);
      await manifest.writeAsString(_rebuild(meta, fm.body));
      await load();
      return null;
    } catch (e) {
      return '保存失败：$e';
    }
  }

  /// 读全文（给 `tool` 工具用）。
  ///
  /// 返回给模型看的文本：元信息 + 正文 + 附件清单（真实路径）。
  /// **附件只给路径不给内容** —— 内容可能很大，让模型自己决定读哪个。
  String readForModel(FolderTool t) {
    final StringBuffer sb = StringBuffer();
    sb.writeln('# 工具：${t.title}（${t.id}）');
    if (t.description.isNotEmpty) sb.writeln('说明：${t.description}');
    if (t.whenToUse.isNotEmpty) sb.writeln('适用场景：${t.whenToUse}');
    sb.writeln('版本：${t.version}');
    sb.writeln();
    sb.writeln(t.body.isEmpty ? '（这个工具还没有正文说明）' : t.body);
    if (t.files.isNotEmpty) {
      sb.writeln();
      sb.writeln('## 附件（可用 file_read / shell 直接访问）');
      for (final String f in t.files) {
        sb.writeln('- ${t.folderPath}/$f');
      }
    }
    return sb.toString();
  }

  // ------------------------------------------------------------ 文件级操作
  //
  // 这几个是**给"文件夹式"的界面和 agent 改工具**用的：
  // 工具是文件夹，所以要能列出里面的文件、读一个、写一个、新建、删掉。
  //
  // 全部走 `_resolveInside` 做路径校验 —— 见那里的说明。

  /// 把**工具内相对路径**解析成绝对路径，越界就抛。
  ///
  /// ## 为什么必须校验
  ///
  /// 这两条路都会把用户/模型给的字符串当路径用：
  ///  · 界面上"新建文件"让用户输入名字；
  ///  · agent 通过 `write` 动作写文件。
  ///
  /// 不挡 `../` 的话，一个 `write ../../notes.json` 就能改掉笔记库，
  /// 或者覆盖别的工具。这类破坏是不可逆的，所以在这里一律拒绝。
  File _resolveInside(FolderTool t, String raw) {
    final String cleaned = raw.trim().replaceAll('\\', '/');
    if (cleaned.isEmpty) {
      throw Exception('文件名不能为空');
    }
    if (cleaned.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(cleaned)) {
      throw Exception('只能用工具文件夹内的相对路径（例如 `tool.md`）');
    }
    final List<String> parts = <String>[];
    for (final String seg in cleaned.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        throw Exception('路径不能跳出工具文件夹');
      }
      parts.add(seg);
    }
    if (parts.isEmpty) throw Exception('文件名不能为空');
    return File('${t.folderPath}/${parts.join('/')}');
  }

  /// 工具文件夹里的全部文件（相对路径，`tool.md` 排最前）。
  ///
  /// `tool.md` 排最前是因为它是**主体** —— 界面上一眼该先看到它，
  /// 而不是按字母序被 `a.py` 挤到中间。
  List<String> filesOf(FolderTool t) {
    // 两个"主文件"排最前：tool.md 是做法，intro.md 是备注。
    // 其余按名字。用户打开工具时最该先看到这两个。
    final List<String> out = <String>[manifestName];
    if (t.intro.isNotEmpty) out.add(introName);
    final List<String> rest =
        t.files
            .where((String f) => f != manifestName && f != introName)
            .toList()
          ..sort();
    out.addAll(rest);
    return out;
  }

  /// 读一个文件。`tool.md` 返回**原始内容**（含 frontmatter），
  /// 因为界面上要编辑的就是原文 —— 去掉 frontmatter 再保存会把元信息弄丢。
  Future<String> readFile(FolderTool t, String rel) async {
    final File f = _resolveInside(t, rel);
    if (!f.existsSync()) throw Exception('文件不存在：$rel');
    return f.readAsString();
  }

  /// 写一个文件（不存在则创建，父目录自动建）。
  Future<void> writeFile(FolderTool t, String rel, String content) async {
    final File f = _resolveInside(t, rel);
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    // 写完要重扫：附件清单变了，`loadForModel` 里那份列表也得跟着变
    await load();
  }

  /// 新建一个空文件。已存在就报错（不静默覆盖）。
  Future<String?> createFile(FolderTool t, String rel) async {
    final File f = _resolveInside(t, rel);
    if (f.existsSync()) return '已经有这个文件了';
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString('');
      await load();
      return null;
    } catch (e) {
      return '创建失败：$e';
    }
  }

  /// 确保 `intro.md` 存在，返回它（给界面上"编辑备注"用）。
  ///
  /// ## 为什么懒创建
  ///
  /// 不是每个工具都需要备注。新建工具时**不**自动生成一个空 intro.md，
  /// 否则每个工具文件夹里都躺着一个空文件，看着像"没写完"。
  /// 等用户点了"编辑备注"才建 —— 那时他确实要写了。
  Future<File> ensureIntro(FolderTool t) async {
    final File f = File('${t.folderPath}/$introName');
    if (!f.existsSync()) {
      await f.writeAsString(_introTemplate(t.title));
      await load();
    }
    return f;
  }

  Future<String?> deleteFile(FolderTool t, String rel) async {
    // `tool.md` 不能删 —— 删了工具就消失了，而界面上那个"删除文件"
    // 按钮看起来只是删一个文件。想删整个工具请用删除工具。
    if (rel == manifestName) {
      return '不能删除 $manifestName。要删掉整个工具请用"删除工具"。';
    }
    final File f = _resolveInside(t, rel);
    if (!f.existsSync()) return '文件不存在';
    try {
      await f.delete();
      await load();
      return null;
    } catch (e) {
      return '删除失败：$e';
    }
  }

  /// 系统提示词里那段**索引**。
  ///
  /// 只放一句"叫什么、干什么、什么时候用"，不放正文 ——
  /// 正文由模型按需调 `load_tool` 取。这样工具再多也不会把提示词撑爆。
  String toPromptSection() {
    final List<FolderTool> list = enabled;
    if (list.isEmpty) return '';
    final StringBuffer sb = StringBuffer();
    sb.writeln('## 可用的工具（Tool，按需取用）');
    sb.writeln(
      '下面这些是**成套的做法**，不是一次就能调用的动作。'
      '觉得和当前任务相关时，先用 `load_tool` 读它的全文，再照着做。',
    );
    for (final FolderTool t in list) {
      sb.write('- `${t.id}`：${t.title}');
      if (t.description.isNotEmpty) sb.write(' —— ${t.description}');
      if (t.whenToUse.isNotEmpty) sb.write('（${t.whenToUse}）');
      sb.writeln();
    }
    return sb.toString();
  }

  static String _template(String name) =>
      '''---
name: $name
title: ${_humanize(name)}
description: 一句话说明这个工具能做什么
when_to_use: 什么情况下应该用它
version: 1
enabled: true
---

# ${_humanize(name)}

<!--
  这里写"怎么做"：步骤、命令、注意事项。
  模型会读到这整段，所以写成可执行的具体指令，不要写成宣传词。
-->

1. 先确认……
2. 然后执行……
3. 最后……

## 注意

- 容易出错的地方写在这里。
''';

  /// `intro.md` 的模板 —— **给人看的备注**。
  ///
  /// 和 `tool.md` 的内容刻意不重叠：那边写"怎么执行"，这里写"为什么"。
  static String _introTemplate(String title) => '''# $title · 备注

<!--
  这个文件是**给你自己看的**，模型不会读它。

  适合写：
  · 这个工具是怎么来的（谁提的需求、为什么需要）
  · 已知的坑、什么情况下会失败
  · 改动记录（哪天把哪一步换掉了，为什么）
  · 依赖了什么外部服务/账号

  要改"怎么做"，请编辑 tool.md。
-->
''';

  static String _humanize(String id) =>
      id.replaceAll(RegExp(r'[_-]+'), ' ').trim();

  static String _rebuild(Map<String, String> meta, String body) {
    final StringBuffer sb = StringBuffer('---\n');
    for (final MapEntry<String, String> e in meta.entries) {
      sb.writeln('${e.key}: ${e.value}');
    }
    sb.writeln('---\n');
    sb.write(body);
    return sb.toString();
  }

  /// 导出成 JSON（备份用）。
  String exportJson() =>
      const JsonEncoder.withIndent('  ')
          .convert(tools.map((FolderTool t) => t.toJson()).toList());
}
