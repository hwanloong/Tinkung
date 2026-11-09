import 'dart:convert';
import 'dart:typed_data';

import '../core/folder_tool.dart';
import '../core/models.dart';
import 'tool.dart';

/// agent 对**文件夹工具（Tool）**的读写入口。
///
/// ## 为什么 Tool 不直接注册成一个个工具
///
/// 一套流程可能几十行说明、还带几个脚本。注册成工具意味着**每一轮**的
/// 工具列表都背着它 —— 工具越多，模型选错的概率越高，而绝大多数轮次
/// 根本用不到它。所以 Tool 是"按需取用"的：
///
///  · 系统提示词里只放一句索引（叫什么、干什么、什么时候用）；
///  · 模型觉得相关时，调这个工具的 `read` 读全文，再照着做。
///
/// ## 为什么读和写放在同一个工具里
///
/// 用户的原话是"ai 支持修改 tool"。也就是说它不只是读者，还是作者：
/// 用户说"把那个流程改一下，第二步换成……"，模型应该直接改文件，
/// 而不是让用户自己去界面里翻。
///
/// `read` 和 `write` 放在一起还有个实际好处：**改之前必须先读**。
/// 分成两个工具时模型容易凭记忆直接覆盖，把用户写的东西删了；
/// 同一个工具里，动作顺序在描述里写得下，也更容易提醒。
class FolderToolTool extends AgentTool {
  const FolderToolTool();

  @override
  String get name => 'tool';

  @override
  String get title => '工具';

  @override
  String get description =>
      '管理**文件夹工具（Tool）**——成套的做法，由 `tool.md` 和附属文件组成。\n'
      '和 rule（约束）、plugin（新动作）区分开：Tool 是"这件事该怎么做"的流程。\n'
      'action:\n'
      '· `list` —— 列出所有工具\n'
      '· `read` —— 读工具全文（含 `tool.md` 正文和附件路径）。'
      '**想用某个工具时先读它**\n'
      '· `read_file` —— 读工具文件夹里的某个文件（params: name, file）\n'
      '· `create` —— 新建工具（params: name）\n'
      '· `write` —— 写文件（params: name, file, content）。'
      '改 `tool.md` 就是改工具的说明/做法\n'
      '· `import_file` —— 导入一个**外来文件**（params: name, file, base64）。'
      '二进制/图片/脚本用它，`write` 只能写文本\n'
      '· `enable` / `disable` —— 开关\n'
      '· `rename` —— 改名（params: name, new_title?, new_id?）。'
      '`new_title` 只改显示名称，**没有副作用**；'
      '`new_id` 会改文件夹名，而它是 `@tool:xxx` 的锚点 —— '
      '改完历史消息里的旧引用会失效，所以改之前要跟用户确认\n'
      '· `delete` —— 删除整个工具（**不可撤销**）\n'
      '**改之前一定先 read**：`write` 是整文件覆盖，凭记忆写会把用户的内容删掉。\n'
      '文件路径只能是工具文件夹内的相对路径（`tool.md`、`scripts/a.sh`）。\n'
      '要给它写 Python/Shell 脚本时，用 `write`，'
      '`name=<工具 id>, file=scripts/run.py`。\n'
      '两个特殊文件：\n'
      '· `tool.md` —— **给模型看**的执行说明（你读它、改它）\n'
      '· `intro.md` —— **给用户看**的备注（由来、坑、改动记录）。'
      '平时不用读它；用户让你记一条备注时，write 到 `intro.md`\n'
      '如果工具文件夹里有 `tool.icon`（一张位图，png/jpg/webp/gif/bmp），'
      '它就是这个工具在界面上显示的图标。想给它配图标时用 `import_file` '
      '把图片存成 `tool.icon` 即可';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'list',
          'read',
          'read_file',
          'create',
          'write',
          'import_file',
          'enable',
          'disable',
          'rename',
          'delete',
        ],
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description': '工具 id（文件夹名）。省略且 action=list 时列出全部。',
      },
      'file': <String, dynamic>{
        'type': 'string',
        'description':
            'read_file / write / import_file 的文件相对路径，'
            '如 `tool.md`、`scripts/run.sh`',
      },
      'content': <String, dynamic>{
        'type': 'string',
        'description': 'write 要写入的完整文件内容',
      },
      'base64': <String, dynamic>{
        'type': 'string',
        'description':
            'import_file 用：文件内容的 base64（可带 '
            '`data:image/png;base64,` 前缀）。用于图片、二进制、'
            '需要保留原始换行的脚本',
      },
      'overwrite': <String, dynamic>{
        'type': 'boolean',
        'description':
            'import_file 用：目标文件已存在时是否覆盖（默认 false，'
            '会返回错误而不是替换）',
      },
      'new_title': <String, dynamic>{
        'type': 'string',
        'description': 'rename 用：新的显示名称（如「合并 PDF」）',
      },
      'new_id': <String, dynamic>{
        'type': 'string',
        'description':
            'rename 用：新的标识（文件夹名，即 @tool:xxx 里的 xxx）。'
            '会改变引用名，历史消息里的旧引用会失效。',
      },
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    return switch (args.str('action')) {
      // 写/删等于改 agent 自己的行为，让用户过一眼
      'write' || 'create' || 'delete' || 'import_file' => const RiskAssessment(
        RiskLevel.caution,
        <String>['会改变 agent 的工具（做法）'],
      ),
      _ => RiskAssessment.safe,
    };
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String a = args.str('action');
    final String n = args.str('name').trim();
    final String f = args.str('file').trim();
    return switch (a) {
      'list' => '列出工具',
      'read' => '读工具 $n',
      'read_file' => '读 $n/$f',
      'create' => '新建工具 $n',
      'write' => '写 $n/$f',
      'import_file' => '导入 $f → $n',
      _ => '$a $n',
    };
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final FolderToolStore store = FolderToolStore.instance;
    final String action = args.str('action').trim().toLowerCase();
    final String name = args.str('name').trim();

    switch (action) {
      case 'list':
        if (store.tools.isEmpty) {
          return '当前没有任何工具（Tool）。可以用 action=create 建一个。';
        }
        final StringBuffer sb = StringBuffer('共 ${store.tools.length} 个工具：\n');
        for (final FolderTool t in store.tools) {
          sb.writeln(
            '- ${t.id}（${t.title}）'
            '${t.enabled ? '' : ' · 已停用'}',
          );
          if (t.description.isNotEmpty) sb.writeln('  ${t.description}');
          if (t.files.isNotEmpty) {
            sb.writeln('  文件：${t.files.join(', ')}');
          }
        }
        return sb.toString();

      case 'read':
        final FolderTool? t = _find(store, name);
        if (t == null) return _notFound(store, name);
        return store.readForModel(t);

      case 'read_file':
        final FolderTool? t = _find(store, name);
        if (t == null) return _notFound(store, name);
        final String file = args.str('file').trim();
        if (file.isEmpty) return 'read_file 需要 file 参数';
        // 二进制文件不能当文本读：整段乱码会白占上下文，模型还可能
        // 据此"修"出更离谱的东西。直接告诉它改用什么动作。
        final ToolFileStat st = await store.statFile(t, file);
        if (!st.isText) {
          return '$file 是二进制/非文本文件（${FolderToolStore.humanSize(st.size)}），'
              '读出来只会是乱码，所以没读。'
              '要处理它就在 tool.md 里写清用哪个命令（shell）去跑；'
              '要替换它用 import_file。';
        }
        try {
          return clampOutput(await store.readFile(t, file), max: 8000);
        } catch (e) {
          return '读文件失败：$e';
        }

      case 'create':
        if (name.isEmpty) return 'create 需要 name（会作为文件夹名）';
        final String? err = await store.create(name);
        if (err != null) return 'create 失败：$err';
        return '已创建工具「$name」，里面有一个模板 `tool.md`。'
            '下一步用 action=write 写 `tool.md` 的内容。';

      case 'write':
        final FolderTool? t = _find(store, name);
        if (t == null) return _notFound(store, name);
        final String file = args.str('file').trim();
        if (file.isEmpty) return 'write 需要 file 参数（如 `tool.md`）';
        if (!args.containsKey('content')) {
          return 'write 需要 content 参数（完整文件内容）';
        }
        try {
          await store.writeFile(t, file, args.str('content'));
          return '已写入 ${t.id}/$file（${args.str('content').length} 字符）。';
        } catch (e) {
          return '写文件失败：$e';
        }

      case 'import_file':
        final FolderTool? t = _find(store, name);
        if (t == null) return _notFound(store, name);
        final String file = args.str('file').trim();
        if (file.isEmpty) {
          return 'import_file 需要 file 参数（工具文件夹内的目标路径，'
              '如 `scripts/run.sh` 或 `tool.icon`）';
        }
        final String rawB64 = args.str('base64').trim();
        if (rawB64.isEmpty) {
          return 'import_file 需要 base64 参数（文件内容的 base64）';
        }
        // 模型经常把 `data:image/png;base64,` 前缀一起贴进来。不剥掉的话
        // 解码会在第一个字符就失败，而报错写着"base64 不合法"—— 明明内容是对的。
        String b64 = rawB64;
        final int comma = b64.indexOf(',');
        if (b64.startsWith('data:') && comma > 0) {
          b64 = b64.substring(comma + 1);
        }
        // 换行/空格是 base64 的常见包装（邮件风格），解码前清掉
        b64 = b64.replaceAll(RegExp(r'\s'), '');
        final Uint8List bytes;
        try {
          bytes = base64Decode(b64);
        } catch (_) {
          return 'base64 解码失败：它必须是标准 base64（可以带 '
              '`data:...;base64,` 前缀，但不接受其它编码）';
        }

        final String? err = await store.importBytes(
          t,
          file,
          bytes,
          overwrite: args['overwrite'] == true,
        );
        if (err != null) return 'import_file 失败：$err';

        final String lower = file.toLowerCase();
        final bool asIcon =
            lower == FolderToolStore.iconName ||
            lower.startsWith('${FolderToolStore.iconName}.');
        return '已导入 ${t.id}/$file（${FolderToolStore.humanSize(bytes.length)}）。'
            '${asIcon ? '它现在就是这个工具在界面上的图标。' : ''}';

      case 'enable':
      case 'disable':
        final FolderTool? t = _find(store, name);
        if (t == null) return _notFound(store, name);
        final String? err = await store.setEnabled(t.id, action == 'enable');
        if (err != null) return '$action 失败：$err';
        return '已${action == 'enable' ? '启用' : '停用'}工具「${t.title}」。';

      case 'rename':
        final FolderTool? t = _find(store, name);
        if (t == null) return _notFound(store, name);

        final String newTitle = args.str('new_title').trim();
        final String newId = args.str('new_id').trim();
        if (newTitle.isEmpty && newId.isEmpty) {
          return 'rename 需要 new_title 或 new_id（至少给一个）';
        }

        final StringBuffer sb = StringBuffer();
        // 先改标识：它可能因为重名/非法字符失败，那时**不应该**已经改了标题
        if (newId.isNotEmpty && newId != t.id) {
          final String? err = await store.renameId(t.id, newId);
          if (err != null) return 'rename 失败：$err';
          sb.writeln(
            '标识已改为 `$newId`。'
            '⚠️ 历史消息里的 `@tool:${t.id}` 现在引用不到了 —— '
            '如果用户还需要那些引用，告诉他可以手动改回文本。',
          );
        }
        if (newTitle.isNotEmpty) {
          final String? err = await store.setTitle(
            newId.isNotEmpty ? newId : t.id,
            newTitle,
          );
          if (err != null) return 'rename 失败：$err';
          sb.writeln('显示名称已改为「$newTitle」。');
        }
        return sb.toString().trimRight();

      case 'delete':
        final FolderTool? t = _find(store, name);
        if (t == null) return _notFound(store, name);
        final String title = t.title;
        final String? err = await store.remove(t.id);
        if (err != null) return 'delete 失败：$err';
        return '已删除工具「$title」。';

      default:
        return '未知 action「$action」。可用：list / read / read_file / '
            'create / write / import_file / enable / disable / rename / delete';
    }
  }

  static FolderTool? _find(FolderToolStore store, String name) {
    if (name.isEmpty) return null;
    // 允许用标题匹配：用户和模型记的都是标题，不是文件夹名
    for (final FolderTool t in store.tools) {
      if (t.id == name || t.title == name) return t;
    }
    return null;
  }

  static String _notFound(FolderToolStore store, String name) {
    final List<String> ids = store.tools.map((FolderTool e) => e.id).toList();
    return '找不到工具「$name」。'
        '${ids.isEmpty ? '当前还没有任何工具。' : '现有：${ids.join('、')}'}';
  }
}
