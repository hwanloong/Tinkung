import '../core/models.dart';
import 'tool.dart';

/// **multibot**：主模型一次派出若干子智能体，各自干一件事，并行跑完再汇总。
///
/// ## 它解决什么
///
/// 有些活是"几件彼此独立的事"：查三家的价格、核对五个文件、分别搜三个
/// 关键词。让主模型自己一件件串行做，既慢又会把主上下文撑得很大。
/// 派出去之后，每个子智能体在**自己的临时会话**里做，主模型只拿到
/// 每个子任务的结论 —— 中间的工具输出不回灌。
///
/// ## 子智能体能做什么
///
/// 它和主模型用**同一套工具**（读写文件、联网、Python…），因为它要真的干活。
/// 唯一被拿掉的是 `multibot` 自己（见 `AgentRunner._dispatchSubAgents`），
/// 防止子智能体再派下一层。
///
/// ## 风险
///
/// 派出去本身不改任何东西，所以派发是 `safe`。子智能体里真正会改东西的
/// 工具仍然各自走自己的风险分级；后台没有界面，危险操作在子智能体里一律拒绝。
class MultibotTool extends AgentTool {
  const MultibotTool();

  @override
  String get name => 'multibot';

  @override
  String get title => '子智能体';

  @override
  String get description =>
      '把几件**彼此独立**的事派给多个子智能体并行去做，全部完成后汇总结论。\n'
      '\n'
      '**什么时候用**：任务能拆成 2 件以上互不依赖的具体工作（比如分别查三家的价格、'
      '分别核对几个文件、分别搜几个关键词）。有先后依赖的不要用，那种用你自己一步步做。\n'
      '\n'
      '参数 `tasks`：数组，每项 `{label, task}`。\n'
      '· `label` —— 简短名字，用来区分结果（"A 公司价格""文件 b 的校验"）。\n'
      '· `task` —— 交给它的**完整**任务。子智能体看不到主对话，所以要把背景、'
      '目标、要的产出都写进去，不要写"按刚才说的做"。\n'
      '\n'
      '子智能体和你用同一套工具，但不能再派子智能体。'
      '派出去的活它们是并行做的；你拿到的是每一件的结论，再由你汇总回答用户。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'tasks': <String, dynamic>{
        'type': 'array',
        'description': '要派出去的子任务列表（至少一项）',
        'items': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'label': <String, dynamic>{
              'type': 'string',
              'description': '简短名字，用于区分结果',
            },
            'task': <String, dynamic>{
              'type': 'string',
              'description': '完整的任务描述（子智能体看不到主对话）',
            },
          },
          'required': <String>['task'],
        },
      },
    },
    'required': <String>['tasks'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) =>
      const RiskAssessment(RiskLevel.safe, <String>[]);

  @override
  String summarize(Map<String, dynamic> args) {
    final dynamic raw = args['tasks'];
    final int n = raw is List ? raw.length : 0;
    return '派出 $n 个子智能体';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final Future<List<SubAgentResult>> Function(List<SubAgentSpec> specs)?
        dispatch = ctx.dispatchSubAgents;
    if (dispatch == null) {
      // 子智能体自己拿不到派发回调 —— 走到这里说明它在尝试套娃。
      return '错误：子智能体不能再派子智能体。请你自己把这件事做完，'
          '或者直接说明做不了的部分。';
    }

    final dynamic raw = args['tasks'];
    if (raw is! List || raw.isEmpty) {
      return '错误：tasks 需要是非空数组，每项至少有 task。';
    }

    final List<SubAgentSpec> specs = <SubAgentSpec>[];
    for (final dynamic e in raw) {
      if (e is! Map) continue;
      final String task = (e['task']?.toString() ?? '').trim();
      if (task.isEmpty) continue;
      final String label = (e['label']?.toString() ?? '').trim();
      specs.add(
        SubAgentSpec(
          label: label.isEmpty ? '子任务${specs.length + 1}' : label,
          task: task,
        ),
      );
    }
    if (specs.isEmpty) {
      return '错误：没有一条带 task 的合法子任务。';
    }
    // 上限：派得太多会同时开太多请求，也说明任务拆得太碎了。
    if (specs.length > 8) {
      return '错误：一次最多派 8 个子智能体（你给了 ${specs.length} 个）。'
          '请合并成更大的几件事再派。';
    }

    final List<SubAgentResult> results = await dispatch(specs);

    final StringBuffer sb = StringBuffer();
    final int okCount = results.where((SubAgentResult r) => r.ok).length;
    sb.writeln('已派出 ${results.length} 个子智能体，完成 $okCount 个：');
    for (final SubAgentResult r in results) {
      sb.writeln();
      sb.writeln('## ${r.ok ? '✓' : '✗'} ${r.label}');
      if (r.ok) {
        sb.writeln(r.answer.trim());
      } else {
        sb.writeln('（没有完成）${r.error.isNotEmpty ? r.error : r.answer}');
      }
    }
    sb.writeln();
    sb.writeln('请基于以上结论汇总回答用户；没完成的那部分要如实说明。');
    return sb.toString();
  }
}
