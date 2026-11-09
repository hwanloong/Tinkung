import '../core/models.dart';
import '../core/productivity.dart';
import '../core/store.dart';
import '../plugins/plugin.dart';
import '../shizuku/shizuku_service.dart';
import 'risk.dart';

/// 工具执行上下文
/// 派给一个子智能体的任务。
class SubAgentSpec {
  const SubAgentSpec({required this.label, required this.task});

  /// 展示用的名字（"查天气""核对数字"），也是结果里的小标题。
  final String label;

  /// 交给子智能体的完整任务。它**看不到**主对话，所以这里要写全。
  final String task;
}

/// 一个子智能体跑完的结果。
class SubAgentResult {
  const SubAgentResult({
    required this.label,
    required this.ok,
    required this.answer,
    this.error = '',
  });

  final String label;
  final bool ok;

  /// 子智能体最后一条回答的正文（只回填这个，不回填它的全部中间过程）。
  final String answer;
  final String error;
}

class ToolContext {
  const ToolContext({
    required this.settings,
    required this.shizuku,
    required this.conversation,
    required this.workDir,
    required this.searchApiKey,
    required this.visionBaseUrl,
    required this.visionApiKey,
    required this.visionModel,
    required this.mainApiKey,
    required this.mainBaseUrl,
    required this.mainModel,
    required this.modelSeesImages,
    required this.modelGeneratesImages,
    required this.imageGen,
    required this.searchEngine,
    required this.webSearchMode,
    required this.selfHostedSearchUrl,
    required this.notes,
    required this.tasks,
    required this.plugins,
    this.dispatchSubAgents,
  });

  /// 全局设置。模型管理工具需要它来新增/修改/切换档案。
  final Settings settings;

  final ShizukuService shizuku;

  /// **当前这场对话**（可写）。
  ///
  /// 给谁用：`mark` 工具 —— 标记是挂在**消息**上的（`ChatMessage.marks`），
  /// "把刚才那句标黄"这件事没有别的落点。除此之外的工具都不该改它：
  /// 会话内容属于用户，模型只能通过正常回复去影响它。
  final Conversation conversation;

  /// 应用私有目录：截图、录屏、临时文件都放这里，
  /// 避免污染用户可见的 /sdcard。
  final String workDir;

  /// 笔记与任务。agent 能直接读写它们 —— 这是「常规 agent 功能」的核心：
  /// 用户说「记一下」「明天提醒我」时，模型应该真的写进去，而不是只回一句话。
  final NoteStore notes;
  final TaskStore tasks;

  /// 自定义插件仓库。
  ///
  /// 给 `plugin` 工具用：让 agent 能**看**有哪些插件、也能**改**（新建、
  /// 改模板、开关、删除）。没有它的时候插件只能靠用户自己在界面里点，
  /// 而"帮我加一个能查天气的工具"这种话说出来是没人接的。
  final PluginStore plugins;

  /// **派发子智能体**（multibot 用）。由 [AgentRunner] 注入：它知道怎么
  /// 用父的模型、工具表和设置起一个新的 runner。
  ///
  /// null = 当前上下文不允许再派子智能体 —— 子智能体自己拿到的上下文就是
  /// null，这是防止"子智能体又派子智能体"无限递归的开关。
  final Future<List<SubAgentResult>> Function(List<SubAgentSpec> specs)?
  dispatchSubAgents;

  final String searchApiKey;

  /// 可选的独立视觉模型配置（覆盖主模型）
  final String visionBaseUrl;
  final String visionApiKey;
  final String visionModel;

  /// 主对话模型的信息。识图默认直接走它——
  /// deepseek-flash 本身就支持图像理解，不必再挂第三方视觉模型。
  final String mainApiKey;
  final String mainBaseUrl;
  final String mainModel;

  /// 当前模型**看不看得懂图**（多模态输入）。用户声明，见 ModelProfile.vision。
  final bool modelSeesImages;

  /// 当前模型**画不画得出图**（多模态输出）。
  ///
  /// 和 [modelSeesImages] 是两件独立的事，别合并成一个开关：
  /// 只看得懂图的模型和只会画图的模型都存在。它决定 `generate_image`
  /// 这个工具**注不注册** —— 不注册比"注册了但一调就报错"好得多，
  /// 后者会让模型白白浪费一轮。
  final bool modelGeneratesImages;

  /// **生图专用的那套配置**（地址 / 密钥 / 模型名）。
  ///
  /// 和上面三个 `main*` 是**两回事**：对话和生图几乎不会用同一个模型
  /// （生图模型不能对话、对话模型不能生图），所以生图不能拿 [mainModel]
  /// 去发请求 —— 那正是之前"点了生图没反应"的原因之一。
  ///
  /// null 表示还没配，工具会返回一句能看懂的提示而不是发一个注定失败的请求。
  final ImageGenConfig? imageGen;

  /// 内置浏览器抓取搜索时使用的搜索引擎（bing / duckduckgo / baidu / google）
  final String searchEngine;

  /// 联网搜索走哪条通道：auto / deepseek / browser
  final String webSearchMode;

  /// 自建搜索服务地址（agent-web-search 这类）。留空表示未配置。
  final String selfHostedSearchUrl;
}

/// 一个可被模型调用的工具。
abstract class AgentTool {
  const AgentTool();

  /// 给模型看的函数名（英文、下划线）
  String get name;

  /// 给人看的中文名
  String get title;

  /// 给模型看的说明
  String get description;

  /// JSON Schema 形式的参数定义
  Map<String, dynamic> get parameters;

  /// 由工具自己判断本次调用的风险等级。
  /// shell 类工具会走 [RiskClassifier]，其它工具按操作语义给出。
  RiskAssessment riskFor(Map<String, dynamic> args);

  /// 是否**跳过确认框、直接执行**。
  ///
  /// 默认 false —— 风险不是 safe 的操作都要用户点一下。
  ///
  /// 为什么要单独开这个口子，而不是直接把 [riskFor] 改成恒返回 safe：
  /// 两者是**不同的问题**。风险等级是"这次调用有多危险"，用来上色、给用户看、
  /// 写进日志；而确认框问的是"要不要让用户点一下"。把风险等级改成 safe
  /// 等于**谎报**，工具行上的红点会变成绿的，用户就再也看不出刚才那段
  /// 代码删了文件 —— 那是把安全性做成了装饰。
  ///
  /// 所以：等级照实报，确认单独关。
  bool get autoApprove => false;

  /// 执行并返回给模型看的文本结果
  Future<String> run(ToolContext ctx, Map<String, dynamic> args);

  /// 单次调用的**兜底时限**。默认 10 分钟。
  ///
  /// 这不是"给慢工具加时间"的开关，而是"不让一次调用把整场对话挂死"的
  /// 保险。多数工具内部有自己的超时（shell 120s、HTTP 30s…），但外挂插件、
  /// 浏览器自动化、生图/生视频的轮询这类没有统一上限 —— 一旦某次调用卡住，
  /// agent 主循环就停在 `await` 上，用户看到的只是"一直转圈"，连停止按钮
  /// 都只能掐网络、掐不掉这个 await。
  ///
  /// 需要跑更久的工具（长任务、大文件）自己覆盖这个 getter ——
  /// 默认值存在的意义是"忘了覆盖也不会挂死"。
  Duration get timeout => const Duration(minutes: 10);

  /// 供 UI 展示的命令/操作摘要
  String summarize(Map<String, dynamic> args) => name;
}

class ToolRegistry {
  ToolRegistry([List<AgentTool>? tools]) : _tools = <AgentTool>[...?tools];

  final List<AgentTool> _tools;

  void register(AgentTool tool) => _tools.add(tool);

  void registerAll(Iterable<AgentTool> tools) => _tools.addAll(tools);

  List<AgentTool> get all => List<AgentTool>.unmodifiable(_tools);

  AgentTool? byName(String name) {
    for (final AgentTool t in _tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// 按档案白名单裁剪注册表。
  ///
  /// 在执行前裁剪而不是在 `run()` 里拒绝：没注册的工具模型根本看不到，
  /// 不会浪费一轮去调用一个注定失败的函数。
  void retainWhere(bool Function(AgentTool tool) test) {
    _tools.removeWhere((AgentTool t) => !test(t));
  }

  /// 转成 OpenAI / DeepSeek 的 tools 字段
  List<Map<String, dynamic>> toApiSchema() {
    return _tools
        .map(
          (AgentTool t) => <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
          },
        )
        .toList();
  }
}

/// 参数读取的小工具：模型给的东西不可信，类型和缺失都要兜住。
extension ToolArgs on Map<String, dynamic> {
  String str(String key, {String fallback = ''}) {
    final dynamic v = this[key];
    if (v == null) return fallback;
    return v.toString();
  }

  int intVal(String key, {int fallback = 0}) {
    final dynamic v = this[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  bool boolVal(String key, {bool fallback = false}) {
    final dynamic v = this[key];
    if (v is bool) return v;
    final String s = v?.toString().toLowerCase() ?? '';
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
    return fallback;
  }

  /// 读一个**字符串数组**（单个字符串也收）。
  ///
  /// 模型经常把数组写成 `"a,b"` 或者干脆给一个字符串 —— 直接
  /// `as List` 会抛异常，而那种异常只会变成一句"工具执行失败"。
  List<String> listVal(String key) {
    final dynamic v = this[key];
    if (v is List) {
      return v
          .map((dynamic e) => e?.toString().trim() ?? '')
          .where((String s) => s.isNotEmpty)
          .toList();
    }
    final String s = v?.toString().trim() ?? '';
    return s.isEmpty ? <String>[] : <String>[s];
  }

  /// 读一个**对象**（maps only，其它一律当空）。
  Map<String, dynamic> mapVal(String key) {
    final dynamic v = this[key];
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }
}

/// shell 单引号转义：把 `'` 换成 `'\''`。
/// 模型给的字符串可能含引号/分号，不转义会直接把命令拆坏（既是 bug 也是注入面）。
String shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 限制回传给模型的文本长度，避免一次 ls -R 把上下文撑爆
String clampOutput(String s, {int max = 12000}) {
  if (s.length <= max) return s;
  final String head = s.substring(0, max);
  return '$head\n…（输出过长已截断，共 ${s.length} 字符）';
}
