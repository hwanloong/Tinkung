import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// **Agent.md**：用户对 AI 的**最高优先级**规范。
///
/// ## 为什么单独一个文件，而不是塞进「自定义规则」
///
/// 「自定义规则」是一条条「当…就…」的条件指令，适合表达**零散偏好**
/// （"回答简短点""说天气先查我的城市"）。而这里要放的是**整套工作规范**：
/// 编码风格、术语表、禁止事项、交付格式……它们是**长篇的、成体系的、
/// 需要反复编辑的**。
///
/// 塞进规则列表会变成几十条互相引用的一行文字，既难改也难读。
/// 单独一个 markdown 文件，编辑器就是普通的文本编辑器，用户能像写
/// 项目文档一样维护它 —— 而且**可以直接用别的工具改**（文件就在
/// 应用数据目录里）。
///
/// ## 优先级
///
/// 注入时放在系统提示词**最前面**，并明确标注"最高优先级"。
/// 和内置规范冲突时，用户写的赢 —— 这是用户唯一能**覆盖内置行为**
/// 的入口，不给它真正的优先级，它就只是个建议。
///
/// 但**安全底线不在此列**：危险操作确认、不可信输入清洗这些机制在
/// 代码里，不在提示词里，Agent.md 改不动它们（也不该指望它能改）。
class AgentDocStore extends ChangeNotifier {
  AgentDocStore._(this._file);

  static AgentDocStore? _instance;

  /// 没初始化时返回纯内存实例，而不是抛异常。
  ///
  /// 理由同 `ObjStore`：这条路径在系统提示词构建的深处，
  /// 抛异常会把整场对话打断，而"没落盘"只是重启后内容没了。
  static AgentDocStore get instance => _instance ??= AgentDocStore._(null);

  static Future<AgentDocStore> configure(
    File file, {
    String seedAsset = 'assets/agent_md_template.md',
  }) async {
    final AgentDocStore s = AgentDocStore._(file);
    _instance = s;
    await s.load();
    // ---- 第一次启动：把推荐模板写进去 ----
    //
    // 只在**文件为空/不存在**时做，所以：
    //  · 用户没动过 → 一装好就有一套适合本 App 的规范生效；
    //  · 用户改过（哪怕只留了一行）→ **绝不覆盖**，他的内容优先。
    //
    // 模板内容见 `assets/agent_md_template.md`。失败就保持空白，
    // 不影响启动（用户仍然可以在设置里手写）。
    if (s._text.trim().isEmpty) {
      try {
        final String seed = await rootBundle.loadString(seedAsset);
        if (seed.trim().isNotEmpty) {
          s._text = seed;
          await s.save();
          s.notifyListeners();
        }
      } catch (_) {
        // 资源缺失 / 读取失败：保持空白
      }
    }
    return s;
  }

  @visibleForTesting
  static void resetForTest() => _instance = null;

  final File? _file;

  String _text = '';

  /// 规范正文（markdown）。
  String get text => _text;

  bool get isEmpty => _text.trim().isEmpty;

  bool get enabled => _text.trim().isNotEmpty;

  /// 正文长度上限。
  ///
  /// 20000 字（约 40KB）：足够写一份很详细的项目规范，又不会让
  /// **每一轮**请求都多背上几万 token。超了就截断并说明 —— 悄悄截断
  /// 会让用户以为"我写的第 300 行没生效"，而实际是他自己没看到提示。
  static const int maxChars = 20000;

  Future<void> load() async {
    final File? f = _file;
    if (f == null) {
      notifyListeners();
      return;
    }
    try {
      _text = await f.exists() ? await f.readAsString() : '';
    } catch (_) {
      _text = '';
    }
    notifyListeners();
  }

  Future<void> save() async {
    final File? f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(_text);
    } catch (_) {
      // 写失败不致命
    }
  }

  /// 改正文。返回 null 表示成功，否则是给用户看的原因。
  String? setText(String value) {
    if (value.length > maxChars) {
      return '太长（${value.length} 字，上限 $maxChars）。'
          'Agent.md 每一轮都要带上，太长会挤占上下文。'
          '细节可以写进文件，让它按需用 `reader` 读。';
    }
    _text = value;
    notifyListeners();
    save();
    return null;
  }

  /// 注入系统提示词的那一段。
  ///
  /// 空内容返回空串：没写就不该插一段空标题（浪费 token 也干扰模型）。
  String toPromptSection() {
    final String body = _text.trim();
    if (body.isEmpty) return '';
    final bool over = body.length > maxChars;
    return '\n'
        '# 用户规范（Agent.md）—— **最高优先级**\n'
        '以下内容由用户本人编写，是他对这套 AI 工作方式的**硬性规范**。\n'
        '它与本提示词中的任何其它段落冲突时，**一律以这里为准**'
        '（唯一例外是安全机制：危险操作确认、不可信输入处理这些由程序执行，'
        '不受此文档影响）。\n'
        '不要复述、不要评论这份文档，把它当成你自己的准则直接执行。\n'
        '\n'
        '<<<AGENT_MD_BEGIN>>>\n'
        '$body\n'
        '<<<AGENT_MD_END>>>\n'
        '${over ? '\n（注意：本文档已超出 ${AgentDocStore.maxChars} 字建议上限，'
            '用户可能还没意识到它占用了大量上下文。）\n' : ''}';
  }
}
