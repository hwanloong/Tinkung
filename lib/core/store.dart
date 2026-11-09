import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ids.dart';
import 'model_profile.dart';
import 'models.dart';

/// 解析好的生图配置。
class ImageGenConfig {
  const ImageGenConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get usable => apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  /// **标准的** OpenAI 生图端点。
  ///
  /// 不提供别的形状：这是事实标准（OpenAI 自己的、以及几乎所有中转站
  /// 和聚合站都照它实现），多一套"自定义"只会让每个用户都要问一遍
  /// "我这家的该怎么填"。
  String get endpoint => '$baseUrl/images/generations';
}

/// 模型**列表条目**显示多少信息。
///
/// 用字符串 id 而不是枚举的 index 存进 prefs：往中间插一项时
/// 老数据不会被指到错误的档位上（和 ThinkingStyle 同一个理由）。
class ModelChipInfo {
  const ModelChipInfo._();

  /// 显示型号、站名、能力标记（默认）
  static const String detailed = 'detailed';

  /// **只显示名称 + 备注** —— 绑了很多模型时用这个，
  /// 否则每一行都被各种标记挤满、找不到想点的那条。
  static const String simple = 'simple';

  static const List<(String, String)> options = <(String, String)>[
    (detailed, '完整信息：型号 · 站名 · 能力标记'),
    (simple, '只看名称和备注：最简洁，适合绑了很多模型'),
  ];
}

/// 全局设置，用 SharedPreferences 持久化。
class Settings extends ChangeNotifier {
  Settings._(this._prefs);

  final SharedPreferences _prefs;

  static Future<Settings> load() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final Settings s = Settings._(p);
    s._read();
    return s;
  }

  // ------------------------------------------------------------ 已绑定的模型

  /// 用户绑定的全部模型（地址 + 密钥 + 模型名 + 该模型的参数）。
  ///
  /// **这是"支持绑定多个模型"的落点。** 原来地址/密钥/模型名各自是
  /// [Settings] 上的一个字段，存一个新的就覆盖旧的，多模型在结构上不可能；
  /// 打包成 [ModelProfile] 列表之后，多绑一个只是列表里多一项。
  final List<ModelProfile> profiles = <ModelProfile>[];

  /// 当前正在用的档案 id。`null` = 一个都没绑。
  String? activeProfileId;

  /// 当前档案。一个都没绑时为 null。
  ModelProfile? get activeProfile {
    for (final ModelProfile p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  /// 切到另一个已绑定的模型。返回是否真的切了。
  bool selectProfile(String id) {
    for (final ModelProfile p in profiles) {
      if (p.id != id) continue;
      if (activeProfileId == id) return false;
      activeProfileId = id;
      // 切到某个模型就意味着要用它 —— 它必须可见，
      // 否则会出现"使用中的模型不在切换列表里"的矛盾状态。
      hiddenProfileIds.remove(id);
      _syncModelBacking();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 在模型选择器里**被隐藏**的档案 id。
  ///
  /// ## 隐藏 ≠ 删除
  ///
  /// 隐藏只是"不要在切换列表里出现"，档案、密钥、备注全都保留，
  /// 随时可以在「模型」管理页恢复。绑了十几个中转站模型的人，
  /// 日常只用其中两三个 —— 每次都从一长串里找，是纯粹的浪费。
  ///
  /// **当前正在用的那个永远显示**（见 `_ModelPickerSheet`）：
  /// 否则用户看不到自己在用什么，也没法从列表里切回去。
  List<String> hiddenProfileIds = <String>[];

  bool isProfileHidden(String id) => hiddenProfileIds.contains(id);

  /// 隐藏 / 显示一个档案。传 [hidden] = false 就是恢复。
  void setProfileHidden(String id, bool hidden) {
    if (hidden) {
      if (!hiddenProfileIds.contains(id)) hiddenProfileIds.add(id);
      // 藏起当前在用的模型是没有意义的：它仍然会显示，也不该让
      // "隐藏"这个动作看起来生效了又没生效。
      if (activeProfileId == id) hiddenProfileIds.remove(id);
    } else {
      hiddenProfileIds.remove(id);
    }
    notifyListeners();
  }

  /// 新增一个档案并（默认）切过去。返回新档案。
  ModelProfile addProfile(ModelProfile p, {bool activate = true}) {
    profiles.add(p);
    if (activate || activeProfileId == null) {
      activeProfileId = p.id;
      _syncModelBacking();
    }
    notifyListeners();
    return p;
  }

  /// 就地改一个档案。找不到就什么都不做。
  ///
  /// 改的如果是**当前**档案，把兼容字段（apiKey/baseUrl/model）同步过去 ——
  /// [DeepSeekClient] 读的是它们，不同步的话"改了模型名但请求还发旧的"。
  void updateProfile(ModelProfile p) {
    final int i = profiles.indexWhere((ModelProfile e) => e.id == p.id);
    if (i < 0) return;
    profiles[i] = p;
    if (p.id == activeProfileId) _syncModelBacking();
    notifyListeners();
  }

  /// 删除一个档案。删掉的是当前档案时，自动切到列表里的第一个。
  void removeProfile(String id) {
    profiles.removeWhere((ModelProfile p) => p.id == id);
    if (activeProfileId == id) {
      activeProfileId = profiles.isEmpty ? null : profiles.first.id;
    }
    _syncModelBacking();
    notifyListeners();
  }

  /// 把列表里的第 [from] 项移到 [target]（**拖拽排序**）。
  ///
  /// ## 为什么用"列表顺序"而不是给每个档案加一个 `sortOrder` 字段
  ///
  /// 加字段要维护"插入时怎么编号、删除后要不要重排"，而它唯一的作用
  /// 就是决定显示顺序 —— 顺序本来就是列表的属性，存字段等于把一件事
  /// 记在两个地方，迟早不一致。
  ///
  /// 列表顺序直接进 JSON（`modelProfiles` 是个数组），所以拖完就持久化了。
  void moveProfile(int from, int target) {
    if (from < 0 || from >= profiles.length) return;
    if (target < 0) target = 0;
    if (target >= profiles.length) target = profiles.length - 1;
    if (target == from) return;

    final ModelProfile moved = profiles.removeAt(from);
    profiles.insert(target, moved);
    // 当前选中的是哪个**不受顺序影响**（认的是 id），所以不用动 activeProfileId。
    notifyListeners();
  }

  /// 当前档案是否就是这一个。
  bool isActive(String id) => activeProfileId == id;

  // ------------------------------------------------------------ 对话模型
  //
  // 下面三个字段是**兼容层**：`DeepSeekClient`、`AgentRunner` 等十几处
  // 读的都是 `settings.apiKey / baseUrl / model`。它们的真身现在是
  // 「当前档案」里的对应字段，这里用读写器转发 —— 这样"多模型"不需要
  // 改动每一个调用点，而那些调用点自动就跟着当前选中的模型走。
  //
  // 读：当前档案的值（没有档案时给一份能让人看懂提示的空值）
  // 写：写回当前档案，没有档案时就地建一个 —— 老用户升级上来时
  //     设置页那三个输入框仍然照常工作。

  String get apiKey => activeProfile?.apiKey ?? '';
  set apiKey(String v) => _writeActive((ModelProfile p) => p.apiKey = v);

  String get baseUrl => activeProfile?.baseUrl ?? 'https://api.deepseek.com';
  set baseUrl(String v) => _writeActive((ModelProfile p) => p.baseUrl = v);

  /// 当前模型名：
  ///  · deepseek-flash    —— V4.1-Flash，1M 上下文，**支持图像理解**
  ///  · deepseek-v4-pro   —— V4-Pro，不支持图像理解
  /// 旧名 deepseek-chat / deepseek-reasoner 已不在模型表中。
  String get model => activeProfile?.model ?? 'deepseek-flash';
  set model(String v) => _writeActive((ModelProfile p) => p.model = v);

  /// 往当前档案写一个字段（没有档案就先建一个默认的）。
  void _writeActive(void Function(ModelProfile p) mutate) {
    ModelProfile? p = activeProfile;
    if (p == null) {
      p = ModelProfile(id: newId(), name: 'DeepSeek');
      profiles.add(p);
      activeProfileId = p.id;
    }
    mutate(p);
  }

  /// 把当前档案的字段铺回 top-level 的 prefs key。
  ///
  /// 为什么不干脆删掉那几个 key：备份/恢复（core/backup.dart）和
  /// 老版本的读取路径都认它们。留着它们等于"多模型"对老代码透明。
  void _syncModelBacking() {
    final ModelProfile? p = activeProfile;
    _prefs.setString('apiKey', p?.apiKey ?? '');
    _prefs.setString('baseUrl', p?.baseUrl ?? 'https://api.deepseek.com');
    _prefs.setString('model', p?.model ?? 'deepseek-flash');
  }

  /// 是否开启思考模式。DeepSeek 默认开启。
  bool thinkingEnabled = true;

  /// 「思考」参数用哪种形状（Anthropic / DeepSeek / 通用 / 不发送）。
  ///
  /// 转发到当前模型档案 —— 它**必须跟着模型走**：同一个应用里
  /// 可能同时绑着 DeepSeek 和 Anthropic 两个后端，而它们对
  /// `thinking` 字段的要求互不兼容（一个要 `enabled`，一个只认 `adaptive`，
  /// 且都会**严格校验**，传错直接 400）。
  ThinkingStyle get thinkingStyle =>
      activeProfile?.thinkingStyle ?? ThinkingStyle.deepseek;
  set thinkingStyle(ThinkingStyle v) =>
      _writeActive((ModelProfile p) => p.thinkingStyle = v);

  /// 思考强度：low / high / max。
  /// 官方映射表：minimal、low → low；medium、high、xhigh → high；max、ultra → max。
  String reasoningEffort = 'high';

  double temperature = 0.7;

  /// 单轮工具调用次数的**天花板**（滑杆的最大值）。
  ///
  /// 和 [maxToolRounds] 的默认值同源：两处不一致时 `Slider` 会因为
  /// value 越界直接断言失败，整页崩掉 —— 而那种崩很难联想到是这里。
  static const int maxToolRoundsCeiling = 100;

  /// 单轮对话里最多允许多少次工具调用，防止模型陷入死循环。
  ///
  /// **默认给满 100。** 从前是 8，理由是"防止死循环"，但实测下来那个值
  /// 更容易造成另一种问题：复杂任务（多步搜索、写代码再跑再改）会在
  /// 做到一半时**被硬停住**，而模型不会说"我被限制了"，它只会含糊地
  /// 总结一下 —— 用户看到的是"它好像没做完"，却不知道为什么。
  ///
  /// 现在把上限交给用户（输入框上方 → 模型参数里可调），默认给满：
  /// 真正防死循环的是"模型能自己判断该停了"，而不是一个很小的上限。
  /// 想省 token 的人可以自己调小。
  ///
  /// **`0` = 不设限**。有用户明确要这个：复杂任务（批量处理几十个文件、
  /// 多轮搜索+验证）根本估不准要几轮，而"被硬停住"的代价比多花点 token
  /// 大得多 —— 模型不会说"我被限制了"，它只会含糊地总结一下。
  /// 真要停下来，用户手上有停止按钮，不需要一个猜出来的数字替他决定。
  int maxToolRounds = maxToolRoundsCeiling;

  /// **永久放行**：所有工具都不再弹确认框。
  ///
  /// 由确认框里的「全部运行」打开（见 `ConfirmDecision.allowAll`），
  /// 由输入框旁边那个感叹号暂停。**刻意做成显式状态**而不是
  /// "点过一次就记住某个工具"：后者会变成一份越积越长、用户看不见的
  /// 白名单，而这个开关永远只有一个，且随时能在眼前关掉。
  ///
  /// 打开时它**连危险命令一起放行** —— 那正是"全部运行"四个字的意思。
  /// 所以界面上要一直有那个感叹号（红色、可点），不能让它变成一个
  /// 用户忘了自己开过的开关。
  bool autoApproveAll = false;

  /// 可选模型清单已迁到 [ModelPreset.all]（core/model_profile.dart）——
  /// 那份清单带地址，能一键绑定一个完整的模型档案，
  /// 而这里原来的两行只有模型名。

  static const List<(String, String)> effortPresets = <(String, String)>[
    ('low', '低 · 快，适合简单操作'),
    ('high', '高 · 默认，平衡'),
    ('max', '最大 · 最慢最贵，适合复杂推理'),
  ];

  // ------------------------------------------------------------ 联网

  /// Tavily 搜索 key。留空时走 DuckDuckGo 兜底。
  String searchApiKey = '';

  /// 内置浏览器抓取搜索时用的搜索引擎。
  /// 走 WebView 而不是 HTTP 请求，所以不受反爬拦截影响。
  String searchEngine = 'bing';

  /// 联网搜索走哪条通道：
  ///  auto     —— 依次尝试 DeepSeek 服务端 → Tavily → 内置浏览器抓取
  ///  deepseek —— 只用 DeepSeek Responses API 的服务端 web_search
  ///  browser  —— 只用内置浏览器抓取
  String webSearchMode = 'auto';

  /// 自建搜索服务的地址（agent-web-search 这类）。
  ///
  /// 它是**独立部署的服务**（Docker + SearXNG），不在手机上跑，
  /// 所以这里只存一个 HTTP 地址。留空则跳过这一层。
  /// 价值在于它替我们做完了「抓取 → 正文提取 → 去噪 → 分块 → 向量化 →
  /// 相关度排序」整条链，拿回来就是能直接读的资料，还自带提示注入清洗。
  String selfHostedSearchUrl = '';

  /// 「+」面板里联网搜索用哪条通道：`bing-rss` / `duckduckgo`。
  ///
  /// 它只影响**用户主动搜**（把结果当附件发出去）这一条路；
  /// agent 自己调 `web` 工具时的通道由 [webSearchMode] 决定。
  ///
  /// 默认 Bing RSS：国内可达，而且 RSS 是结构化输出，
  /// 不会因为结果页改版就突然解析不出东西。DuckDuckGo 的结果质量
  /// 通常更好（尤其技术内容），但国内经常连不上 —— 所以它作为可选项，
  /// 而且失败会自动落到另一条（见 `WebSearchSource.searchWithFallback`）。
  String webSearchEngine = 'bing-rss';

  /// 搜索一次取几条结果。喂给模型的资料，太多会把上下文挤掉，
  /// 太少又不够回答。8 条是"够用且不撑"的折中。
  int webSearchLimit = 8;

  /// 联网方式。
  ///
  /// 自建搜索服务与 DeepSeek 服务端搜索已移除：
  /// · 自建服务要自己部署 Docker + SearXNG，门槛太高，而且跑在手机上
  ///   仍然受手机网络限制（墙的问题没解决，只是换了台机器）；
  /// · DeepSeek 的 `web_search` 已被官方关闭 —— 响应里不再出现
  ///   `web_search_call`，实测确认，官方文档也一直标着「忽略」。
  static const List<(String, String)> searchModePresets = <(String, String)>[
    ('auto', '自动：Tavily → Bing 直连 → 浏览器，依次尝试'),
    ('tavily', '只用 Tavily（需要 API Key）'),
    ('browser', '只用内置浏览器抓取'),
  ];

  // ------------------------------------------------------------ 生图

  /// **生图模型名**（走标准的 `/images/generations`）。
  ///
  /// ## 为什么只有一个字段
  ///
  /// 生图用的是**当前模型档案的地址和密钥**，只有模型名要单独填 ——
  /// 因为一个中转站常常"一条档案、多个模型"：地址和 Key 是同一个，
  /// 对话用 `gpt-4o`、画图用 `gpt-image-2`。
  ///
  /// 留空 = 不生图（`generate_image` 工具不注册给模型）。
  /// 之前这里有三项（选档案 / 模型名 / 尺寸）加一套独立设置页，
  /// 那是把"一条 OpenAI 通用接口"做成了一个子系统 ——
  /// 地址和密钥明明已经有了，没必要让用户再选一遍。
  ///
  /// 尺寸不在这里配：`gpt-image-*` 只认 1024x1024 / 1024x1536 / 1536x1024，
  /// 而 dall-e 又是另一套。写死会错，让用户填又会踩 400。
  /// **不发这个参数**由服务端按模型自己决定，是唯一不会错的选项。
  String imageGenModel = '';

  // ------------------------------------------------------------ 识图

  /// 视觉模型（OpenAI 兼容）。
  ///
  /// 地址/密钥留空时**复用主档案**（见 `ImageTool` 的候选解析）；
  /// 模型名默认 `deepseek-flash` —— 官方 key 本来就能调它。
  String visionBaseUrl = '';
  String visionApiKey = '';
  String visionModel = 'deepseek-flash';

  // ------------------------------------------------------------ 知识库（RAG）

  /// Embedding 模型名（OpenAI 兼容的 `/embeddings`）。
  ///
  /// **留空 = 不启用向量检索**：知识库仍然可用，但只做关键词/BM25 检索。
  /// 地址与密钥留空时复用当前模型档案（和识图同一个约定）。
  String embeddingModel = '';
  String embeddingBaseUrl = '';
  String embeddingApiKey = '';

  /// Rerank 模型名（POST `/rerank`，Jina / SiliconFlow / Cohere 兼容形状）。
  ///
  /// 留空 = 用本地的混合分（向量 + BM25）排序，不发额外请求。
  String rerankModel = '';
  String rerankBaseUrl = '';
  String rerankApiKey = '';

  /// 检索默认送进上下文的片段数（Top-N）。
  int ragTopK = 6;

  // ------------------------------------------------------------ 输入建议

  /// 是否在输入框上方给"接下来可能想说什么"的建议。
  ///
  /// 默认关：它要多一次模型往返（虽然很短），而且有人会觉得被剧透。
  bool inputSuggestEnabled = false;

  /// 输入建议用哪个档案；空 = 跟随当前聊天模型。
  String inputSuggestProfileId = '';

  /// 输入建议的思考强度：0=关闭，1=低，2=高，3=最高。
  int inputSuggestEffort = 1;

  // ------------------------------------------------------------ 描述改进

  /// **「描述改进」开关**：发消息前先让模型把用户原话改写成更清楚的
  /// 任务描述，再把改写结果交给 agent 执行。
  ///
  /// **默认关**。理由是它会：
  ///  · 让每次发送**多一次往返**（通常一两秒）；
  ///  · 改变用户输入的原意（规则里禁止加需求，但改写本身就是改写）。
  ///
  /// 所以这是"用户主动要"才开的东西，不替所有人做主 ——
  /// 这个应用的另一半价值就在"我说什么它做什么"。
  bool improvePrompt = false;

  /// **描述改进的力度**：`low` / `medium` / `high`。
  ///
  /// 三个档位改的是"改写器能改多少"，不是"开不开"：
  ///  · `low`   —— 只补指代、只把含混的动作词说明白，句子结构尽量别动；
  ///  · `medium` —— 默认。补全指代 + 说明意图 + 去掉口语噪声；
  ///  · `high`  —— 允许重写成一条**结构化的任务描述**（目标、约束、
  ///    产出物、验收标准）。适合"我懒得写需求，你先帮我理清楚"。
  ///
  /// 档位越高越可能改变用户的原意，所以默认 medium，而不是 high。
  String promptImproveLevel = 'medium';

  /// 用**哪个模型**做描述改进。留空 = 用当前对话模型。
  ///
  /// 为什么值得单独填：改写是个"短、快、要稳"的活。用便宜的小模型
  /// 完全够（它只补指代，不做推理），而拿一个贵模型去改写纯属浪费；
  /// 反过来，如果当前模型不支持 `thinking` 字段或响应很慢，
  /// 换一个专门做这件事的模型也能把等待时间压下来。
  ///
  /// 地址和密钥沿用当前档案（一个中转站常常一条档案、多个模型）。
  String promptImproveModel = '';

  /// **自定义改进要求**：追加给改写器的额外指令，留空 = 只用内置规则。
  ///
  /// 例："把所有代词替换成具体名字"、"按 Markdown 分点输出"、
  /// "我说话很省略，帮我补成完整句子"。这一条**优先级最高** ——
  /// 用户自己写了要求，就按他的来，内置规则让位。
  String promptImproveInstruction = '';

  // ------------------------------------------------------------ 行为

  /// 只读命令是否自动执行（关闭后所有命令都要确认）
  bool autoApproveSafe = true;

  /// 是否优先用系统悬浮窗做确认。
  /// 工具常常把别的应用切到前台，此时应用内弹窗会被盖住，
  /// 悬浮窗则始终在最上层。需要 SYSTEM_ALERT_WINDOW 权限。
  bool useOverlayConfirm = true;

  /// 是否启用「记忆」：把关于用户的长期事实注入系统提示词。
  ///
  /// 关掉之后**只是不再注入**，记忆条目本身仍然留着 ——
  /// 用户想"暂时别带上这些"和"把记下来的删掉"是两件事，
  /// 混成一个开关会让人不敢碰它。
  bool memoryEnabled = true;

  /// 是否启用「跨聊天记忆」：把**其他对话**的索引注入提示词，并允许
  /// 模型用 `recall` 工具按需检索。
  ///
  /// 和 [memoryEnabled] 分开：长期记忆是一句句事实（用户主动/模型判断
  /// 值得记的），跨聊天记忆是**整个历史**的只读视图 —— 有人希望模型
  /// 记住"我住上海"，但不希望它去翻三个月前的闲聊。两件事，两个开关。
  ///
  /// 关掉之后：不注入索引、`recall` 也不注册（模型看不到这个能力），
  /// 但对话本身当然不会被删除。
  bool crossChatMemory = true;

  /// 是否启用「自学习」：把 agent 自己写下的操作经验注入系统提示词。
  ///
  /// 和记忆同一个取舍：关掉只是**不再注入**，笔记本身还留着，
  /// 用户可以在设置里逐条删除。**用户不能添加** —— 这是 agent 的复盘，
  /// 不是第二个规则列表。
  bool learningEnabled = true;

  /// **工具步骤过程**是否收进一个可折叠的块里。
  ///
  /// ## 两种模式的取舍
  ///
  /// · `true`（默认，= 折叠）：一轮里调了十几个工具时，聊天流会被
  ///   一大片工具行淹没，正文被推到看不见。折叠成「执行了 12 步 ▸」
  ///   之后正文始终在视线里，想看细节点一下。
  /// · `false`（= 平铺）：每一步都直接占一行。**调试时有用** ——
  ///   能一眼扫完整个调用链，不用反复展开；但正常聊天时太吵。
  ///
  /// 放在「性能」里而不是「界面」里：它影响的是**信息密度**，
  /// 和字号、圆角那类纯外观选项不是一回事。
  bool collapseToolSteps = true;

  /// **上下文压缩的时机**。三档：
  ///
  ///  · `every`（默认）—— **每一轮都压**：较早轮次的工具输出在发请求前
  ///    压成摘要。这是原来的行为；
  ///  · `ratio` —— **用量到 80% 才压**：前面的轮次全部原样发送，
  ///    等最近一次请求的输入超过上下文上限的 80%，从下一轮开始压缩。
  ///    上下文宽裕时模型能看到完整原文，撞上限之前照样会自动收紧；
  ///  · `off` —— 不压，原样发送（需要模型精确回看某段工具原文时用）。
  ///
  /// ## 为什么要有 `ratio` 这一档
  ///
  /// `every` 的问题是**代价恒定**：哪怕这一轮只有三千 token，早先那几步
  /// 工具输出也会被削掉 —— 模型在核对一个上午前的输出时，看到的已经是
  /// 摘要。而多数会话离上限很远，那笔削价纯属白付。
  ///
  /// `ratio` 把那笔代价挪到真正需要它的时候：宽裕时给全文，吃紧时再压。
  ///
  /// 压缩本身是**有损**的，所以 `off` 必须留着 —— 用户核对输出、
  /// 复现报错时需要完整性，那比省 token 重要。
  String compressMode = 'every';

  /// 是否启用压缩（`off` 以外都算启用）。给老调用点用的派生值。
  bool get compressContext => compressMode != 'off';

  /// 两档压缩模式给界面用的中文名。
  static String compressModeLabel(String id) => switch (id) {
    'ratio' => '用量到 80% 才压缩',
    'off' => '不压缩',
    _ => '每轮压缩',
  };

  /// 压缩的**强度**：保留最近几轮的完整工具输出。
  ///
  /// 数值越大越保守（越不压）。3 轮够覆盖"刚才那一步在干什么"，
  /// 再往前的内容模型已经消化成结论了。
  int compressKeepTurns = 3;

  /// **极简过程模式**：思考和工具调用合并成一行状态，
  /// 只写「正在思考…」或「正在调用工具…」，**点不开、看不到细节**。
  ///
  /// 和 [collapseToolSteps] 是两档不同的东西：
  ///  · 折叠：一行摘要，**点得开**，细节还在（默认档）；
  ///  · 极简：一行状态，**没有可展开的内容**，结束后连这一行都不留。
  ///
  /// 给谁用：把手机当"问答机"用的人 —— 他只要结果，过程对他来说
  /// 是一屏在动的字。这不是"省空间"，是**把过程从界面上整个拿掉**，
  /// 所以它必须有独立开关，而不是折叠的第三档。
  bool minimalProgress = false;

  /// **开发者选项的总开关**。
  ///
  /// 默认关。打开之后，设置里会出现一整段排障工具（工具耗时、逐轮明细、
  /// 导出 log 等）。这些工具对普通用户是噪音 —— 他们要的是"AI 怎么更好用"，
  /// 不是"第 4 轮工具调用了 1832 毫秒"。但对反馈问题的人，它们是**唯一**
  /// 能说清"慢在哪一步"的东西，所以必须存在，只是藏起来。
  ///
  /// 为什么不做隐藏手势（连点版本号七次那种）：那种设计用户永远找不到，
  /// 而需要它的人恰恰是"已经遇到问题、正在到处找"的人。给一个明确的
  /// 开关，位置就在「设置 → 高级」里，说明写清楚。
  bool developerMode = false;

  /// 开发者选项里：性能面板是否列出**每一轮**的模型思考耗时。
  ///
  /// 不分档位直接常开会让面板在长对话里变成几百行；而"看总体有多快"
  /// 和"第 12 轮为什么慢"是两个问题。默认只显示汇总，要看逐轮才开。
  bool showPerTurnTimings = false;

  /// 自定义主题（主题包）下**显示应用原生的顶栏按钮**（返回 / 更多）。
  ///
  /// 默认 `true` = 现状：两颗圆浮在主题页面之上。
  ///
  /// 关掉的场景：主题自己画了顶栏。这时原生两颗圆会**压在自己的按钮上**，
  /// 两边都点不准 —— 关掉之后，主题里的按钮调 `window.App.back()` /
  /// `window.App.more()` 把动作接回来（见 `kBridgeDoc`），
  /// 背后的逻辑仍然是原生的那一套（根页面返回 = 开侧栏、更多 = 模型/
  /// 工具/权限面板），只是画在哪由主题决定。
  bool themePackNativeHeader = true;

  /// 电脑上 `pc_agent.exe` 的地址（含 token），由 `pc` 工具的 `connect` 写入。
  ///
  /// 存成**一整条 URL** 而不是拆成 host/port/token 三个字段：
  ///  · 用户是从 exe 窗口里整条复制的，拆开等于让他手工拆一遍；
  ///  · 三个字段任何一个丢了都会报 401 / 连不上，而"少填一个"
  ///    比"整条粘错"更难查。
  ///
  /// 空字符串 = 还没连过。
  String pcUrl = '';

  /// 工作空间目录。空字符串 = 用默认目录。
  ///
  /// **所有工作的中间产物都落在这里**：截图、录屏、附件、插件脚本。
  /// 之所以让用户可选，是因为默认目录在
  /// `/sdcard/Android/data/<包名>/files/dsh` —— 那个位置在文件管理器里
  /// 常常是隐藏的，想自己翻一下截图都找不到。换到「下载」这种可见目录
  /// 就能直接看。
  ///
  /// 注意它**不是**应用内部数据目录：会话、笔记、设置仍然在应用私有目录里，
  /// 不受这里影响。把应用数据也搬到用户可写目录，等于把数据放在谁都
  /// 能改的地方。
  String workspacePath = '';

  // ---------------------------------------------------------------- TeenSpace
  //
  // 内容尺度的三档敏感度。0 = 宽松，1 = 标准，2 = 严格。
  //
  // 这三项**不是**过滤器 —— 应用没法可靠地在本地判断什么算"政治议题"
  // （那需要语义理解，本地没有模型）。它们的真实作用是**写进系统提示词**，
  // 让模型自己按这个尺度回答。所以措辞上给的是"指导"，不是"拦截"。
  //
  // 诚实地说清这一点很重要：把它做成一个看起来像"内容过滤开关"的东西，
  // 用户会以为打开就万无一失，那是假的。

  /// 成人 / R 级内容
  int teenAdult = 1;

  /// 政治议题
  int teenPolitics = 1;

  /// 题目查询（作业、考试题）
  int teenQuery = 1;

  /// 字体已经**不可切换**：界面固定用 San Francisco Display，
  /// 中文由系统字体兜底（见 [AppFonts]）。
  ///
  /// 从前这里有 `fontScheme`（6 套方案）和 `customFontPath`（用户自选 .ttf）。
  /// 两者一起删掉了：字体是产品决定，不是设置项。留着 key 只为让老版本的
  /// 备份文件仍能导入（多出来的字段被忽略）。

  /// 字号额外放大倍数（1.0 ~ 1.4）。
  /// 主题的基础倍率是 1.0（见 AppFonts.baseScale），最终倍率 = 1.0 × 这个值。
  double fontScale = 1.0;

  /// **使用模式**：决定 agent 的工作方式（见 `buildSystemPrompt` 的模式段）。
  ///
  /// · `student`  —— 学生：偏好图、步骤、大白话，先解释再动手；
  /// · `daily`    —— 日常：简洁直接，能一句话说清就不多说；
  /// · `developer` —— 程序员：代码优先、路径精确、可以一次做多步。
  ///
  /// 空串 = 还没选过（首次启动会弹选一次）。默认给 `daily`，
  /// 这样万一选择页被跳过，行为也是中性的那种。
  String assistantMode = 'daily';

  /// 横屏时在 [fontScale] 之上再乘的倍率。
  ///
  /// 横屏的可用高度只有竖屏的一半，同一套字号会让聊天和工具表都很挤；
  /// 单独给横屏一个倍率，用户不必为了横屏把竖屏也一起缩小。
  double landscapeFontScale = 1.0;

  /// **用户自选的字体文件路径**（`.ttf` / `.otf` / `.ttc`）。留空 = 用内置的。
  ///
  /// ## 为什么是路径而不是把字体打进 APK
  ///
  /// 见 `core/custom_font.dart`：字体文件进仓库就是**再分发**（苹方这类是
  /// 苹果的东西），而且 Flutter 不支持"可选字体资源"——声明了找不到文件
  /// 就是构建错误，等于让每个克隆仓库的人自己准备一份。
  ///
  /// 所以：运行时从文件加载，路径存在这里。代价是**换设备要重新选一次**；
  /// 同一台设备上升级应用不会丢。
  String customFontPath = '';

  /// **抓网页时用桌面版 UA**（默认移动版）。
  ///
  /// 一部分站点给手机端发的是精简页（正文被砍，"展开全文"才出），
  /// 给桌面端的才是完整内容。抓资料时经常是桌面版更好用，
  /// 但"我要哪个版本"是用户的意图，不该替他猜 —— 所以是一个开关。
  bool desktopUa = false;

  /// **主题色**（M3 种子色）的 ARGB 值。0 = 用默认灰。
  ///
  /// 存 int 而不是 Color：SharedPreferences 存不了对象，
  /// 而 int 是最省事的无损表示（Color.toARGB32()）。
  ///
  /// **必须走种子色**，不能只改强调色 —— M3 的整套表面色
  /// （页面底、卡片、代码块）都是由种子推出来的，
  /// 只把 primary 换个颜色会得到"底色还是灰的、只有按钮变色"的
  /// 半套主题，比不换更难看。见 `AppColors.seed` 的注释。
  int themeSeed = 0;

  /// **模型列表里每个条目显示多少信息**。
  ///
  /// ## 它管的是列表，不是输入框那颗胶囊
  ///
  /// 胶囊上永远显示"名字 + 思考深度" —— 那是**当下的状态**，
  /// 任何时候都要看得见，不该由设置决定。
  ///
  /// 列表条目则相反，两种需求都真实存在：
  ///  · 只绑了两三个模型 → 想一眼看到型号、站名、能力标记
  ///    （"这个能不能看图"、"走的是哪家"）；
  ///  · 绑了十几个 → 每行都挂着 `站名 · 支持图像 · Deep`
  ///    会变成一片噪声，反而找不到想点的那一行。
  ///
  /// 所以交给用户选。默认 [ModelChipInfo.detailed]（大多数人是前者）。
  String modelChipInfo = ModelChipInfo.detailed;

  void _read() {
    // ---- 多模型档案 ----
    //
    // 顺序很要紧：先读档案列表，再读下面那些字段。老版本（只有单个
    // apiKey/baseUrl/model）升级上来时列表是空的，靠 _migrateLegacyProfile()
    // 从旧的三个 key 造出第一个档案 —— 用户不会因为升级而丢掉密钥。
    profiles
      ..clear()
      ..addAll(
        ModelProfile.decodeList(_prefs.getString('modelProfiles') ?? ''),
      );
    activeProfileId = _prefs.getString('activeProfileId');
    if (profiles.isEmpty) _migrateLegacyProfile();
    // 新用户（以及清空过模型列表的人）不应该是"没有模型"的空状态：
    // 内置免费档开箱即用，至少能聊天、搜索、记笔记。
    if (profiles.isEmpty) _addBuiltinFreeProfile();

    // ---- 迁移：解除内置免费档的工具白名单 ----
    //
    // 白名单当初的理由是"免费通道的能力和额度由上游决定，别让它拿到
    // shell"。但那个限制**挡住了本该能做的事**：免费档用户也用不了
    // 文件、终端、截屏这些常规工具，而模型会一遍遍尝试、拿到"无权限"。
    //
    // 这里在**读入时**清掉，而不是只改新建档案的那段代码 ——
    // 老用户的档案是存在 SharedPreferences 里的，
    // 只改 `_addBuiltinFreeProfile()` 对他们**完全没影响**，
    // 表现就是"更新了但限制还在"。
    //
    // 只清 `builtinFree` 的那些：用户自己配的档案如果**主动**设过白名单，
    // 那是他的选择，不能顺手抹掉。
    for (final ModelProfile p in profiles) {
      if (p.builtinFree) p.toolAllowlist = null;
    }

    if (activeProfile != null && activeProfile!.id != activeProfileId) {
      activeProfileId = activeProfile!.id;
    }

    thinkingEnabled = activeProfile?.thinking ?? true;
    reasoningEffort = activeProfile?.reasoningEffort ?? 'high';
    temperature = activeProfile?.temperature ?? 0.7;
    // 上限从 8 提到 100：老用户存的是 8，而那个值会让复杂任务中途被停。
    // 只在"正是旧默认值 8"时才升 —— 用户自己调过（比如 20）说明他有意图，
    // 不该被我们的默认值变更覆盖掉。
    final int savedRounds = _prefs.getInt('maxToolRounds') ?? 100;
    maxToolRounds = savedRounds == 8 ? 100 : savedRounds;
    searchApiKey = _prefs.getString('searchApiKey') ?? '';
    searchEngine = _prefs.getString('searchEngine') ?? 'bing';
    webSearchMode = _prefs.getString('webSearchMode') ?? 'auto';
    selfHostedSearchUrl = _prefs.getString('selfHostedSearchUrl') ?? '';
    webSearchEngine = _prefs.getString('webSearchEngine') ?? 'bing-rss';
    webSearchLimit = _prefs.getInt('webSearchLimit') ?? 8;
    imageGenModel = _prefs.getString('imageGenModel') ?? '';
    visionBaseUrl = _prefs.getString('visionBaseUrl') ?? '';
    visionApiKey = _prefs.getString('visionApiKey') ?? '';
    visionModel = _prefs.getString('visionModel') ?? 'deepseek-flash';
    embeddingModel = _prefs.getString('embeddingModel') ?? '';
    embeddingBaseUrl = _prefs.getString('embeddingBaseUrl') ?? '';
    embeddingApiKey = _prefs.getString('embeddingApiKey') ?? '';
    rerankModel = _prefs.getString('rerankModel') ?? '';
    rerankBaseUrl = _prefs.getString('rerankBaseUrl') ?? '';
    rerankApiKey = _prefs.getString('rerankApiKey') ?? '';
    ragTopK = _prefs.getInt('ragTopK') ?? 6;
    inputSuggestEnabled = _prefs.getBool('inputSuggestEnabled') ?? false;
    inputSuggestProfileId = _prefs.getString('inputSuggestProfileId') ?? '';
    inputSuggestEffort = _prefs.getInt('inputSuggestEffort') ?? 1;
    improvePrompt = _prefs.getBool('improvePrompt') ?? false;
    hiddenProfileIds =
        _prefs.getStringList('hiddenProfileIds') ?? <String>[];
    promptImproveLevel = _prefs.getString('promptImproveLevel') ?? 'medium';
    promptImproveModel = _prefs.getString('promptImproveModel') ?? '';
    promptImproveInstruction =
        _prefs.getString('promptImproveInstruction') ?? '';
    autoApproveAll = _prefs.getBool('autoApproveAll') ?? false;
    autoApproveSafe = _prefs.getBool('autoApproveSafe') ?? true;
    useOverlayConfirm = _prefs.getBool('useOverlayConfirm') ?? true;
    // 六套字体预设（fontScheme）不再读取：只剩"字号"和"用户自选一个字体
    // 文件"两件事。老的 prefs key 留着不删，免得回滚旧版本时设置丢失。
    customFontPath = _prefs.getString('customFontPath') ?? '';
    desktopUa = _prefs.getBool('desktopUa') ?? false;
    memoryEnabled = _prefs.getBool('memoryEnabled') ?? true;
    crossChatMemory = _prefs.getBool('crossChatMemory') ?? true;
    learningEnabled = _prefs.getBool('learningEnabled') ?? true;
    collapseToolSteps = _prefs.getBool('collapseToolSteps') ?? true;
    // 老版本存的是**布尔**（开/关）。迁一次：
    // `true` → `every`（原来的"每轮都压"），`false` → `off`。
    // 新 key 存在就用新值。
    compressMode =
        _prefs.getString('compressMode') ??
        ((_prefs.getBool('compressContext') ?? true) ? 'every' : 'off');
    compressKeepTurns = _prefs.getInt('compressKeepTurns') ?? 3;
    minimalProgress = _prefs.getBool('minimalProgress') ?? false;
    developerMode = _prefs.getBool('developerMode') ?? false;
    showPerTurnTimings = _prefs.getBool('showPerTurnTimings') ?? false;
    themePackNativeHeader = _prefs.getBool('themePackNativeHeader') ?? true;
    pcUrl = _prefs.getString('pcUrl') ?? '';
    workspacePath = _prefs.getString('workspacePath') ?? '';
    teenAdult = _prefs.getInt('teenAdult') ?? 1;
    teenPolitics = _prefs.getInt('teenPolitics') ?? 1;
    teenQuery = _prefs.getInt('teenQuery') ?? 1;
    fontScale = _prefs.getDouble('fontScale') ?? 1.0;
    landscapeFontScale = _prefs.getDouble('landscapeFontScale') ?? 1.0;
    themeSeed = _prefs.getInt('themeSeed') ?? 0;
    // 空串保留原样：首次启动看到"没选过"，才会弹模式选择页。
    // 不能默认成 daily —— 那样选择页永远不会出现。
    assistantMode = _prefs.getString('assistantMode') ?? '';
    modelChipInfo = _prefs.getString('modelChipInfo') ?? ModelChipInfo.detailed;
  }

  /// 把老的「单个 apiKey/baseUrl/model」升级成一个档案。
  ///
  /// **只在完全没有档案时执行。** 老用户升上来时密钥还在，
  /// 不需要重新去官网复制一遍。
  void _migrateLegacyProfile() {
    final String key = _prefs.getString('apiKey') ?? '';
    final String url =
        _prefs.getString('baseUrl') ?? 'https://api.deepseek.com';
    final String name = _prefs.getString('model') ?? 'deepseek-flash';

    // 从没配过（密钥为空）就不建档案 —— 空档案会让首页显示一个
    // "已选模型"但发不出消息的假状态，不如干脆显示"还没有模型"。
    if (key.trim().isEmpty) return;

    final String host = Uri.tryParse(url)?.host ?? '';
    final ModelProfile p = ModelProfile(
      id: newId(),
      name: host.isNotEmpty ? host : '默认模型',
      baseUrl: url,
      apiKey: key,
      model: name,
    );
    profiles.add(p);
    activeProfileId = p.id;
  }

  /// 新建内置免费档。
  ///
  /// 它不写 API Key 输入框里的 `public` 到用户可见的位置也能工作：
  /// `usable` 只要求 key 非空，而免费网关本来就把 `public` 当公开凭据。
  ///
  /// **不再挂工具白名单**（`toolAllowlist: null` = 不限制）。
  /// 原来这里给的是 [kBasicToolAllowlist]，理由是"免费通道的能力和额度
  /// 由上游决定，不能让它顺手拿到 shell" —— 但那个限制实际挡住的是
  /// 文件、终端、截屏这些常规能力，而模型只会反复尝试再拿到"无权限"，
  /// 体验上就是"免费档不好用"。工具该不该用由**风险确认**那一层管
  /// （危险命令照样弹框），而不是按"是不是免费"一刀切。
  void _addBuiltinFreeProfile() {
    final ModelProfile p = ModelProfile(
      id: newId(),
      name: '免费 DeepSeek',
      note: '内置免费通道 · 工具不限制 · 不可用自动切备用免费池',
      baseUrl: kFreeDeepSeekBaseUrl,
      apiKey: 'public',
      model: kFreeDeepSeekModel,
      thinking: true,
      thinkingStyle: ThinkingStyle.effortOnly,
      reasoningEffort: 'high',
      vision: false,
      // null = 不限制，和用户自建档案的默认值一致
      toolAllowlist: null,
      builtinFree: true,
    );
    profiles.add(p);
    activeProfileId = p.id;
  }

  /// 当前档案是否允许某个工具。
  ///
  /// `null` 白名单 = 不限制；空列表 = 明确全关。
  /// 注册表在构建时调用它，而不是在执行时临时判断 ——
  /// 不注册的工具模型根本看不见，不会反复调用然后拿到"无权限"。
  bool allowsTool(String name, {ModelProfile? profile}) {
    final List<String>? allow = (profile ?? activeProfile)?.toolAllowlist;
    return allow == null || allow.contains(name);
  }

  bool get activeIsBuiltinFree => activeProfile?.builtinFree ?? false;

  Future<void> update(void Function() mutate) async {
    // ---- 顺序很要紧，别把这两步调过来 ----
    //
    // 1) **先**把 top-level 的思考/强度/温度铺回当前档案；
    // 2) **再**跑 mutate()（可能新增/改写档案）。
    //
    // 反过来会踩一个很隐蔽的坑：模型编辑页保存时走的是
    //   update(() => addProfile(created))
    // 而 addProfile 会把新档案设为当前档案。此时若再执行第 1 步，
    // 刚在编辑页里设好的 thinking / reasoningEffort 就会被
    // **top-level 的旧值覆盖**（顶层那两项是全局的，可能是上一次编辑
    // 别的模型时留下的）—— 表现为"我在编辑页关了思考模式，保存后它又开了"。
    final ModelProfile? active = activeProfile;
    if (active != null) {
      active
        ..thinking = thinkingEnabled
        ..reasoningEffort = reasoningEffort
        ..temperature = temperature;
    }

    mutate();
    notifyListeners();

    await _prefs.setString('apiKey', apiKey);
    await _prefs.setString('baseUrl', baseUrl);
    await _prefs.setString('model', model);
    await _prefs.setString('modelProfiles', ModelProfile.encodeList(profiles));
    if (activeProfileId != null) {
      await _prefs.setString('activeProfileId', activeProfileId!);
    } else {
      await _prefs.remove('activeProfileId');
    }
    await _prefs.setBool('thinkingEnabled', thinkingEnabled);
    await _prefs.setString('reasoningEffort', reasoningEffort);
    await _prefs.setDouble('temperature', temperature);
    await _prefs.setInt('maxToolRounds', maxToolRounds);
    await _prefs.setString('searchApiKey', searchApiKey);
    await _prefs.setString('searchEngine', searchEngine);
    await _prefs.setString('webSearchMode', webSearchMode);
    await _prefs.setString('selfHostedSearchUrl', selfHostedSearchUrl);
    await _prefs.setString('webSearchEngine', webSearchEngine);
    await _prefs.setInt('webSearchLimit', webSearchLimit);
    await _prefs.setString('imageGenModel', imageGenModel);
    await _prefs.setString('visionBaseUrl', visionBaseUrl);
    await _prefs.setString('visionApiKey', visionApiKey);
    await _prefs.setString('visionModel', visionModel);
    await _prefs.setString('embeddingModel', embeddingModel);
    await _prefs.setString('embeddingBaseUrl', embeddingBaseUrl);
    await _prefs.setString('embeddingApiKey', embeddingApiKey);
    await _prefs.setString('rerankModel', rerankModel);
    await _prefs.setString('rerankBaseUrl', rerankBaseUrl);
    await _prefs.setString('rerankApiKey', rerankApiKey);
    await _prefs.setInt('ragTopK', ragTopK);
    await _prefs.setBool('inputSuggestEnabled', inputSuggestEnabled);
    await _prefs.setString('inputSuggestProfileId', inputSuggestProfileId);
    await _prefs.setInt('inputSuggestEffort', inputSuggestEffort);
    await _prefs.setBool('improvePrompt', improvePrompt);
    await _prefs.setStringList('hiddenProfileIds', hiddenProfileIds);
    await _prefs.setString('promptImproveLevel', promptImproveLevel);
    await _prefs.setString('promptImproveModel', promptImproveModel);
    await _prefs.setString(
      'promptImproveInstruction',
      promptImproveInstruction,
    );
    await _prefs.setBool('autoApproveAll', autoApproveAll);
    await _prefs.setBool('autoApproveSafe', autoApproveSafe);
    await _prefs.setBool('useOverlayConfirm', useOverlayConfirm);
    await _prefs.setBool('memoryEnabled', memoryEnabled);
    await _prefs.setBool('crossChatMemory', crossChatMemory);
    await _prefs.setBool('learningEnabled', learningEnabled);
    await _prefs.setBool('collapseToolSteps', collapseToolSteps);
    await _prefs.setString('compressMode', compressMode);
    // 老 key 同步成布尔：回滚旧版本时语义仍然对（every/ratio 都算"开"）。
    await _prefs.setBool('compressContext', compressMode != 'off');
    await _prefs.setInt('compressKeepTurns', compressKeepTurns);
    await _prefs.setBool('minimalProgress', minimalProgress);
    await _prefs.setBool('developerMode', developerMode);
    await _prefs.setBool('showPerTurnTimings', showPerTurnTimings);
    await _prefs.setBool('themePackNativeHeader', themePackNativeHeader);
    await _prefs.setString('pcUrl', pcUrl);
    await _prefs.setString('workspacePath', workspacePath);
    await _prefs.setInt('teenAdult', teenAdult);
    await _prefs.setInt('teenPolitics', teenPolitics);
    await _prefs.setInt('teenQuery', teenQuery);
    await _prefs.setDouble('fontScale', fontScale);
    await _prefs.setDouble('landscapeFontScale', landscapeFontScale);
    await _prefs.setString('customFontPath', customFontPath);
    await _prefs.setBool('desktopUa', desktopUa);
    await _prefs.setInt('themeSeed', themeSeed);
    await _prefs.setString('assistantMode', assistantMode);
    await _prefs.setString('modelChipInfo', modelChipInfo);
  }

  /// 是否已经绑定了至少一个能用的模型。
  bool get configured => profiles.any((ModelProfile p) => p.usable);

  /// 把 TeenSpace 的三档敏感度拼成一段注入系统提示词的文字。
  ///
  /// **三档全「标准」时返回空串。** 因为"标准"就是模型的默认行为，
  /// 特意写一段"请保持标准"既白花 token，又可能让模型过度紧张、
  /// 该说的也缩着不说。
  ///
  /// 这段文字是**指导**，不是过滤器 —— 应用没有语义理解能力，
  /// 判断不了"什么算政治议题"。详见 `TeenSpacePage` 的说明。
  String contentPolicyPrompt() {
    final List<String> rules = <String>[];

    if (teenAdult == 2) {
      rules.add('- 性、暴力、血腥的直接描写：拒绝，只给概括，或建议换个方向。');
    } else if (teenAdult == 0) {
      rules.add('- 成人向内容：用户是成年人，按正常尺度回答，不要主动规避。');
    }

    if (teenPolitics == 2) {
      rules.add(
        '- 政治议题：只陈述可考证的事实，**不给立场判断、不做预测**；'
        '存在争议的部分要说明存在争议，不要替用户下结论。',
      );
    } else if (teenPolitics == 0) {
      rules.add('- 政治议题：可以给出分析和立场，不必自我审查。');
    }

    if (teenQuery == 2) {
      rules.add(
        '- 作业 / 考试 / 竞赛题：**不要直接给最终答案**。'
        '讲清思路、点出关键那一步，让用户自己算出来。',
      );
    } else if (teenQuery == 0) {
      rules.add('- 作业 / 考试题：直接给答案和完整过程，不用顾虑。');
    }

    if (rules.isEmpty) return '';

    return '\n内容尺度（用户在 TeenSpace 里设定，优先级高于你自己的默认习惯）：\n'
        '${rules.join('\n')}\n'
        '这是**回答尺度**的指导，不是内容过滤 —— 按它调整你的表达方式即可，'
        '不要向用户复述这段规则。\n';
  }

  /// 当前模型是否具备图像理解能力。
  ///
  /// 现在读的是**档案上用户声明的 [ModelProfile.vision]** —— "这个模型看不看得懂图"
  /// 没有可靠的自动探测办法（不同厂商、不同版本各不相同），
  /// 猜错的代价是发出去的图片被 API 顶回来（400），不如让用户在绑定模型时勾一下。
  bool get modelSeesImages => activeProfile?.vision ?? true;

  /// 生图该用哪套配置：**当前档案的地址和密钥** + [imageGenModel] 这个模型名。
  ///
  /// 只有模型名是单独配的，因为一个中转站常常"一条档案、多个模型"：
  /// 地址和 Key 是同一个，对话用 `gpt-4o`、画图用 `gpt-image-2`。
  /// 地址和密钥没必要让用户再选一遍 —— 他刚刚才填过。
  ///
  /// 返回 null 表示没配生图模型（那时工具根本不会注册，见
  /// 工具那一侧给一条能看懂的提示，见 `ImageGenTool.run`）。
  ImageGenConfig? get imageGenConfig {
    final ModelProfile? profile = activeProfile;
    final String model = imageGenModel.trim();
    if (profile == null || model.isEmpty) return null;
    if (!profile.usable) return null;

    return ImageGenConfig(
      baseUrl: profile.normalizedBaseUrl,
      apiKey: profile.apiKey,
      model: model,
    );
  }

  /// 当前模型档案是否**声明**了自己能生成图片（见 [ModelProfile.tools]）。
  ///
  /// ⚠️ **它不再决定 `generate_image` 注不注册**。生图走的是
  /// [imageGenConfig]（另一个模型名 + 当前档案的地址和密钥），
  /// 和对话模型是不是"能画图"没有关系 —— 拿这个开关去拦，会把
  /// 用户平时聊天的模型全都拦掉（中转站批量导入的档案工具集是空数组）。
  /// 现在它只是一条**能力描述**，给界面和提示词用。
  bool get modelGeneratesImages =>
      activeProfile?.hasTool(kImageGenTool) ?? false;

  /// 当前模型的上下文窗口（token）。
  ///
  /// 拿不准就给保守值 —— 高估会让用户以为还有余量、实际早该压缩了。
  /// 从前这个判断写死在 `agent.dart` 里按模型名猜（含 flash/pro 就当 1M），
  /// 现在多模型了，**按名字猜完全不可靠**：中转站里几十个模型的命名五花八门，
  /// 猜出来的数可能差十倍。所以以档案上的 `contextLimit` 字段为准，
  /// 没填才回退到"只认那两个很确定的官方型号"。
  int get contextLimit {
    final int declared = activeProfile?.contextLimit ?? 0;
    if (declared > 0) return declared;

    final String m = model.toLowerCase();
    // 只保留两条很确定的：DeepSeek 官方这两个型号确实是 1M。
    // 其余一律按保守值 —— 猜小了只是多弹一次压缩提示，
    // 猜大了是"塞爆了还不知道为什么"。
    if (m == 'deepseek-flash' || m == 'deepseek-v4-pro') return 1000000;
    return 128000;
  }

  /// 当前模型的接口地址（OpenAI 兼容的 `/chat/completions`）。
  String get chatEndpoint =>
      activeProfile?.chatEndpoint ??
      'https://api.deepseek.com/chat/completions';
}

/// 会话历史，存成一个 JSON 文件。
///
/// 用文件而不是 SharedPreferences：历史会随着使用不断变长，
/// 塞进 key-value 存储里迟早会遇到大小和性能问题。
class ConversationStore extends ChangeNotifier {
  ConversationStore(this._file);

  final File _file;

  final List<Conversation> conversations = <Conversation>[];
  String? currentId;

  Conversation? get current {
    if (currentId == null) return null;
    for (final Conversation c in conversations) {
      if (c.id == currentId) return c;
    }
    return null;
  }

  /// 排序：**置顶的永远在最前**，其余按最近更新。
  ///
  /// 置顶不参与时间排序（哪怕它三个月没动过也还在最上面）——
  /// "我把它钉在这儿"的意思就是"别让时间把它冲下去"。
  List<Conversation> get sorted {
    final List<Conversation> list = List<Conversation>.from(conversations)
      ..sort((Conversation a, Conversation b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    return list;
  }

  /// 历史列表：排序之后**再去掉空白页**。
  ///
  /// 空白页（见 [Conversation.isBlank]）不是历史 —— 它是"还没写字的草稿纸"，
  /// 每开一次就多一条「新对话」，真正的历史会被一路挤下去。
  /// 这里过滤掉它，用户看到的列表就只剩"确实聊过"的会话。
  ///
  /// 过滤放在这里而不是各调用点：列表只有这一个出口，判断就只有一处。
  List<Conversation> get history =>
      sorted.where((Conversation c) => !c.isBlank).toList();

  /// 历史是否已经**从磁盘读完了**。
  ///
  /// 首帧现在**不等**历史加载（见 `main()`），所以界面有可能在历史还是
  /// 空的时就构建出来。这时候任何"列表是空的 → 建个新会话"的判断
  /// 都会误伤：历史读到之后它就变成一条凭空多出来的空白页。
  ///
  /// 于是所有这类判断都先看这个标记 —— 它只在 [load] 结束时变 true。
  ///
  /// 默认值**必须是 true**：测试和工具里大量 `ConversationStore(...)` 之后
  /// 直接 `createNew()`，从没调过 `load()`；默认 false 会让它们全部失效。
  /// 真正的"还没读完"只可能出现在 [load] 正在跑的那一段。
  bool get loaded => _loaded;
  bool _loaded = true;

  Future<void> load() async {
    _loaded = false;
    conversations.clear();
    try {
      // 注意这里**不能提前 return**：首帧已经不等加载了，返回前必须
      // 把"读完了"这件事通知出去，否则界面会一直停在空状态上。
      if (await _file.exists()) {
        final List<Conversation> parsed = await _readConversations(_file);
        // 老存档里堆积的空白页在**读入时就丢掉**（见 [Conversation.isBlank]）。
        // 不丢的话，升级上来的第一次启动就会看到一串「新对话」；
        // 而且要等用户手动清一遍才能干净 —— 那不是他该操心的事。
        // 过滤放在解析那一侧（[_readConversations]）做，省一次全表遍历。
        conversations.addAll(parsed);
        // 取**最近更新**的那条，而不是 `sorted.first`：置顶之后列表第一条是
        // "被钉住的那条"，不一定是他上次聊的那条。用 sorted 会变成
        // "打开应用落在置顶会话上" —— 那不是置顶该有的副作用。
        currentId = conversations.isEmpty
            ? null
            : conversations
                  .reduce(
                    (Conversation a, Conversation b) =>
                        a.updatedAt.isAfter(b.updatedAt) ? a : b,
                  )
                  .id;
      }
    } catch (_) {
      // 历史文件损坏时不该阻止 app 启动
      conversations.clear();
      currentId = null;
    } finally {
      _loaded = true;
      // 放在 finally：成功、没文件、解析失败三条路都要把界面叫醒一次。
      notifyListeners();
    }
  }

  Future<void> save() async {
    // ⚠️ **历史还没读完时绝不写盘。**
    //
    // 启动初期 `load()` 还在后台跑，内存里的 `conversations` 是**空的**。
    // 这时候任何一次 `save()`（新建会话、改名、切置顶都会触发）都会把
    // 这份空列表写进文件 —— 用户的全部历史被一次点击抹掉，而且下一个
    // 启动才看得出来。
    //
    // 丢弃这一次写入是安全的：这段时间里改的都是内存里刚建的东西，
    // `load()` 结束后它们会重新被创建 / 用户会重新操作。**丢一次写入
    // 远好过丢全部历史。**
    if (!_loaded) return;
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        // **空白页不落盘**（见 [Conversation.isBlank]）。
        //
        // 这是"新开的空白页不断记进历史"那条 bug 的根治：只要没写过字，
        // 它连文件都进不去，重启之后自然就只剩一条（启动时补的那一条）。
        // 用户改过名或置顶过的空会话不算空白页，照样存 —— 那是他的东西。
        jsonEncode(
          conversations
              .where((Conversation c) => !c.isBlank)
              .map((Conversation c) => c.toJson())
              .toList(),
        ),
      );
    } catch (_) {
      // 写失败不致命，下次再试
    }
  }

  /// 新建一条会话，或者**回到已经存在的那条空白页**。
  ///
  /// ## 为什么不无条件新建
  ///
  /// 空白页不参与历史记录（[save] / [history]），所以"再开一条空的"
  /// 除了在内存里堆出同一个空白页的多份副本之外没有任何作用 ——
  /// 而只要有一条引用活着，它就可能被顺手写进某个列表里。
  /// 回到已有的那条，语义上完全等价，而且"空白页永远只有一条"这件事
  /// 从源头上就成立了，不用靠别处小心。
  Conversation createNew() {
    for (final Conversation c in conversations) {
      if (!c.isBlank) continue;
      currentId = c.id;
      notifyListeners();
      return c;
    }
    final Conversation c = Conversation(
      id: newId(),
      title: Conversation.defaultTitle,
    );
    conversations.add(c);
    currentId = c.id;
    notifyListeners();
    unawaitedSave();
    return c;
  }

  void select(String id) {
    currentId = id;
    notifyListeners();
  }

  /// 改会话名字。
  ///
  /// **不动 `updatedAt`**：改名是"整理"，不是"聊了"。跟着时间戳走的话，
  /// 给一条三个月前的会话改名会把它顶到列表最上面 —— 用户看到的顺序
  /// 会和他刚做的事对不上。
  ///
  /// 空名字回退成「新对话」：否则历史里会出现一行**完全的空白**，
  /// 看起来像数据坏了，而且点不着（没有任何可点的文字）。
  void rename(String id, String title) {
    final String t = title.trim();
    for (final Conversation c in conversations) {
      if (c.id != id) continue;
      c.title = t.isEmpty ? Conversation.defaultTitle : t;
      break;
    }
    notifyListeners();
    unawaitedSave();
  }

  /// 置顶 / 取消置顶（同一个动作的两个方向，做成一个开关语义）。
  void togglePin(String id) {
    for (final Conversation c in conversations) {
      if (c.id != id) continue;
      c.pinned = !c.pinned;
      break;
    }
    notifyListeners();
    unawaitedSave();
  }

  void remove(String id) {
    conversations.removeWhere((Conversation c) => c.id == id);
    if (currentId == id) {
      currentId = conversations.isEmpty ? null : sorted.first.id;
    }
    notifyListeners();
    unawaitedSave();
  }

  /// 一次删掉多条（历史列表的"批量删除"用）。
  ///
  /// 为什么不直接循环调 [remove]：那样每删一条就 `notifyListeners()` 一次、
  /// 落盘一次 —— 删二十条就是二十次重建 + 二十次写文件，界面会明显卡。
  /// 这里收成一次。
  void removeMany(Iterable<String> ids) {
    final Set<String> gone = ids.toSet();
    if (gone.isEmpty) return;
    conversations.removeWhere((Conversation c) => gone.contains(c.id));
    if (currentId != null && gone.contains(currentId)) {
      // 删掉的可能正是当前这条：落到剩下的第一条上（没有就交给调用方补空白页，
      // 和 clearAll 的处理保持一致）。
      currentId = conversations.isEmpty ? null : sorted.first.id;
    }
    notifyListeners();
    unawaitedSave();
  }

  /// 一次给多条设置置顶状态（批量"置顶 / 取消置顶"用）。
  ///
  /// 语义是**赋值**而不是翻转：一批里有的已置顶、有的没置顶时，
  /// 翻转会把它们变成一半一半 —— 而用户点的是"置顶"，他要的是"都置顶"。
  void setPinned(Iterable<String> ids, bool pinned) {
    final Set<String> want = ids.toSet();
    if (want.isEmpty) return;
    bool changed = false;
    for (final Conversation c in conversations) {
      if (!want.contains(c.id) || c.pinned == pinned) continue;
      c.pinned = pinned;
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    unawaitedSave();
  }

  void clearAll() {
    conversations.clear();
    currentId = null;
    notifyListeners();
    unawaitedSave();
  }

  /// 用导入的数据整体替换（导入备份的「覆盖」模式用）。
  ///
  /// 放在 store 内部而不是让导入代码直接改列表再调 notifyListeners()：
  /// notifyListeners 是 ChangeNotifier 的 protected 成员，外部调用会被分析器拦下；
  /// 而且 currentId 的重置逻辑也该由 store 自己负责。
  void replaceAll(List<Conversation> next) {
    conversations
      ..clear()
      ..addAll(next);
    currentId = conversations.isEmpty ? null : sorted.first.id;
    notifyListeners();
    unawaitedSave();
  }

  /// 批量追加（导入备份的「合并」模式用）
  void appendMissing(List<Conversation> next) {
    final Set<String> existing = conversations
        .map((Conversation c) => c.id)
        .toSet();
    bool changed = false;
    for (final Conversation c in next) {
      if (existing.contains(c.id)) continue;
      conversations.add(c);
      changed = true;
    }
    if (!changed) return;
    if (currentId == null && conversations.isNotEmpty) {
      currentId = sorted.first.id;
    }
    notifyListeners();
    unawaitedSave();
  }

  /// 用首条用户消息给会话起个名字，方便在历史里认出来
  void touch(Conversation c) {
    c.updatedAt = DateTime.now();
    if (c.title == Conversation.defaultTitle) {
      for (final ChatMessage m in c.messages) {
        if (m.role == Role.user && !m.hidden && m.content.trim().isNotEmpty) {
          final String t = m.content.trim().replaceAll('\n', ' ');
          c.title = t.length > 18 ? '${t.substring(0, 18)}…' : t;
          break;
        }
      }
    }
    notifyListeners();
  }

  void unawaitedSave() {
    // 故意不 await：调用方通常在 UI 回调里，不想被磁盘 IO 阻塞
    save();
  }
}

/// 在**后台 isolate** 里读完整个会话文件并解析好。
///
/// ## 为什么必须离开主 isolate
///
/// 会话文件是**只增不减**的：每聊一条消息、每接一张图，它就大一点。
/// 聊到几千条消息时它是几 MB，`jsonDecode` 加上几千次 `Conversation.
/// fromJson` 在主 isolate 上是**几百毫秒的纯阻塞** —— 这期间界面一帧
/// 都画不出来。用户看到的不是"加载中"，而是**点了图标什么都没发生**，
/// 于是以为应用卡死了。
///
/// 移出去之后主 isolate 只负责把结果接过来，解析期间它空着，可以正常
/// 出首帧、响应点击。
///
/// ## 参数只传路径字符串
///
/// 不传 `File` 对象：后台 isolate 之间传对象要经过序列化，`File` 这种
/// 带平台句柄的东西既没必要也不稳妥。路径是纯字符串，最省。
///
/// ## 返回值是普通的 Dart 对象
///
/// `Conversation` / `ChatMessage` 这一串虽然挂在 Flutter 的模型层里，
/// 但它们是**纯数据**（只有 `TextMark.background` 用到 `Color` 常量），
/// 没有 `BuildContext`、没有 isolate-local 的状态，跨 isolate 传递是安全的。
Future<List<Conversation>> _readConversations(File file) async {
  final String path = file.path;
  // 读盘 + 解析**都在后台做**：单独把读盘留在主 isolate 上没意义，
  // 几 MB 的一次性读同样是阻塞。
  return Isolate.run<List<Conversation>>(() async {
    final File f = File(path);
    if (!await f.exists()) return <Conversation>[];
    final String raw = await f.readAsString();
    // 空文件 / 只剩空白：当没有历史，省掉解析。
    if (raw.trim().isEmpty) return <Conversation>[];
    final dynamic data = jsonDecode(raw);
    if (data is! List) return <Conversation>[];
    final List<Conversation> out = <Conversation>[];
    for (final dynamic e in data) {
      final Conversation c = Conversation.fromJson(
        Map<String, dynamic>.from(e as Map),
      );
      // 空白页在这一侧就丢掉：主 isolate 拿到的直接是可用的列表。
      if (c.isBlank) continue;
      out.add(c);
    }
    return out;
  });
}
