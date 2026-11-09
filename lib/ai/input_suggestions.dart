import 'dart:convert';

import '../core/model_profile.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../tools/extra_tools.dart';
import '../tools/tool.dart';
import 'deepseek.dart';

/// 输入建议：图片解析 + 上下文揣测。
///
/// ## 为什么不是"替用户说话"
///
/// 建议只是**可点的气泡**：点了才填进输入框，发不发、怎么改仍然由用户决定。
/// 所以这里不做自动补全、不劫持发送键。
///
/// 两类建议各有来源：
///  · 图片：先把图交给识图工具真解析一遍，再给"这道题怎么写 / 这是什么"；
///  · 上下文：用最近几轮对话做一次**很短**的补全请求，返回 3 条候选。
class InputSuggestionService {
  const InputSuggestionService._();

  /// 图片建议。`desc` 解析失败也给基础建议 —— 有建议比空白好。
  static Future<List<String>> forImage({
    required ToolContext ctx,
    required Attachment image,
  }) async {
    String desc = '';
    try {
      desc = await const ImageTool().run(ctx, <String, dynamic>{
        'path': image.path,
        'question': '用一两句话说明这张图片里是什么；如果是题目，说明科目和题型。',
      });
    } catch (_) {
      // 识图失败不影响给建议
    }

    final List<String> out = <String>[
      if (desc.contains('题') || desc.contains('计算') || desc.contains('证明'))
        '这题怎么做？'
      else
        '这个是什么？',
      '提取图片里的文字',
      '翻译图片内容',
      '详细描述这张图',
    ];
    if (desc.contains('表格') || desc.contains('数据')) {
      out[2] = '把这张表整理成表格';
    }
    return out.take(4).toList();
  }

  /// 根据最近几轮对话，预测用户接下来可能输入什么。
  ///
  /// 失败一律返回空列表：建议是加分项，不能因为模型慢/报错就阻塞输入。
  static Future<List<String>> forContext({
    required Settings settings,
    required List<ChatMessage> messages,
    required int effort,
    String profileId = '',
  }) async {
    final ModelProfile? profile = _pickProfile(settings, profileId);
    if (profile == null || !profile.usable) return <String>[];

    final List<ChatMessage> recent = messages
        .where((ChatMessage m) => !m.hidden && m.content.trim().isNotEmpty)
        .toList();
    final int start = recent.length > 6 ? recent.length - 6 : 0;
    final String digest = recent
        .sublist(start)
        .map(
          (ChatMessage m) =>
              '${m.role == Role.user ? '用户' : 'AI'}：'
              '${m.content.length > 300 ? m.content.substring(0, 300) : m.content}',
        )
        .join('\n');

    final String prompt = digest.isEmpty ? '用户刚打开一个新对话，还没有内容。' : digest;

    final List<Map<String, dynamic>> msgs = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'system',
        'content':
            '你是输入预测器。根据对话，预测用户接下来最可能输入的 3 条短句。'
            '只返回 JSON 字符串数组（例如 ["...","...","..."]），不要解释；'
            '每条不超过 18 个汉字，必须是用户会说的话，不要写成回答。',
      },
      <String, dynamic>{'role': 'user', 'content': prompt},
    ];

    final String effortName = switch (effort) {
      1 => 'low',
      2 => 'high',
      3 => 'max',
      _ => profile.reasoningEffort,
    };
    final ModelProfile use = profile.copyWith(
      thinking: effort > 0,
      reasoningEffort: effortName,
      temperature: 0.4,
    );

    try {
      String content = await _run(
        settings,
        use,
        msgs,
      ).timeout(const Duration(seconds: 15));
      // 有些模型/中转不认 thinking 字段：去掉它再试一次，
      // 别让"输入建议"因为一个可选参数整块失效。
      if (content.trim().isEmpty && effort > 0) {
        content = await _run(
          settings,
          use.copyWith(thinking: false),
          msgs,
        ).timeout(const Duration(seconds: 15));
      }
      return _parseSuggestions(content);
    } catch (_) {
      return <String>[];
    }
  }

  static Future<String> _run(
    Settings settings,
    ModelProfile profile,
    List<Map<String, dynamic>> messages,
  ) async {
    final DeepSeekClient client = DeepSeekClient(settings, profile: profile);
    try {
      final AssistantTurn turn = await client.chat(
        messages: messages,
        tools: const <Map<String, dynamic>>[],
      );
      return turn.content;
    } finally {
      client.cancel();
    }
  }

  static ModelProfile? _pickProfile(Settings settings, String id) {
    if (id.trim().isEmpty) return settings.activeProfile;
    for (final ModelProfile p in settings.profiles) {
      if (p.id == id) return p;
    }
    return settings.activeProfile;
  }

  /// 容错解析：模型可能返回 ```json 围栏、前后带解释、或直接用换行分隔。
  static List<String> _parseSuggestions(String raw) {
    String text = raw.trim();
    if (text.isEmpty) return <String>[];
    // 去掉围栏
    text = text.replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '');
    text = text.replaceAll(RegExp(r'\s*```$'), '');

    final int lb = text.indexOf('[');
    final int rb = text.lastIndexOf(']');
    if (lb >= 0 && rb > lb) {
      try {
        final dynamic arr = jsonDecode(text.substring(lb, rb + 1));
        if (arr is List) {
          return _clean(arr.map((dynamic e) => e.toString()));
        }
      } catch (_) {
        // 落到按行拆
      }
    }
    return _clean(text.split(RegExp(r'[\n,，]')));
  }

  static List<String> _clean(Iterable<String> items) {
    final List<String> out = <String>[];
    for (String s in items) {
      // 去掉模型加的引号、序号、项目符号；保留中英文与数字。
      s = s
          .trim()
          .replaceAll(RegExp(r'^[^a-zA-Z0-9\u4e00-\u9fff]+'), '')
          .replaceAll(RegExp(r'[^a-zA-Z0-9\u4e00-\u9fff]+$'), '')
          .trim();
      if (s.isEmpty || s.length > 24) continue;
      if (out.contains(s)) continue;
      out.add(s);
      if (out.length >= 3) break;
    }
    return out;
  }
}
