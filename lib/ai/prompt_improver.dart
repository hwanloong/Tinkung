import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../core/store.dart';

/// 「描述改进」：把用户随口说的一句话，改写成更适合发给模型的任务描述。
///
/// ## 它解决什么问题
///
/// 用户输入常常是"帮我看看那个文件"、"弄一下"、"这个东西怎么改" ——
/// 人能靠上下文猜，模型不能。于是它要么反问一轮（浪费一次往返），
/// 要么按自己的猜测乱做（更糟，还可能真的动了文件）。
///
/// 改写之后把指代补全、把意图说明确，模型一次就能做对。
///
/// ## 为什么是一次独立的模型调用，而不是让主模型自己"先想一想"
///
/// 主模型已经能看到整场对话，看起来它自己补全指代就够了。但实测不行：
/// **它会把"补全"和"执行"混在同一次输出里** —— 常常一边补全一边就开始
/// 调工具了，而那时它补全得并不完整。拆成两次调用，第二步拿到的是一段
/// **定稿的指令**，没有"一边想一边做"的余地。
///
/// 代价是多一次往返（通常一两秒）。所以它是个**开关**，
/// 默认关着，需要的人自己打开。
class PromptImprover {
  const PromptImprover._();

  /// 改写的系统提示词。
  ///
  /// 每一条约束都有理由，不是凑字数的：
  ///
  ///  · **不要回答、不要调工具** —— 这一步只是改写，不是执行。
  ///    不写死的话模型经常顺手把活干了，而那个"活"是拿半截信息做的。
  ///  · **不要新增用户没提的要求** —— 这是最容易被违背的一条：
  ///    模型会自作主张加上"顺便帮我检查一下…"。用户看到自己的话被
  ///    塞进了没要求的东西，会直接不信任这个功能。
  ///  · **拿不准就原样返回** —— 给模型一条"可以不改"的退路。
  ///    没有这条退路时，它会把本来就很清楚的话也硬改一遍，越改越糟。
  ///  · **保留语言** —— 中文输入必须中文输出，否则术语会漂。
  ///  · **只输出改写后的内容** —— 否则会带出"好的，这是改写后的版本："
  ///    这类前缀，而那会被当成提示词的一部分发出去。
  static const String systemPrompt = '''
你是一个"任务描述改写器"。用户会把一句话发给你，你把它改写成**更适合
交给 AI 助手执行**的任务描述。

改写规则：
1. **补全指代**：把"那个文件""这个东西""上面说的"这类指代，根据用户
   这句话本身能确定的范围写具体。**不要臆造**用户没提供的信息。
2. **说明意图**：把"弄一下""搞一下"改写成明确的动作（查看 / 修改 /
   删除 / 生成 / 解释）。只看用户这句话，不确定就保留原样。
3. **不要新增需求**：绝对不要添加用户没有提出的要求、限制或额外任务。
4. **不要回答、不要执行、不要调用工具**：你只做改写。
5. **保留原语言**：中文输入就输出中文；专业术语保持原样，不要翻译。
6. **拿不准就原样返回**：如果原话已经很明确，直接返回原话，
   不要为了改写而改写。
7. 只输出改写后的那一句话，**不要任何前缀、解释、引号或 markdown**。

现在改写下面这句话。''';

  /// 按**档位**和**用户自定义要求**拼出这次要用的系统提示词。
  ///
  /// 顺序：内置规则 → 档位要求 → 用户自定义。**自定义放最后**不是排版
  /// 问题：越靠后的指令对模型影响越大，而"用户本人写的要求"必须压过
  /// 我们替他定的规则 —— 他说"按 markdown 分点"，就该分点，
  /// 哪怕内置规则里写着"只输出一句话"。
  ///
  /// 三个档位改的是"改写器能动多少"，不是"开不开"：
  ///  · `low`   —— 最小改动，只把读不通的地方改到读得通；
  ///  · `medium` —— 默认，补指代 + 说明意图 + 去口语噪声；
  ///  · `high`  —— 允许重写成结构化的任务描述（目标 / 约束 / 产出）。
  @visibleForTesting
  static String promptFor(String level, String customInstruction) {
    final StringBuffer sb = StringBuffer(systemPrompt);
    sb.write('\n\n');

    switch (level) {
      case 'low':
        sb.write('''
改写力度：**最小改动**。
· 只在指代不清、动作含糊时动手，句子结构和用词尽量保持原样。
· 不许换说法、不许补背景、不许加限定条件 —— 你不是在润色，
  你是把一句读不通的话改到读得通。''');
      case 'high':
        sb.write('''
改写力度：**完整任务描述**。
· 允许把口语重写成一段结构清楚的任务说明，按需要分点写：
  目标 / 具体做什么 / 约束（不要动什么、放在哪）/ 期望产出。
· 缺的信息**留成明确的待确认项**（"文件名待确认"），不要自己编一个填上。
· 分点是为了让执行方看懂，不是为了写文档 —— 不要标题、不要客套话。''');
      default:
        sb.write('''
改写力度：**中等**（默认）。
· 补全指代、说明意图、去掉口语噪声（"帮我""麻烦"这类）。
· 保持一句话的形态，不要写成多段需求文档。''');
    }

    final String extra = customInstruction.trim();
    if (extra.isNotEmpty) {
      sb.write(
        '\n\n'
        '**用户本人对这个改写器的要求（优先级最高，与上面冲突时以它为准）：**\n'
        '$extra',
      );
    }

    return sb.toString();
  }

  /// 把 [raw] 改写成更清楚的提示词。
  ///
  /// 返回 null 表示**用原话就好** —— 调用方应当退回 [raw]。
  /// 以下情况都返回 null：
  ///  · 开关关着 / 没有可用模型；
  ///  · 原文太短（一两个字，没什么可补全的）；
  ///  · 请求失败或超时（**绝不能因为改写失败就发不出去消息**）；
  ///  · 改写结果明显不合理（过长、空、或只是把原话抄了一遍带解释）。
  static Future<String?> improve(
    String raw, {
    required Settings settings,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final String text = raw.trim();

    // 太短的不值得改写：两个字多半是"继续""好的"，本身没有歧义，
    // 而改写反而可能给它加戏。
    if (text.length < 4) return null;

    final String base = settings.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final String key = settings.apiKey.trim();
    // 改写用哪个模型：设置了就用它，否则跟着当前对话模型。
    // 地址和密钥一律沿用当前档案（见 `Settings.promptImproveModel`）。
    final String model = settings.promptImproveModel.trim().isEmpty
        ? settings.model.trim()
        : settings.promptImproveModel.trim();
    if (base.isEmpty || key.isEmpty || model.isEmpty) return null;

    final String sys = promptFor(
      settings.promptImproveLevel,
      settings.promptImproveInstruction,
    );
    // 高档次允许更长的产出：它本来就要写成结构化的任务描述。而
    // "超过原话 4 倍就当成它在解释"这条上限是按中等档位定的。
    final int slack = settings.promptImproveLevel == 'high' ? 800 : 80;

    final Uri uri;
    try {
      uri = Uri.parse('$base/chat/completions');
    } catch (_) {
      return null;
    }

    try {
      final http.Response resp = await http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(<String, dynamic>{
              'model': model,
              'messages': <Map<String, String>>[
                <String, String>{'role': 'system', 'content': sys},
                <String, String>{'role': 'user', 'content': text},
              ],
              // 温度调低：这一步要的是**稳定、可预料**的改写，
              // 不是创作。高了会开始自由发挥、加需求。
              'temperature': 0.2,
              // 改写结果不会比原话长太多，给个上限也能防它写小作文。
              'max_tokens': 800,
              // **不要思考链**：这一步要的是快（用户正等着消息发出去），
              // 而"补全指代"不需要推理深度。有些服务端不认这个字段，
              // 认不认都不影响主流程（下面解析只看 content）。
              'thinking': <String, String>{'type': 'disabled'},
            }),
          )
          .timeout(timeout);

      if (resp.statusCode != 200) {
        // 有些服务端不接受 `thinking` 字段，会 400。
        // 去掉它再试一次 —— 这个功能值得为兼容性多花一次请求。
        if (resp.statusCode == 400) {
          return await _retryWithoutThinking(
            uri,
            key,
            model,
            text,
            sys,
            timeout,
            slack,
          );
        }
        return null;
      }

      return _extract(resp.bodyBytes, text, slack);
    } catch (_) {
      // 超时/断网/解析失败 —— 一律当作"没改进"，用原话继续。
      // **不能因为改写失败就让用户发不出消息。**
      return null;
    }
  }

  static Future<String?> _retryWithoutThinking(
    Uri uri,
    String key,
    String model,
    String text,
    String system,
    Duration timeout,
    int slack,
  ) async {
    try {
      final http.Response resp = await http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(<String, dynamic>{
              'model': model,
              'messages': <Map<String, String>>[
                <String, String>{'role': 'system', 'content': system},
                <String, String>{'role': 'user', 'content': text},
              ],
              'temperature': 0.2,
              'max_tokens': 800,
            }),
          )
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      return _extract(resp.bodyBytes, text, slack);
    } catch (_) {
      return null;
    }
  }

  /// 从返回体里取改写结果，并做**合理性检查**。
  @visibleForTesting
  static String? extractImproved(
    String body,
    String original, {
    int slack = 80,
  }) {
    dynamic data;
    try {
      data = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (data is! Map) return null;
    final dynamic choices = data['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final dynamic first = choices.first;
    if (first is! Map) return null;
    final dynamic msg = first['message'];
    if (msg is! Map) return null;
    String? out = msg['content']?.toString();
    if (out == null) return null;

    out = out.trim();

    // 有些模型会坚持加前后缀或整体套上引号
    out = _stripDecoration(out);

    if (!isSane(out, original, slack: slack)) return null;
    return out;
  }

  static String? _extract(List<int> bodyBytes, String original, int slack) =>
      extractImproved(
        utf8.decode(bodyBytes, allowMalformed: true),
        original,
        slack: slack,
      );

  /// 去掉常见的包装：代码围栏、整段引号、"改写后："这类前缀。
  static String _stripDecoration(String s) {
    String out = s;

    // ```…``` 围栏
    final RegExp fence = RegExp(r'^```[a-zA-Z]*\s*\n([\s\S]*?)\n?```$');
    final RegExpMatch? fm = fence.firstMatch(out);
    if (fm != null) out = fm.group(1)!.trim();

    // 去掉只在**整段**外面的一对引号
    const List<List<String>> quotePairs = <List<String>>[
      <String>['"', '"'],
      <String>['“', '”'],
      <String>['「', '」'],
      <String>['『', '』'],
    ];
    for (final List<String> pair in quotePairs) {
      if (out.length > 1 && out.startsWith(pair[0]) && out.endsWith(pair[1])) {
        out = out.substring(pair[0].length, out.length - pair[1].length).trim();
      }
    }

    // "改写后：xxx" / "改进后的提示词：xxx"
    final RegExp prefix = RegExp(r'^(改写后|改进后|优化后|改写结果|改进结果)[：:]\s*');
    out = out.replaceFirst(prefix, '').trim();

    return out;
  }

  /// 改写结果是不是**能用**。
  ///
  /// 这一步很重要：模型偶尔会无视指令，输出一段解释
  /// （"这句话已经很清楚了，不需要改写。不过如果你想…"），
  /// 那种东西直接发出去，主模型会把它当成任务的一部分。
  @visibleForTesting
  static bool isSane(String improved, String original, {int slack = 80}) {
    final String a = improved.trim();
    if (a.isEmpty) return false;

    // 超长：改写不该是原话的 4 倍以上。出现这种情况基本是它开始解释了。
    // [slack] 是给高档位留的余量（它本来就要写成结构化的任务描述）。
    if (a.length > (original.trim().length * 4) + slack) return false;

    // 明确是在"讨论改写这件事"，而不是给出改写结果
    const List<String> meta = <String>[
      '不需要改写',
      '无需改写',
      '已经很明确',
      '已经很清楚',
      '作为改写',
      '改写后的版本是',
      '以下是改写',
      '我无法',
      '抱歉',
    ];
    for (final String m in meta) {
      if (a.contains(m)) return false;
    }

    // 完全照抄原话（去掉空白后一样）→ 等于没改进，没必要占一个字段
    if (a.replaceAll(RegExp(r'\s'), '') ==
        original.trim().replaceAll(RegExp(r'\s'), '')) {
      return false;
    }

    return true;
  }
}
