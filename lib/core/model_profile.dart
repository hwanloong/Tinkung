import 'dart:convert';

import 'package:http/http.dart' as http;

import 'net_error.dart';

/// 生图工具的名字。
///
/// 定义为常量放这里（而不是从 `tools/image_gen_tool.dart` 引），是因为
/// **工具名要被"模型档案"引用**（档案上存"这个模型开了哪些工具"），
/// 而工具本身要引 `store.dart` 拿配置 —— 反向引会成环。
/// 名字是个稳定标识，单独放一处正合适。
const String kImageGenTool = 'generate_image';

/// 内置免费模型的通道。
///
/// 首选 OpenCode 的公开免密车道：它是目前少数能直接给出
/// DeepSeek V4.1 Flash 的免费入口。上游会按地区/客户端指纹限流，
/// 所以 [kFreeFallbackBaseUrl] 是同一档位里的兜底免费池。
const String kFreeDeepSeekBaseUrl = 'https://opencode.ai/inference/v1';
const String kFreeDeepSeekModel = 'deepseek-v4.1-flash-free';
const String kFreeFallbackBaseUrl = 'https://api.kilo.ai/api/gateway';
const String kFreeFallbackModel = 'kilo-auto/free';

/// 内置免费档能用的工具。
///
/// 用户的要求很具体：**联网搜索、Python、改模型、本地笔记/任务**，
/// 以及其它不碰 shell / Termux 的基础操作。白名单而不是黑名单，
/// 是因为免费通道的能力和额度都由上游决定，漏掉一个危险工具
/// 的代价比多拦一个基础工具大得多。
const List<String> kBasicToolAllowlist = <String>[
  'web',
  'python',
  'model_manager',
  'notes',
  'tasks',
  'mark',
  'memory',
  'recall',
  'rules',
  'learn',
  'knowledge',
  'interact',
  'change_think',
  'open_file',
  'get_location',
  'read_image',
];

// 这里原本有一份 `kOptionalTools`：能挂到模型档案上的"可选工具"表，
// 内容只有 `generate_image` / `generate_video` 两项。
//
// **它已经删掉了**，因为那两项根本不该由"模型档案"决定 ——
// 生图发的是**另一个模型**（设置里单独填的模型名，配上当前
// 档案的地址和密钥），对话模型是不是"能画图"和这件事毫无关系。
// 用这个开关去拦的后果很具体：中转站批量导入进来的档案，工具集是
// **显式的空数组**，于是用户平时聊天的那些模型一个都没有这两个工具 ——
// 说"画一张图"，模型回"我没有这个能力"，而设置里填好的生图模型名
// 一点用都没有。详见 `ModelProfile.tools`。

/// 「思考模式」参数用哪种形状。
///
/// `thinking` **不是 OpenAI 规范里的字段**，是各家自己加的 ——
/// 于是同一件事有好几种写法，而且服务端大多**严格校验** `type`，
/// 传错是直接 400 而不是忽略。
///
/// 所以做成模型档案上的一个选项，而不是在代码里按模型名猜：
/// 中转站里同一个模型名可能被套上任何后端，猜错的代价是一次请求失败。
enum ThinkingStyle {
  /// Anthropic 系（含 Anthropic 兼容的中转）：只认 `{"type":"adaptive"}`。
  ///
  /// **没有"关闭"这个取值** —— 想关只能整个字段不发。
  anthropic,

  /// DeepSeek 系：`{"type":"enabled"|"disabled"}` + `reasoning_effort`。
  deepseek,

  /// 其它 OpenAI 兼容服务（OpenAI 自己、Kimi、智谱、本地 Ollama…）：
  /// 它们不认识 `thinking`，发了可能被忽略也可能 400。
  openAiLike,

  /// 只发 `reasoning_effort`，不发 `thinking`。
  ///
  /// 免费网关（OpenCode / Kilo 这类）大多只透传 OpenAI 规范的
  /// `reasoning_effort`，而它们对 `thinking` 这个非标准字段的校验
  /// 比官方服务更严。内置免费模型用这一档，不会因为多带一个字段
  /// 把整轮请求打成 400。
  effortOnly,

  /// 完全不发 `thinking`。
  none,
}

extension ThinkingStyleX on ThinkingStyle {
  /// 存进 JSON 的名字。用稳定的字符串而不是 `index` ——
  /// 以后往中间插一项就会把老数据全指错。
  String get id => switch (this) {
    ThinkingStyle.anthropic => 'anthropic',
    ThinkingStyle.deepseek => 'deepseek',
    ThinkingStyle.openAiLike => 'openai',
    ThinkingStyle.effortOnly => 'effort',
    ThinkingStyle.none => 'none',
  };

  String get label => switch (this) {
    ThinkingStyle.anthropic => 'Anthropic',
    ThinkingStyle.deepseek => 'DeepSeek',
    ThinkingStyle.openAiLike => 'OpenAI 兼容',
    ThinkingStyle.effortOnly => '仅强度',
    ThinkingStyle.none => '不发送',
  };

  String get hint => switch (this) {
    ThinkingStyle.anthropic =>
      '只发 {"type":"adaptive"}。Anthropic 及其中转站严格只认这个值，'
          '发 enabled 会被拒绝。',
    ThinkingStyle.deepseek =>
      '发 enabled / disabled，开启时配套 reasoning_effort。'
          'DeepSeek 官方用这个。',
    ThinkingStyle.openAiLike =>
      '和其它 OpenAI 兼容服务一样发 enabled / disabled，'
          '不认识的会被忽略。',
    ThinkingStyle.effortOnly =>
      '只发 reasoning_effort，不发 thinking。'
          '适用于免费网关和不接受 thinking 字段的中转。',
    ThinkingStyle.none => '完全不发 thinking 字段。这一项造成 400 时选它最稳。',
  };

  static ThinkingStyle fromId(String? raw) {
    for (final ThinkingStyle s in ThinkingStyle.values) {
      if (s.id == raw) return s;
    }
    return ThinkingStyle.deepseek;
  }
}

/// 一个「已绑定的模型」。
///
/// 为什么是「档案」而不是「模型名」：一个模型要能真的用起来，至少需要
/// 三样东西 —— 地址、密钥、模型名。原来这三样各自在 [Settings] 里占一个
/// 字段，于是「绑多个模型」在结构上就不可能：存了新的地址就覆盖了旧的。
/// 把它们打包成一个对象之后，多模型只是"列表里多一项"。
///
/// 它同时是**任何 OpenAI 兼容服务**的档案，不限于 DeepSeek：
/// 只要对方提供 `/chat/completions`，填上地址和模型名就能用
/// （OpenAI、Kimi、智谱、本地 Ollama / vLLM 都是这个形状）。
class ModelProfile {
  ModelProfile({
    required this.id,
    required this.name,
    this.note = '',
    this.baseUrl = 'https://api.deepseek.com',
    this.apiKey = '',
    this.model = 'deepseek-flash',
    this.thinking = true,
    this.thinkingStyle = ThinkingStyle.deepseek,
    this.reasoningEffort = 'high',
    this.temperature = 0.7,
    this.vision = true,
    this.chat = true,
    this.tools,
    this.toolAllowlist,
    this.builtinFree = false,
    this.contextLimit = 0,
  });

  /// 稳定 id。切换/删除认的是它，不是 [name] ——
  /// 名字是给人看的，用户可以随时改，改了不该把"当前选的是哪个"弄丢。
  final String id;

  /// 展示名。为空时 UI 回退到 [model]。
  String name;

  /// **用户自己写的备注**。选模型列表里显示，用来区分"这个模型我是拿来
  /// 干什么的"。
  ///
  /// 为什么需要它：绑了十几个模型之后，列表里是一串
  /// `gpt-4o` / `gpt-4o-mini` / `deepseek-v3` / `qwq-32b` ——
  /// 名字能看出型号，看不出**用途**（哪个是拿来写代码的、哪个是便宜的、
  /// 哪个是备用中转站的）。备注就是这个用途说明。
  ///
  /// 和 [name] 的分工：`name` 是身份（列表里显示成主标题），
  /// 备注是补充（显示成下面一行灰字）。也可以只写备注、不写名字。
  String note;

  /// 接口地址，不含 `/chat/completions`
  String baseUrl;

  String apiKey;

  /// API 里的模型名（`deepseek-flash`、`gpt-4o-mini`、`llama3.1:8b`…）
  String model;

  /// 是否请求思考/推理模式。只对支持的模型有意义，不支持的会忽略这个字段。
  bool thinking;

  /// 「思考」参数用哪种形状 —— 各家不兼容，见 [ThinkingStyle]。
  ThinkingStyle thinkingStyle;

  /// 推理强度：low / high / max
  String reasoningEffort;

  double temperature;

  /// 是否具备图像理解能力。**由用户声明**，没有可靠的办法自动探测 ——
  /// 一个猜错的代价是发出去的图片被 API 报 400，不如让用户明确勾一下。
  bool vision;

  /// 是否能**生成**图片（文生图 / 图生图）。
  ///
  /// 和 [vision] 是两件不同的事，别混：
  ///  · [vision] = 看得懂图（多模态**输入**）
  ///  · 生图     = 画得出图（多模态**输出**）
  ///
  /// 这块能力现在由 [tools] 里的 `generate_image` 表达 ——
  /// 生图就是"这个模型能调用的一个工具"，不再是一套独立的配置。
  ///
  /// 同一个模型可以调用哪些**工具**。
  ///
  /// ## 为什么工具能力放在模型档案上
  ///
  /// 工具能不能用，取决于**这个后端支持什么** —— 而不是取决于某个全局开关：
  ///  · 一个只会对话的模型不能画图；
  ///  · 一个纯生图模型不能对话；
  ///  · 一个不支持 function calling 的模型调用任何工具都会报错。
  ///
  /// 所以"这个模型能用哪些工具"是**模型的一条属性**，和数据一起存。
  ///
  /// ⚠️ **但它现在不参与任何判断了**（`generate_image`
  /// 已经和它脱钩，见下面 [defaultTools] 的说明）。字段留着是为了
  /// 兼容存档，以及万一以后真出现"挂在这个档案上才成立"的工具。
  ///
  /// `null` = 用默认（[defaultTools]）。用 null 而不是空集合，
  /// 是为了区分"没配过"和"用户明确全关了" —— 前者要跟随默认变化，
  /// 后者要尊重用户的意图。
  List<String>? tools;

  /// 这个档案**实际允许调用**的工具白名单。
  ///
  /// `null` = 不限制（跟随注册表）；非 null = 只保留这些名字。
  /// 和 [tools] 的区别：[tools] 是历史字段，现在只描述"档案自己声明了
  /// 哪些可选能力"；[toolAllowlist] 是注册表在构建时的硬过滤，
  /// 免费档正是靠它把 shell / Termux 挡在外面。
  List<String>? toolAllowlist;

  /// 是否是**内置免费档**。
  ///
  /// 它决定两件事：
  ///  · 客户端给免费网关补上必要指纹头和兜底通道；
  ///  · 模型管理页显示「内置免费」标记，并且不允许直接删除 ——
  ///    删掉之后下一次冷启动又会回来，不如把这件事说清楚。
  bool builtinFree;

  /// 当前档案是否走内置免费通道。
  ///
  /// 只看地址：用户可以把内置档案改到自己的中转站，那时就不该再补
  /// OpenCode 的指纹头，也不该把请求偷偷切到 Kilo。
  bool get isFreeDeepSeek =>
      normalizedBaseUrl.contains('opencode.ai/inference');

  /// 这个档案是否只开放基础工具。
  bool get basicToolsOnly => toolAllowlist != null;

  /// 没配过工具时，新模型默认开哪些（见 [enabledTools]）。
  ///
  /// ⚠️ **这个工具如今不再是"档案上的可选能力"**：`generate_image`
  /// 走的是设置里单独填的模型名（配当前档案的地址和密钥），
  /// 任何档案都能调，注册时**不看**这里。
  ///
  /// 保留它作为默认值的原因有两个：老存档里 `null` 的语义是
  /// "跟随默认"，改了会让 `tools` 的取值含义悄悄变化；以及
  /// [modelGeneratesImages] 这条能力描述还在读它。
  static const List<String> defaultTools = <String>[kImageGenTool];

  /// 这个模型实际启用的工具集。
  List<String> get enabledTools => tools ?? defaultTools;

  bool hasTool(String name) => enabledTools.contains(name);

  void setTool(String name, bool on) {
    final List<String> next = List<String>.from(enabledTools);
    if (on) {
      if (!next.contains(name)) next.add(name);
    } else {
      next.remove(name);
    }
    tools = next;
  }

  /// 这个模型能不能**用来对话**。
  ///
  /// 默认 true。需要显式关掉的只有一类：**纯生图模型** ——
  /// `gpt-image-1` / `gpt-image-2` / `dall-e-3` / `stable-diffusion-*` 这些
  /// 只提供 `/images/generations`，**根本没有 chat 接口**。
  ///
  /// 拿它们发对话会得到服务端的一句
  /// `This model is not supported on chat completions endpoint` ——
  /// 而用户完全不知道自己做错了什么（他只是在输入框里发了句话）。
  /// 关掉这个开关之后：
  ///  · 输入框上方的模型选择器把它标成「仅生图」，并在选中时给出提示；
  ///  · 消息里那个错误也会被翻成人话（见 `DeepSeekClient._humanize`）。
  bool chat = true;

  /// 上下文窗口（token）。
  ///
  /// `0` = 用默认值（见 [Settings.contextLimit] 的注释）。
  ///
  /// 为什么要让用户填：从前这个值是按模型名猜的（"名字里有 flash/pro
  /// 就当 1M"）。有了多模型之后这条规则彻底不成立 ——
  /// 一个中转站里几十个模型的命名五花八门，猜出来的数可能差十倍。
  /// 猜大的后果是"上下文早就满了还在往里塞"，用户看到的是莫名其妙的
  /// 截断或 400，而且很难联想到是这里的问题。
  int contextLimit;

  /// UI 上显示的名字：没起名就用模型名，两者都空就给个占位。
  String get displayName {
    final String n = name.trim();
    if (n.isNotEmpty) return n;
    final String m = model.trim();
    return m.isEmpty ? '未命名模型' : m;
  }

  /// 去掉尾部斜杠的接口地址（拼 endpoint 时用）
  String get normalizedBaseUrl {
    final String b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return b.isEmpty ? 'https://api.deepseek.com' : b;
  }

  String get chatEndpoint => '$normalizedBaseUrl/chat/completions';

  /// 文生图接口。OpenAI 的规范路径，多数中转站也照这个实现。
  String get imageEndpoint => '$normalizedBaseUrl/images/generations';

  /// 模型列表接口。用于「批量导入中转站」——OpenAI 规范的 `/models`
  /// 返回 `{"data":[{"id":"gpt-4o"},…]}`，中转站基本都实现了它。
  String get modelsEndpoint => '$normalizedBaseUrl/models';

  /// 地址里露出的主机名，列表里用来区分"同一个模型名的两个来源"。
  String get host {
    final Uri? u = Uri.tryParse(normalizedBaseUrl);
    if (u == null || u.host.isEmpty) return normalizedBaseUrl;
    return u.host;
  }

  /// 是否填齐了能发请求的最小集合。
  bool get usable => apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  ModelProfile copyWith({
    String? name,
    String? note,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? thinking,
    ThinkingStyle? thinkingStyle,
    String? reasoningEffort,
    double? temperature,
    bool? vision,
    List<String>? tools,
    List<String>? toolAllowlist,
    bool clearToolAllowlist = false,
    bool? builtinFree,
    bool? chat,
    int? contextLimit,
  }) {
    return ModelProfile(
      id: id,
      name: name ?? this.name,
      note: note ?? this.note,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      thinking: thinking ?? this.thinking,
      thinkingStyle: thinkingStyle ?? this.thinkingStyle,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      temperature: temperature ?? this.temperature,
      vision: vision ?? this.vision,
      tools: tools ?? this.tools,
      toolAllowlist: clearToolAllowlist
          ? null
          : (toolAllowlist ?? this.toolAllowlist),
      builtinFree: builtinFree ?? this.builtinFree,
      chat: chat ?? this.chat,
      contextLimit: contextLimit ?? this.contextLimit,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'note': note,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
    'thinking': thinking,
    'thinkingStyle': thinkingStyle.id,
    'reasoningEffort': reasoningEffort,
    'temperature': temperature,
    'vision': vision,
    // null 也要写进去：它表示"跟随默认"，和"空列表"是两回事。
    'tools': tools,
    'toolAllowlist': toolAllowlist,
    'builtinFree': builtinFree,
    'chat': chat,
    'contextLimit': contextLimit,
  };

  static ModelProfile fromJson(Map<String, dynamic> j) => ModelProfile(
    id: j['id']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    note: j['note']?.toString() ?? '',
    baseUrl: j['baseUrl']?.toString() ?? 'https://api.deepseek.com',
    apiKey: j['apiKey']?.toString() ?? '',
    model: j['model']?.toString() ?? 'deepseek-flash',
    // 老数据没有这些字段时用"能用"的默认值，而不是 false ——
    // 一个刚刚迁移过来的档案直接变成"无思考、无视觉"会让人莫名其妙。
    thinking: j['thinking'] as bool? ?? true,
    // 老数据没有这个字段时按 DeepSeek 处理 —— 那是这个应用原本
    // 唯一的后端，升级上来的用户档案基本都是它。
    thinkingStyle: ThinkingStyleX.fromId(j['thinkingStyle']?.toString()),
    reasoningEffort: j['reasoningEffort']?.toString() ?? 'high',
    temperature: (j['temperature'] as num?)?.toDouble() ?? 0.7,
    vision: j['vision'] as bool? ?? true,
    // 工具集。老数据没有 `tools` 字段，但可能有更老的 `image: true` ——
    // 那个要迁成"开启 generate_image"，否则本来能画图的模型
    // 升级上来突然画不了了。
    tools: _decodeTools(j),
    toolAllowlist: _decodeToolAllowlist(j),
    builtinFree: j['builtinFree'] as bool? ?? false,
    // 对话能力默认 true：绝大多数模型都能对话，
    // 而且老数据里没有这个字段 —— 默认成 false 会让升级后
    // 所有已有模型都变成"仅生图"。
    chat: j['chat'] as bool? ?? true,
    contextLimit: (j['contextLimit'] as num?)?.toInt() ?? 0,
  );

  /// 解析存档里的工具集，并把更老的 `image` 字段迁过来。
  ///
  /// 四种输入：
  ///  · 有 `tools` 数组 → 用它（空数组也是有效值，表示"用户全关了"）；
  ///  · 有 `image: true` → `['generate_image']`；
  ///  · 有 `image: false` → `[]`。**这一条不能漏**：它是"用户明确关过"，
  ///    回退到默认会让升级后本来关着的生图又自己开了；
  ///  · 什么都没有 → `null`，表示"没配过，跟随默认"。
  static List<String>? _decodeTools(Map<String, dynamic> j) {
    final dynamic raw = j['tools'];
    if (raw is List) {
      return raw.map((dynamic e) => e.toString()).toList();
    }
    if (j['image'] == true) return <String>[kImageGenTool];
    if (j.containsKey('image')) return <String>[];
    return null;
  }

  static List<String>? _decodeToolAllowlist(Map<String, dynamic> j) {
    final dynamic raw = j['toolAllowlist'];
    if (raw is List) {
      return raw.map((dynamic e) => e.toString()).toList();
    }
    return null;
  }

  static List<ModelProfile> decodeList(String raw) {
    if (raw.trim().isEmpty) return <ModelProfile>[];
    try {
      final dynamic data = jsonDecode(raw);
      if (data is! List) return <ModelProfile>[];
      return data
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (Map<dynamic, dynamic> e) =>
                ModelProfile.fromJson(Map<String, dynamic>.from(e)),
          )
          .where((ModelProfile p) => p.id.isNotEmpty)
          .toList();
    } catch (_) {
      // 存档损坏时当作空的 —— 上层会重建一个默认档案，
      // 总比带着半截数据启动要好。
      return <ModelProfile>[];
    }
  }

  static String encodeList(List<ModelProfile> list) =>
      jsonEncode(list.map((ModelProfile p) => p.toJson()).toList());
}

/// 「中转站」批量导入：拿一个地址 + 一个 key，把对方支持的模型全列出来。
///
/// ## 什么是中转站
///
/// 就是转卖/代理 OpenAI 或各家模型 API 的服务，提供一个 **OpenAI 兼容**的
/// 地址（`https://xxx.com/v1`）。它通常支持几十甚至上百个模型名，
/// 手动一个一个绑太慢了 —— 而它们基本都实现了 OpenAI 规范的 `/models`，
/// 所以"自动拉列表"是可行的。
///
/// ## 为什么要容错到这种程度
///
/// 中转站的实现质量参差不齐，实测见过至少四种形状：
///  1. 标准：`{"data":[{"id":"gpt-4o"},…]}`
///  2. 只有数组：`[{"id":"gpt-4o"},…]`（少数自己写的网关）
///  3. 用 `model` 而不是 `id` 做字段名
///  4. 直接返回字符串数组：`["gpt-4o",…]`
///
/// 所以这里**不假设任何一种**，全都试一遍。宁可多写二十行解析，
/// 也不要让用户面对一句"返回格式不支持"。
class ModelImporter {
  const ModelImporter._();

  /// 拉取模型列表。
  ///
  /// [baseUrl] 可以带 `/v1`（推荐），也可以只写域名 —— 两者都会试：
  /// 很多中转站只认带 `/v1` 的路径，而用户从浏览器复制地址时经常漏掉它。
  static Future<ImportOutcome> fetchModels({
    required String baseUrl,
    required String apiKey,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (apiKey.trim().isEmpty) {
      return const ImportOutcome(error: '需要填 API Key 才能拉取模型列表');
    }

    final String base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      return const ImportOutcome(error: '需要填中转站地址，例如 https://xx.com/v1');
    }

    final Uri? parsed = Uri.tryParse(base);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return const ImportOutcome(error: '地址要写成完整网址，例如 https://xx.com/v1');
    }

    // 两种候选路径：原样 + 补 /v1（如果原样里还没有 v1）
    final List<String> candidates = <String>['$base/models'];
    if (!RegExp(r'/v\d+$').hasMatch(base)) {
      candidates.add('$base/v1/models');
    }

    final List<String> errors = <String>[];
    for (final String url in candidates) {
      try {
        final http.Response resp = await http
            .get(
              Uri.parse(url),
              headers: <String, String>{
                'Authorization': 'Bearer ${apiKey.trim()}',
                'Accept': 'application/json',
              },
            )
            .timeout(timeout);

        if (resp.statusCode != 200) {
          errors.add('$url → HTTP ${resp.statusCode}');
          continue;
        }

        final List<String> models = parseModelList(utf8.decode(resp.bodyBytes));
        if (models.isEmpty) {
          errors.add('$url → 返回里没有模型');
          continue;
        }
        return ImportOutcome(models: models, endpoint: url);
      } catch (e) {
        errors.add('$url → ${NetError.describe(e)}');
      }
    }

    return ImportOutcome(
      error:
          '拉取失败：\n${errors.join('\n')}\n\n'
          '检查地址是不是完整（多数中转站要带 /v1）、Key 是否正确。',
    );
  }

  /// 从返回体里解析出模型名列表。四种形状都认，见类注释。
  ///
  /// 抽成独立方法是为了能单独测 —— 解析错了会往用户列表里灌一堆垃圾条目。
  static List<String> parseModelList(String body) {
    dynamic data;
    try {
      data = jsonDecode(body);
    } catch (_) {
      return <String>[];
    }

    // 形状 2/4：顶层就是数组
    List<dynamic>? list;
    if (data is List) {
      list = data;
    } else if (data is Map) {
      for (final String key in <String>['data', 'models', 'result']) {
        final dynamic v = data[key];
        if (v is List) {
          list = v;
          break;
        }
      }
    }
    if (list == null) return <String>[];

    final Set<String> out = <String>{};
    for (final dynamic e in list) {
      if (e is String) {
        _add(out, e);
        continue;
      }
      if (e is! Map) continue;
      // 形状 1/3：对象里取 id，退而求其次取 model / name
      for (final String key in <String>['id', 'model', 'name']) {
        final dynamic v = e[key];
        if (v is String && v.trim().isNotEmpty) {
          _add(out, v);
          break;
        }
      }
    }

    final List<String> sorted = out.toList()..sort();
    return sorted;
  }

  static void _add(Set<String> out, String raw) {
    final String s = raw.trim();
    if (s.isEmpty || s.length > 120) return;

    // 过滤明显不是模型名的东西。中转站的返回里经常混进**错误信息和
    // 广告文案**（"余额不足，请联系客服充值"这种），它们没有空格、
    // 也不长，光靠长度和空格是拦不住的。
    //
    // 判据用"含汉字"：真实的模型名全是 ASCII（字母/数字/`-`/`_`/`.`/`:`/`/`）。
    // 有汉字的基本都是给人看的文案，不是模型标识符。
    // 宁可错杀一个奇怪的自定义模型名，也不要往用户的模型列表里灌广告。
    if (RegExp(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]').hasMatch(s)) {
      return;
    }
    // 带空格的同样不是标识符
    if (s.contains(RegExp(r'\s'))) return;

    out.add(s);
  }
}

/// 批量导入的结果。
class ImportOutcome {
  const ImportOutcome({
    this.models = const <String>[],
    this.endpoint,
    this.error,
  });

  final List<String> models;

  /// 实际成功的那个地址，导完之后显示给用户看 ——
  /// 它决定了新档案的 baseUrl 该写什么。
  final String? endpoint;

  final String? error;

  bool get ok => models.isNotEmpty;
}

/// 新建模型时的**建议清单**：一键填入常见服务的地址和模型名。
///
/// 只提供"地址 + 模型名"，**不含密钥** —— 密钥只能由用户自己填。
/// 有这份清单，绑一个新模型是"点一下再贴 key"，
/// 而不是"去查文档抄地址"。
class ModelPreset {
  const ModelPreset({
    required this.label,
    required this.baseUrl,
    required this.model,
    required this.note,
    this.vision = true,
    this.image = false,
    this.chat = true,
  });

  final String label;
  final String baseUrl;
  final String model;
  final String note;
  final bool vision;
  final bool image;

  /// 能不能用来对话。纯生图模型（`gpt-image-*` / `dall-e-*`）要为 false，
  /// 否则用户会拿它发消息然后撞上那句看不懂的服务端报错。
  final bool chat;

  static const List<ModelPreset> all = <ModelPreset>[
    ModelPreset(
      label: 'DeepSeek V4.1 Flash',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      note: '1M 上下文 · 支持图像理解',
    ),
    ModelPreset(
      label: 'DeepSeek V4 Pro',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-v4-pro',
      note: '推理更强 · 不支持图像',
      vision: false,
    ),
    ModelPreset(
      label: 'OpenAI GPT-4o mini',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
      note: '需要能直连 OpenAI',
    ),
    ModelPreset(
      label: 'Kimi (Moonshot)',
      baseUrl: 'https://api.moonshot.cn/v1',
      model: 'moonshot-v1-8k',
      note: '国内可直连',
    ),
    ModelPreset(
      label: '智谱 GLM-4 Flash',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4-flash',
      note: '国内可直连 · 有免费额度',
    ),
    ModelPreset(
      label: 'Ollama（本机）',
      baseUrl: 'http://127.0.0.1:11434/v1',
      model: 'llama3.1',
      note: '本地部署 · 密钥随便填一个非空值',
    ),
    ModelPreset(
      label: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'openai/gpt-4o-mini',
      note: '聚合站 · 一个 key 用几十家模型（国内需代理）',
    ),
    ModelPreset(
      label: '硅基流动 SiliconFlow',
      baseUrl: 'https://api.siliconflow.cn/v1',
      model: 'Qwen/Qwen2.5-7B-Instruct',
      note: '国内可直连 · 也有生图模型',
    ),
    ModelPreset(
      label: 'gpt-image-2（仅生图）',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-image-2',
      note: '只有 /images/generations，**不能对话**',
      vision: false,
      image: true,
      chat: false,
    ),
    ModelPreset(
      label: 'DeepSeek 生图（示例）',
      baseUrl: 'https://api.siliconflow.cn/v1',
      model: 'Kwai-Kolors/Kolors',
      note: '文生图 · 在编辑页勾上「支持生成图片」',
      vision: false,
      image: true,
      chat: false,
    ),
  ];
}

/// 中转站地址的**建议清单**。
///
/// 只填地址，不填 key（key 只能用户自己贴）。作用是把"去查文档抄地址"
/// 变成"点一下"—— 而中转站的地址正是最容易写错的一步（漏 `/v1` 是最常见的）。
///
/// 这份清单**不是白名单**：任何 OpenAI 兼容的地址都能用，
/// 它只是省掉几个高频项的输入。
class RelayPreset {
  const RelayPreset({
    required this.label,
    required this.baseUrl,
    this.note = '',
  });

  final String label;
  final String baseUrl;
  final String note;

  static const List<RelayPreset> all = <RelayPreset>[
    RelayPreset(
      label: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      note: '聚合站，模型最多',
    ),
    RelayPreset(
      label: '硅基流动',
      baseUrl: 'https://api.siliconflow.cn/v1',
      note: '国内直连，有免费额度',
    ),
    RelayPreset(label: 'DeepSeek 官方', baseUrl: 'https://api.deepseek.com'),
    RelayPreset(
      label: 'Kimi / Moonshot',
      baseUrl: 'https://api.moonshot.cn/v1',
    ),
    RelayPreset(
      label: '智谱开放平台',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    ),
    RelayPreset(
      label: 'Ollama（本机）',
      baseUrl: 'http://127.0.0.1:11434/v1',
      note: '本地部署',
    ),
  ];
}
