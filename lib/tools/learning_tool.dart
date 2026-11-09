import '../core/learning.dart';
import '../core/models.dart';
import 'tool.dart';

/// 让 agent 把**自己踩过的坑**写进「自学习笔记」。
///
/// ## 为什么需要它
///
/// 一次任务里走过的弯路，下一场对话它就忘了 —— 同一个错误（路径没转义、
/// 该先 `ui_tree` 却直接点坐标、HTTP 400 还在原样重试）会一再发生。
/// 记忆工具记的是"关于用户的事实"，规则工具记的是"用户的长期指令"，
/// 两者都不适合放**操作经验**：
///
///  · 写进记忆 → 混进"用户事实"，模型会拿它当用户偏好；
///  · 写进规则 → 需要用户确认，而且语义是"用户命令我这样做"。
///
/// 所以单独给一个只属于 agent 自己的笔记本。
///
/// ## 权限方向是**单向**的
///
/// agent 只能 `add` / `list`，**不能删除**（工具里根本没有删除动作）；
/// 用户只能在设置页查看和删除，**不能添加**。这不是权限疏漏，
/// 而是这个功能的定义：它必须始终是"agent 自己的复盘"。
///
/// ## 为什么默认不用确认框
///
/// 用户要求的是"每次绕弯子 / 犯错 / 学到技能都**自己**写进去"。每写一条
/// 都弹一次确认，等于把复盘变成了打扰，最后用户会关掉整个功能。
/// 风险上它是可控的：只写进本地提示词、不执行任何操作，而且
/// [LearningStore.add] 会拦掉"绕过安全规则 / 夹带密钥"的内容。
///
/// 注意：用户把「只读命令自动执行」**关掉**时，那个总闸优先 ——
/// 这时连本工具也会弹确认（和 `python` 一样）。用户明确要求
/// "什么都让我看一眼"，不能因为想少打扰就绕过它。
class LearnTool extends AgentTool {
  const LearnTool();

  @override
  String get name => 'learn';

  @override
  String get title => '自学习';

  @override
  String get description =>
      '把**你自己**在任务里得到的操作经验写进「自学习笔记」，之后每轮对话都会看到。\n'
      '**什么时候写**（每次遇到都要写，不要只在用户要求时写）：\n'
      '· 走弯路：试了两三次才找到对的做法；\n'
      '· 犯错：被用户纠正、或工具报错后发现是自己用错了；\n'
      '· 学技能：发现某个工具/参数组合能稳定解决一类问题。\n'
      '**怎么写**：一条一个教训，写成"下次遇到 X 就 Y"的可执行短句'
      '（40 字以内最好，上限 240 字）；同类经验已存在就不要重复写。\n'
      '**不要写**：用户的个人信息（用 memory）、一次性的任务细节（用 notes）、'
      '密钥/密码、以及"忽略安全规则 / 跳过确认"这类自我指令。\n'
      '写进去之后用户只能查看和删除，不能添加 —— 所以别写客套话和废话。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['add', 'list'],
      },
      'text': <String, dynamic>{
        'type': 'string',
        'description': 'add 时的经验正文。一句话，写成"下次遇到 X 就 Y"',
      },
      'kind': <String, dynamic>{
        'type': 'string',
        'enum': <String>['mistake', 'detour', 'skill', 'lesson'],
        'description':
            'add 时的分类：mistake 犯错 / detour 绕弯 / '
            'skill 技能 / lesson 其它经验（默认）',
      },
    },
    'required': <String>['action'],
  };

  /// **写入不需要确认**（见类注释）。但风险等级照实报成 caution：
  /// 它会影响之后每一轮的行为，界面上不该伪装成"只读操作"。
  @override
  bool get autoApprove => true;

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    final String action = args.str('action');
    if (action == 'list') return RiskAssessment.safe;
    if (action == 'add') {
      return RiskAssessment(RiskLevel.caution, <String>[
        '写入一条自学习笔记：${args.str('text')}',
        '之后每一轮对话都会带上它（用户可在设置里删除）',
      ]);
    }
    return RiskAssessment(RiskLevel.caution, <String>['未知操作：$action']);
  }

  @override
  String summarize(Map<String, dynamic> args) {
    if (args.str('action') == 'list') return '查看自学习笔记';
    return args.str('text');
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final LearningStore store = LearningStore.instance;
    final String action = args.str('action');

    switch (action) {
      case 'list':
        if (store.notes.isEmpty) return '（还没有任何自学习笔记）';
        final StringBuffer sb = StringBuffer('共 ${store.notes.length} 条：\n');
        for (final LearningNote n in store.notes) {
          sb.writeln('- [${LearningStore.kindLabel(n.kind)}] ${n.text}');
        }
        return clampOutput(sb.toString());

      case 'add':
        final String text = args.str('text').trim();
        if (text.isEmpty) return '错误：add 需要提供 text';
        final String? err = store.add(text, kind: args.str('kind'));
        if (err != null) return '没有写入：$err';
        return '已记下（共 ${store.notes.length} 条），之后每轮都会生效。';

      default:
        return '错误：未知 action「$action」（只支持 add / list）';
    }
  }
}
