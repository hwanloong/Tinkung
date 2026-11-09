import 'package:flutter/material.dart';

import '../core/ids.dart';
import '../core/model_profile.dart';
import '../core/store.dart';
import '../theme/app_theme.dart';
import 'anchored_card.dart';
import 'ios_switch.dart';
import 'relay_import_page.dart';
import 'widgets.dart';

/// 打开模型选择面板。返回选中的档案 id（用户没选就是 null）。
///
/// 这是「在聊天界面顺手切换模型」的落点：对话页输入框里的模型胶囊点一下
/// 就到这里。面板里能直接切换，也能进「管理模型」去增删改 ——
/// 两步操作共用同一个面板，用户不用先想"我要的是切换还是配置"。
Future<String?> showModelPicker(
  BuildContext context, {
  required Settings settings,
  Rect? anchor,
  Rect Function()? anchorBuilder,
  CardAlign align = CardAlign.right,
}) {
  // ---- 锚定的玻璃小卡片，不是半屏 ----
  //
  // 用户明确要的是"卡片"：从触发它的按钮旁边长出来，而不是从屏幕底下抬起
  // 半个屏幕。调用方传入锚点（通常是模型按钮的矩形）；没有锚点就退回到
  // 屏幕右下方一个合理位置。
  return showAnchoredCard<String>(
    context,
    anchor: anchor,
    anchorBuilder: anchorBuilder ??
        (anchor == null
            ? () => Rect.fromLTWH(
                  MediaQuery.sizeOf(context).width - 56,
                  MediaQuery.sizeOf(context).height - 160,
                  40,
                  40,
                )
            : null),
    width: 260,
    align: align,
    builder: (BuildContext ctx) => _ModelPickerSheet(settings: settings),
  );
}

/// 打开**模型参数**面板：温度 / 思考深度 / 工具调用上限。
///
/// ## 为什么这些参数从「+」面板搬到这里
///
/// 它们从前在「+」→「模型设置」标签下面。搬过来的理由：
/// 调温度是"我这句想问得更发散还是更严谨"的**即时**决定，
/// 和"我现在要发什么"是同一刻发生的。藏在「+」里要两步才能到，
/// 用户会干脆不调 —— 而它恰恰是最该随手能拧的一个旋钮。
Future<void> showModelParams(
  BuildContext context, {
  required Settings settings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext _) => _ModelParamsSheet(settings: settings),
  );
}

/// 思考深度在滑杆上的位置：0 = 关闭，1/2/3 = 浅/深/最深。
///
/// 后端只有 `low` / `high` / `max` 三个值，而"关闭"是另一个开关
/// （`thinkingEnabled`），所以要多一次映射。做成滑杆而不是四个按钮：
/// 用户脑子里想的是"深一点"，不是一个枚举值。
int modelEffortLevel(Settings set) {
  if (!set.thinkingEnabled) return 0;
  return switch (set.reasoningEffort) {
    'low' => 1,
    'max' => 3,
    _ => 2,
  };
}

/// 滑杆上四档的名字。**英文** —— 和选择器上显示的深度用同一套词，
/// 用户在两处看到的是同一个标签，不会觉得是两件事。
const List<String> kEffortNames = <String>['Off', 'Easy', 'Deep', 'Max'];

/// 思考强度的**单档短名**，用于"模型 + 深度"拼在一起显示。
///
/// 为什么单独一套而不是复用 [kEffortNames]：那里是**给滑杆用的**，
/// 带括号解释 —— 拼到模型名后面会又长又碎。这里只要一个词。
///
/// 三档用 `Easy / Deep / Max`（**英文，不翻译**）：
///  · 它们是各家的通用档位名（DeepSeek 的 `reasoning_effort` 取值就是
///    low/high/max，OpenAI 也是 low/medium/high），用户在其他工具里见过；
///  · 要贴在模型名后面当一个短标签，**必须一眼可辨** ——
///    "深"和"最深"只差一个字，扫一眼分不出来。
const List<String> kEffortShort = <String>['', 'Easy', 'Deep', 'Max'];

/// 模型名 + 思考深度，例如 `DeepSeek Max`。
///
/// 用在模型选择器上：换模型和调深度是**同一件事的两个旋钮**
/// （都决定"这次谁来答、想多深"），分开显示的话用户得看两个地方
/// 才知道现在的状态。
///
/// 关闭思考时只返回模型名 —— 那时深度没有意义，标出来是噪声。
String modelWithEffort(Settings set) {
  final String name = set.activeProfile?.displayName ?? 'no model';
  final int level = modelEffortLevel(set);
  if (level <= 0) return name;
  final String tag = kEffortShort[level.clamp(0, kEffortShort.length - 1)];
  return tag.isEmpty ? name : '$name $tag';
}

/// 只取思考深度那一档的词（`Easy` / `Deep` / `Max`）。关闭思考时返回空串。
///
/// 选择器把模型名和深度**分开画**（名字用强调色、深度用灰色粗体），
/// 所以需要单独拿到这一段；[modelWithEffort] 是给"拼接成一行"的场景用的。
String effortTagOf(Settings set) {
  final int level = modelEffortLevel(set);
  if (level <= 0) return '';
  return kEffortShort[level.clamp(0, kEffortShort.length - 1)];
}

/// 把滑杆位置写回设置。
void applyEffortLevel(Settings set, int level) {
  if (level <= 0) {
    set.thinkingEnabled = false;
    return;
  }
  set.thinkingEnabled = true;
  set.reasoningEffort = <String>['low', 'low', 'high', 'max'][level];
}

class _ModelParamsSheet extends StatefulWidget {
  const _ModelParamsSheet({required this.settings});

  final Settings settings;

  @override
  State<_ModelParamsSheet> createState() => _ModelParamsSheetState();
}

class _ModelParamsSheetState extends State<_ModelParamsSheet> {
  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final Settings set = widget.settings;

    void save(void Function() mutate) {
      set.update(mutate);
      // 只重建这个面板：参数写回 `Settings` 后，输入框上方的模型选择器
      // 不需要跟着变（它显示的是模型名，不是参数）。
      setState(() {});
    }

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '模型参数',
                    style: AppFonts.body(
                      size: 17,
                      weight: FontWeight.w600,
                      color: s.text,
                      height: 1.2,
                    ),
                  ),
                ),
                Text(
                  set.model,
                  style: AppFonts.code(size: 11.5, color: s.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '这些参数跟着**当前模型**存，换模型就换成它自己那套。',
                style: AppFonts.body(size: 11.6, color: s.muted, height: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // 思考深度滑杆**搬到了"选择模型"面板**（就在模型列表上方）——
          // 换模型和调深度是同一个决策（"谁来答、想多深"），
          // 分在两个面板里意味着每换一次模型都要进出两层。
          // 这里不再重复放一个。
          _row(s, '温度', set.temperature.toStringAsFixed(1)),
          Slider(
            value: set.temperature.clamp(0.0, 2.0),
            min: 0,
            max: 2,
            divisions: 20,
            label: set.temperature.toStringAsFixed(1),
            onChanged: (double v) => save(() => set.temperature = v),
          ),
          _hint(
            s,
            '越低越稳定保守，越高越发散有创意。'
            // 这条必须说清楚，否则用户会觉得"调了没用"
            '⚠️ **思考模式开启时这个值不生效** —— 官方说明"设置不报错但也不生效"，'
            '想要它起作用先把思考深度调到关闭。',
          ),

          const SizedBox(height: 10),
          _row(s, '工具调用上限', '${set.maxToolRounds} 次'),
          Slider(
            value: set.maxToolRounds.toDouble().clamp(1, 100),
            min: 1,
            max: 100,
            divisions: 99,
            label: '${set.maxToolRounds}',
            onChanged: (double v) => save(() => set.maxToolRounds = v.round()),
          ),
          // 1~100 的跨度上滑杆很难精确点到某个值（想要 37 时手一滑就 40 了），
          // 所以补 ± 和"常用"。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: <Widget>[
                _step(s, '−', () {
                  if (set.maxToolRounds > 1) {
                    save(() => set.maxToolRounds = set.maxToolRounds - 1);
                  }
                }),
                const SizedBox(width: 8),
                _step(s, '＋', () {
                  if (set.maxToolRounds < 100) {
                    save(() => set.maxToolRounds = set.maxToolRounds + 1);
                  }
                }),
                const Spacer(),
                _step(s, '常用 8', () => save(() => set.maxToolRounds = 8)),
                const SizedBox(width: 8),
                _step(s, '最大 100', () => save(() => set.maxToolRounds = 100)),
              ],
            ),
          ),
          _hint(
            s,
            '一次 = 模型调一次工具。复杂任务（多步搜索、写代码再调试）需要更多次；'
            '调太小会让它做一半就停。',
          ),

          // ---- 描述改进 ----
          //
          // 放在"模型参数"面板里是**因为它也是模型相关的行为**：
          // 它决定"用户的话会不会被先改写一遍再交给模型"，
          // 和思考深度、温度属于同一类东西（都是"怎么对待这次输入"）。
          const SizedBox(height: 14),
          Divider(color: s.border, height: 1),
          const SizedBox(height: 6),
          // `SwitchListTile` 内部画的是一个**写死的** Material 开关，
          // 没有插槽可以换 —— 所以只能拆成 `ListTile` + `trailing`。
          // 整行仍然可以点（`onTap` 补上），行高由 `ListTile` 自己算，
          // 和原来的 `SwitchListTile` 是同一套度量。
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            onTap: () => save(() => set.improvePrompt = !set.improvePrompt),
            trailing: IosSwitch(
              value: set.improvePrompt,
              onChanged: (bool v) => save(() => set.improvePrompt = v),
            ),
            title: Text(
              '描述改进',
              style: AppFonts.body(
                size: 14.5,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
            subtitle: Text(
              '发消息前先让模型把你的话改写成更清楚的任务描述，再交给它执行。'
              '适合"帮我看看那个文件"这类省略了指代的说法。\n'
              '代价：每次多一次往返（一两秒），而且**发出去的是改写版**。'
              '原话仍然完整显示在消息里，改写版折叠在它下面，随时可以核对。',
              style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
            ),
          ),
          // 这条提示**不管开关开着还是关着都要显示**。
          //
          // 原来只在开关打开时给一段说明，于是"想找档位/专用模型/自定义
          // 要求在哪"的人（开关还关着）看到的是一片空白 —— 只能靠翻设置
          // 一页页找。要配置的东西必须在**用户想起它的那一屏**指出位置。
          _hint(
            s,
            '这里只有开关。**怎么改**（力度 低/中/高、换成专用模型、'
            '写自己的改写要求）在「设置 → 模型设置 → 描述改进」。\n'
            '默认用当前模型改写；改写失败（超时、断网、模型不听话）会自动'
            '退回原话，**不会因此发不出消息**。',
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  Widget _row(AppSurface s, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: <Widget>[
          Text(label, style: AppFonts.body(size: 13.5, color: s.text)),
          const Spacer(),
          Text(
            value,
            style: AppFonts.code(size: 12.5, color: AppColors.accent),
          ),
        ],
      ),
    );
  }

  Widget _hint(AppSurface s, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text.replaceAll('**', ''),
        style: AppFonts.body(size: 11, color: s.muted, height: 1.55),
      ),
    ),
  );

  Widget _step(AppSurface s, String label, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: ShapeDecoration(
          color: s.codeBg,
          shape: const StadiumBorder(),
        ),
        child: Text(
          label,
          style: AppFonts.body(
            size: 13,
            weight: FontWeight.w600,
            color: s.text,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

/// 思考强度的单档标签（Easy / Deep / Max），用于列表里的能力标注。
///
/// 和 [kEffortShort] 同一套词 —— 选择器和列表里说的必须是同一个东西，
/// 否则用户会以为它们是两件事。
String thinkingShortOf(ModelProfile p) {
  if (!p.chat || !p.thinking) return '';
  return switch (p.reasoningEffort) {
    'low' => 'Easy',
    'max' => 'Max',
    _ => 'Deep',
  };
}

/// 模型列表里的「模型 + 思考深度」标注，例如 `deepseek-flash · Max`。
///
/// 拼在一起而不是分开两个标签：**深度是模型的一个属性**，
/// 用户看"这个模型现在是什么状态"时是一次查询，不是两次。
String thinkingBadgeOf(ModelProfile p) {
  final String s = thinkingShortOf(p);
  return s.isEmpty ? '' : '思考·$s';
}

/// 模型选择面板：**一屏完成"看 → 切 → 调"**。
///
/// ## 为什么把列表直接铺在面板里
///
/// 之前这里是"模型名 + 强度条"一张卡，点名字再叠一层完整列表。
/// 那个结构的问题是：**换模型**是这个面板最主要的用途，却被藏在一个
/// "名字像是标题"的入口后面 —— 用户点之前不知道它能点。
/// 现在列表就在眼前，点一行即切换并收起；强度条缩成上方一张小卡，
/// 它仍然在，但不再抢走屏幕的大半。
class _ModelPickerSheet extends StatelessWidget {
  const _ModelPickerSheet({required this.settings});

  final Settings settings;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final bool landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // ---- 小列表，不是半屏 ----
    //
    // 面板外层（showModelPicker）已经是一张浮起的玻璃小卡片，并且
    // 负责底部安全区的留白，所以这里只做两件事：高度按内容收缩、
    // 封顶不超过半屏。不再包 `SafeArea`，否则卡片里会多出一截空。
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: sheetMaxHeight(context, landscape ? 0.60 : 0.42),
      ),
      child: AnimatedBuilder(
          animation: settings,
          builder: (BuildContext context, Widget? _) {
            // ---- 过滤掉被隐藏的模型 ----
            //
            // 当前正在用的那个**永远显示**：隐藏它只会让用户
            // "看不到自己在用什么"，而且切不回来。
            final List<ModelProfile> all = settings.profiles;
            final List<ModelProfile> list = <ModelProfile>[
              for (final ModelProfile p in all)
                if (!settings.isProfileHidden(p.id) ||
                    settings.isActive(p.id))
                  p,
            ];
            final int hiddenCount = all.length - list.length;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // ---- 标题行：大标题 + 管理 ----
                //
                // 「管理」留在右上角而不是做成主按钮：进管理页是低频动作，
                // 高频的是下面列表里的那一下点按。
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '模型设置',
                          style: AppFonts.body(
                            size: 17,
                            weight: FontWeight.w600,
                            color: s.text,
                            height: 1.2,
                          ),
                        ),
                      ),
                      // 有被隐藏的模型时给一句提示：否则用户会以为
                      // "我明明绑了五个，怎么只剩两个" —— 真正的原因
                      // 是他自己隐藏过。点「管理」能全部看到并恢复。
                      if (hiddenCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text(
                            '已隐藏 $hiddenCount 个',
                            style: AppFonts.body(size: 11.5, color: s.muted),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (BuildContext _) =>
                                ModelsPage(settings: settings),
                          ),
                        ),
                        icon: const Icon(Icons.tune_rounded, size: 17),
                        label: const Text('管理'),
                      ),
                    ],
                  ),
                ),

                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
                    child: Text(
                      '还没有绑定模型。点下面的「添加模型」绑一个就能开始对话。',
                      style: AppFonts.body(
                        size: 12.6,
                        color: s.muted,
                        height: 1.6,
                      ),
                    ),
                  )
                else
                  // `Flexible` + `shrinkWrap`：条数少时列表按内容高度收缩，
                  // 条数多时在 72% 的封顶内滚动 —— 两种情况下都不留空白。
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                      itemCount: list.length,
                      itemBuilder: (BuildContext ctx, int i) =>
                          _ModelRow(settings: settings, profile: list[i]),
                    ),
                  ),

                Divider(color: s.border, height: 1),
                // 两个**低频**入口并排放在底部：加模型、调参数。
                // 它们不该和列表抢视觉重量，所以用文字按钮而不是填充按钮。
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: Row(
                    children: <Widget>[
                      TextButton.icon(
                        onPressed: () => _add(context),
                        // 不能写 `const`：AppColors.accent 是可变的静态字段
                        // （主题切换时会被改写），const 表达式要它编译期固定。
                        icon: Icon(
                          Icons.add_rounded,
                          size: 18,
                          color: AppColors.accent,
                        ),
                        label: Text(
                          '添加模型',
                          style: AppFonts.body(
                            size: 13.5,
                            weight: FontWeight.w600,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () =>
                            showModelParams(context, settings: settings),
                        icon: Icon(Icons.tune_rounded, size: 17, color: s.muted),
                        label: Text(
                          '模型参数',
                          style: AppFonts.body(size: 13.5, color: s.muted),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
    );
  }

  /// 添加模型。建好之后**带着新 id 关掉本面板** ——
  /// 用户刚绑定一个模型，下一步必然是开始用它，而不是回到列表再点一次。
  Future<void> _add(BuildContext context) async {
    final ModelProfile? created = await openModelEditor(
      context,
      settings: settings,
      existing: null,
    );
    if (created != null && context.mounted) {
      Navigator.of(context).pop(created.id);
    }
  }

  /// 思考强度：**一行标签 + 一条细挡位条**。
  ///
  /// 旧版把模型名放在这张卡的最上面（大字），那是"点它才换模型"时代的
  /// 入口。现在换模型在下面的列表里，卡上再放一次模型名只会和列表
  /// 第一行重复，所以这里只留"在调什么、现在几档"。
 
}

/// 一小颗胶囊标签：管理页的状态/能力、选择器的「仅生图」都用它。
///
/// 抽成一个函数是因为**同一个词在两屏必须长得一样** ——
/// 手动写两遍很容易一处 10.5 号、一处 11 号，看起来就像两套东西。
Widget _pillTag(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
    decoration: ShapeDecoration(
      // 用同色 11% 的底而不是灰底：状态色（橙/黄）在暖纸底上
      // 单靠文字已经够清楚，加一层淡底只是为了把它和正文分开。
      color: color.withValues(alpha: 0.11),
      shape: const StadiumBorder(),
    ),
    child: Text(
      text,
      style: AppFonts.body(
        size: 10.6,
        weight: FontWeight.w600,
        color: color,
        height: 1.2,
      ),
    ),
  );
}

/// 选择器列表里的一行：**名称 + 主机，当前项左侧一根橙色竖条**。
///
/// 选中态只做三件事：3px 竖条、名称换强调色、右侧一个勾。
/// 没有整行铺橙 —— 列表里同时要比较十几行，一块橙色会把
/// 其余行的文字压下去，反而看不出还有什么可选。
class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.settings, required this.profile});

  final Settings settings;
  final ModelProfile profile;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final ModelProfile p = profile;
    final bool active = settings.isActive(p.id);
    final bool simple = settings.modelChipInfo == ModelChipInfo.simple;

    // 第二行跟着「选择器显示多少」这个设置走：
    // 简洁模式只留备注，完整模式给 `模型 · 站名`。
    //
    // **备注在两种模式下都要显示**：用户写备注就是为了在选择时看见它
    // （"便宜，日常问答用"），只在简洁模式里出现等于把完整模式变成了
    // 一张参数表。完整模式下它占第二行，`模型 · 站名` 退到第三行。
    final String note = p.note.trim();
    final String meta = '${p.model} · ${p.host}';
    final String sub = simple ? (note.isEmpty ? p.host : note) : meta;
    final bool showNoteAbove = !simple && note.isNotEmpty;

    return Material(
      color: active
          ? AppColors.accent.withValues(alpha: 0.06)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.field),
        // 点一下就切换并收起。返回值是 id，和 showModelPicker 的签名一致。
        onTap: () {
          settings.selectProfile(p.id);
          Navigator.of(context).pop(p.id);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(7, 9, 10, 9),
          child: Row(
            children: <Widget>[
              // 竖条**始终占位**，非选中时画成透明 ——
              // 否则切换时整行文字会左右跳 3px。
              Container(
                width: 3,
                height: 30,
                decoration: BoxDecoration(
                  color: active ? AppColors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      p.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 14.5,
                        weight: FontWeight.w600,
                        color: active ? AppColors.accent : s.text,
                        height: 1.25,
                      ),
                    ),
                    if (showNoteAbove) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(size: 12, color: s.muted),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: simple
                          ? AppFonts.body(
                              size: 12,
                              color: p.chat ? s.muted : AppColors.warning,
                            )
                          : AppFonts.code(
                              size: 11.5,
                              color: p.chat ? s.muted : AppColors.warning,
                            ),
                    ),
                  ],
                ),
              ),
              // 「仅生图」是这一行里唯一会让人**选错**的信息，
              // 所以贴一个小标签，而不是只靠副标题变色。
              if (!p.chat)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _pillTag('仅生图', AppColors.warning),
                ),
              if (active)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: AppColors.accent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「模型」管理页：绑定多个模型、编辑、删除、切换当前使用的那个。
class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key, required this.settings});

  final Settings settings;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return AnimatedBuilder(
      animation: settings,
      builder: (BuildContext context, Widget? _) {
        return Scaffold(
          backgroundColor: s.pageBg,
          appBar: AppBar(
            title: const Text('模型'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: <Widget>[
              Text(
                '每个模型是一条独立的配置：地址 + 密钥 + 模型名。'
                '对话时可以从输入框上方随时切换，切换只影响之后的请求。'
                '${settings.profiles.length > 1 ? '\n按住右边的 ≡ 可以拖动排序，顺序会保存。' : ''}'
                '\n右上「⋯」里可以**隐藏**不常用的模型：隐藏后它不会出现在'
                '切换列表里，但配置和密钥都还在，随时能从这里恢复。',
                style: AppFonts.body(size: 12.6, color: s.muted, height: 1.6),
              ),
              const SizedBox(height: 16),
              if (settings.profiles.isEmpty)
                Card(
                  color: s.surface,
                  elevation: 0,
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    side: BorderSide(color: s.border),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      '还没有绑定模型。点下面的「添加模型」，'
                      '或从常见服务里一键填入地址。',
                      style: AppFonts.body(
                        size: 13,
                        color: s.muted,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),

              // ---- 可拖动排序的模型列表 ----
              //
              // 用 `ReorderableListView` 的 **shrinkWrap + 不可滚动** 形态，
              // 塞进外面这个 `ListView` 里 —— 页面本身还有说明文字和底部按钮，
              // 不能让它自己滚（两层滚动会互相抢手势）。
              //
              // 拖拽手柄放在**右边**（`buildDefaultDragHandles: false` +
              // 自己的 `ReorderableDragStartListener`）：默认是"长按整行"，
              // 而整行还要响应点按（切换模型）和滑动 —— 三者会打架。
              // 给一个明确的手柄，三种手势互不干扰。
              if (settings.profiles.length > 1)
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: settings.profiles.length,
                  // 用 `onReorderItem` 而不是 `onReorder`：
                  // 后者在 3.41 之后已废弃，而且**索引语义不同** ——
                  // `onReorder` 的 `newIndex` 是"移除之前"的位置（往下拖要减一），
                  // `onReorderItem` 已经帮我们调整好了。
                  // 所以下面传给 store 的是 `insertAt`（语义就是最终位置）。
                  onReorderItem: (int from, int insertAt) => settings.update(
                    () => settings.moveProfile(from, insertAt),
                  ),
                  itemBuilder: (BuildContext ctx, int i) {
                    final ModelProfile p = settings.profiles[i];
                    return Row(
                      key: ValueKey<String>(p.id),
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        Expanded(
                          child: _card(context, s, p),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 2, right: 2),
                            child: Icon(
                              Icons.drag_handle_rounded,
                              size: 22,
                              color: s.muted,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                )
              else
                for (final ModelProfile p in settings.profiles)
                  _card(context, s, p),

              const SizedBox(height: 8),
              // 两个入口**等宽、同一重量**，因为它们是**两种不同的动作**：
              // · 添加模型 = 我知道要用哪个，手工填一条
              // · 批量导入 = 我买了一个中转站，把它的模型全拉下来
              // 合成一个按钮的话，用户得先点进去再选，多一步且意图不清。
              //
              // 用 `OutlinedButton` 而不是一个填充 + 一个 tonal：原来的组合
              // 把「添加」画成了主操作，但这两件事**频率相当**，
              // 一深一浅只是让页面看起来多了一个视觉焦点。
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => openModelEditor(
                        context,
                        settings: settings,
                        existing: null,
                      ),
                      icon: const Icon(Icons.add_rounded, size: 19),
                      label: const Text('添加'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) =>
                              RelayImportPage(settings: settings),
                        ),
                      ),
                      icon: const Icon(Icons.cloud_download_outlined, size: 19),
                      label: const Text('批量导入'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '「批量导入」用于中转站：填地址和 Key，自动把它支持的模型全列出来，'
                '勾选一批一次绑定。',
                style: AppFonts.body(size: 11.6, color: s.muted, height: 1.5),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 一张模型卡。
  ///
  /// ## 四行层次是**从上往下越看越细**
  ///
  /// ```
  /// GPT-4o                    [使用中]      ← 1. 用户认它靠这个（15/w600）
  /// 便宜，日常用                            ← 2. 用户自己写的一句话
  /// gpt-4o · api.xx.com                     ← 3. 配置细节（等宽、次要）
  /// [基础工具] [思考·high]                   ← 4. 影响选择的能力标记
  /// ```
  ///
  /// 这个顺序对应**看这一行时的三个问题**：是哪个、干什么用、配哪了。
  /// 能力标记放最后，因为它是"挑的时候才看"的排除条件，不是第一眼信息。
  ///
  /// 选中态只加一条强调色描边 —— 和选择器里的竖条是同一套语言：
  /// 强调"这一个"，而不是把整张卡涂色。
  Widget _card(BuildContext context, AppSurface s, ModelProfile p) {
    final bool active = settings.isActive(p.id);
    final bool hidden = settings.isProfileHidden(p.id);

    // 能力标记只算一次。原来这段列表在建树时拼了**两遍**
    // （一遍判空、一遍 join），加一项就得改两处 —— 很容易漏。
    final List<String> tags = <String>[
      if (!p.usable) '缺少密钥',
      if (p.basicToolsOnly) '基础工具',
      if (!p.chat) '仅生图',
      if (!p.vision && p.chat) '不支持图像',
      if (thinkingBadgeOf(p).isNotEmpty) thinkingBadgeOf(p),
    ];

    return Card(
      // 隐藏的卡片**整块淡化**：它还在（可以随时恢复），
      // 但一眼能看出"这个不在切换列表里"。
      color: hidden ? s.surface.withValues(alpha: 0.55) : s.surface,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(
          color: active ? AppColors.accent : s.border,
          width: active ? 1.4 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => settings.update(() => settings.selectProfile(p.id)),
        child: Padding(
          // 右边只留 4：卡片右端是一个 32 宽的「⋯」，
          // 再给大内边距会让文字区被压窄。
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // ---- 1. 名称 + 状态胶囊 ----
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            p.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.body(
                              size: 15,
                              weight: FontWeight.w600,
                              color: s.text,
                              height: 1.25,
                            ),
                          ),
                        ),
                        if (active) ...<Widget>[
                          const SizedBox(width: 7),
                          _pillTag('使用中', AppColors.accent),
                        ],
                        if (p.builtinFree) ...<Widget>[
                          const SizedBox(width: 5),
                          _pillTag('免费', AppColors.success),
                        ],
                        if (hidden) ...<Widget>[
                          const SizedBox(width: 5),
                          _pillTag('已隐藏', s.muted),
                        ],
                      ],
                    ),
                    // ---- 2. 备注（有才显示）----
                    //
                    // 备注在管理页也显示 —— 它是用户用来做决策的那句话，
                    // 而这一页正是"决定用哪个"的地方。
                    if (p.note.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        p.note.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 12.2,
                          color: s.text,
                          height: 1.35,
                        ),
                      ),
                    ],
                    // ---- 3. 配置细节 ----
                    const SizedBox(height: 4),
                    Text(
                      '${p.model} · ${p.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.code(size: 11.5, color: s.muted),
                    ),
                    // ---- 4. 能力标签 ----
                    //
                    // 用 `Wrap` 而不是 `join(' · ')`：一行文字里塞四五个标记
                    // 会挤成一条灰线，分不出哪个是哪个；小胶囊可以换行，
                    // 每个标签也都能单独被看见。
                    if (tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: <Widget>[
                          for (final String t in tags)
                            _pillTag(
                              t,
                              switch (t) {
                                '缺少密钥' => AppColors.warning,
                                '仅生图' => AppColors.warning,
                                _ => s.muted,
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              // ---- 操作收进一个「⋯」 ----
              //
              // 每张卡右侧原来挤着编辑、删除两个 48 宽的图标按钮，
              // 四张卡并排看下去就是八颗图标在抢注意力，而这两件事
              // **都不是高频**（正常流程是点卡片切过去，不是天天改配置）。
              // 收成菜单后，每张卡右侧只剩一个窄入口，列表重新以内容为主。
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: Icon(Icons.more_horiz_rounded, size: 20, color: s.muted),
                padding: EdgeInsets.zero,
                splashRadius: 18,
                onSelected: (String v) {
                  if (v == 'edit') {
                    openModelEditor(context, settings: settings, existing: p);
                  } else if (v == 'hide') {
                    settings.update(
                      () => settings.setProfileHidden(p.id, !hidden),
                    );
                  } else if (v == 'delete') {
                    _confirmDelete(context, p);
                  }
                },
                itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'edit',
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: s.muted,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '编辑',
                          style: AppFonts.body(size: 13.5, color: s.text),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'hide',
                    // 当前在用的模型不能隐藏：它本来就会一直显示，
                    // 让它可选只会制造"点了没生效"的错觉。
                    enabled: !active,
                    child: Row(
                      children: <Widget>[
                        Icon(
                          hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                          color: active
                              ? s.muted.withValues(alpha: 0.4)
                              : s.muted,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          hidden ? '显示（切换列表里恢复）' : '隐藏（不出现在切换列表）',
                          style: AppFonts.body(
                            size: 13.5,
                            color: active
                                ? s.muted.withValues(alpha: 0.4)
                                : s.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'delete',
                    // 内置免费模型不能删（删了就回不来了），
                    // 用置灰代替"点了没反应"。
                    enabled: !p.builtinFree,
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: p.builtinFree
                              ? s.muted.withValues(alpha: 0.4)
                              : AppColors.danger,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '删除',
                          style: AppFonts.body(
                            size: 13.5,
                            color: p.builtinFree
                                ? s.muted.withValues(alpha: 0.4)
                                : AppColors.danger,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ModelProfile p) async {
    final bool wasActive = settings.isActive(p.id);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(
          '删除「${p.displayName}」？',
          style: AppFonts.body(size: 16, weight: FontWeight.w600, height: 1.3),
        ),
        content: Text(
          wasActive ? '它正在被使用。删除后会自动切到列表里的第一个模型。' : '只删掉这条配置，不影响对方的服务端。',
          style: AppFonts.body(size: 13.5, height: 1.6),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await settings.update(() => settings.removeProfile(p.id));
  }
}

/// 打开新增 / 编辑模型页面。
///
/// 返回**新建出来的档案**（新增时）；编辑或取消返回 null。
Future<ModelProfile?> openModelEditor(
  BuildContext context, {
  required Settings settings,
  required ModelProfile? existing,
}) {
  return Navigator.of(context).push<ModelProfile>(
    MaterialPageRoute<ModelProfile>(
      builder: (BuildContext _) =>
          _ModelEditorPage(settings: settings, existing: existing),
    ),
  );
}

class _ModelEditorPage extends StatefulWidget {
  const _ModelEditorPage({required this.settings, required this.existing});

  final Settings settings;
  final ModelProfile? existing;

  @override
  State<_ModelEditorPage> createState() => _ModelEditorPageState();
}

class _ModelEditorPageState extends State<_ModelEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _note;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;

  late bool _vision;

  /// 这个模型启用了哪些工具（勾选的工具名）
  late Set<String> _tools;
  late bool _chat;
  late bool _thinking;
  late ThinkingStyle _thinkingStyle;
  late String _effort;
  late int _contextLimit;
  bool _showKey = false;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final ModelProfile? p = widget.existing;
    _name = TextEditingController(text: p?.name ?? '');
    _note = TextEditingController(text: p?.note ?? '');
    _baseUrl = TextEditingController(
      text: p?.baseUrl ?? 'https://api.deepseek.com',
    );
    _apiKey = TextEditingController(text: p?.apiKey ?? '');
    _model = TextEditingController(text: p?.model ?? 'deepseek-flash');
    _vision = p?.vision ?? true;
    // 工具集：编辑已有档案时读它的，新建时用默认。
    // 存成 Set 便于界面上勾选/取消。
    _tools = <String>{...(p?.enabledTools ?? ModelProfile.defaultTools)};
    _chat = p?.chat ?? true;
    _thinking = p?.thinking ?? true;
    _thinkingStyle = p?.thinkingStyle ?? ThinkingStyle.deepseek;
    _effort = p?.reasoningEffort ?? 'high';
    _contextLimit = p?.contextLimit ?? 0;
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  /// 校验：地址和模型名不能空，地址必须是个能解析的 http(s) URL。
  ///
  /// 在这里拦一下比让用户发消息时才看到 400 好得多 ——
  /// 那时候错误信息是服务端给的，"哪里填错了"要回头猜。
  String? _validate() {
    if (_apiKey.text.trim().isEmpty) return '密钥不能为空';
    if (_model.text.trim().isEmpty) return '模型名不能为空';
    final Uri? u = Uri.tryParse(_baseUrl.text.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) {
      return '接口地址要写成完整的网址，例如 https://api.deepseek.com';
    }
    if (u.scheme != 'http' && u.scheme != 'https') {
      return '接口地址只支持 http / https';
    }
    return null;
  }

  Future<void> _save() async {
    final String? err = _validate();
    if (err != null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
      return;
    }

    final ModelProfile? old = widget.existing;

    if (old == null) {
      final ModelProfile created = ModelProfile(
        id: newId(),
        name: _name.text.trim(),
        note: _note.text.trim(),
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
        model: _model.text.trim(),
        vision: _vision,
        tools: _tools.toList(),
        chat: _chat,
        thinking: _thinking,
        thinkingStyle: _thinkingStyle,
        reasoningEffort: _effort,
        contextLimit: _contextLimit,
      );
      await widget.settings.update(() => widget.settings.addProfile(created));
      if (mounted) Navigator.of(context).pop(created);
      return;
    }

    final ModelProfile updated = old.copyWith(
      name: _name.text.trim(),
      note: _note.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
      vision: _vision,
      tools: _tools.toList(),
      chat: _chat,
      thinking: _thinking,
      thinkingStyle: _thinkingStyle,
      reasoningEffort: _effort,
      contextLimit: _contextLimit,
    );
    await widget.settings.update(() => widget.settings.updateProfile(updated));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Scaffold(
      backgroundColor: s.pageBg,
      appBar: AppBar(
        title: Text(_isNew ? '添加模型' : '编辑模型'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: <Widget>[
          TextButton(onPressed: _save, child: const Text('保存')),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: <Widget>[
          if (_isNew) ...<Widget>[
            Text(
              '常见服务（一键填入地址和模型名，密钥自己贴）',
              style: AppFonts.body(
                size: 12.6,
                weight: FontWeight.w600,
                color: s.muted,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final ModelPreset pre in ModelPreset.all)
                  ActionChip(
                    label: Text(pre.label),
                    onPressed: () => setState(() {
                      _baseUrl.text = pre.baseUrl;
                      _model.text = pre.model;
                      _vision = pre.vision;
                      _tools = <String>{...ModelProfile.defaultTools};
                      // 预设里标了"仅生图"的，顺手把对话能力关掉 ——
                      // 这正是这个开关存在的意义（否则用户点完预设
                      // 直接发消息就会撞上那句看不懂的服务端报错）。
                      _chat = pre.chat;
                      if (_name.text.trim().isEmpty) _name.text = pre.label;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
          _field(
            s,
            label: '名称',
            hint: '随便起个好认的名字，比如「家里的 Ollama」',
            controller: _name,
          ),
          _field(
            s,
            label: '备注',
            hint: '选模型时会显示，比如「便宜，日常用」「写代码」「备用站」',
            controller: _note,
          ),
          _field(
            s,
            label: '接口地址',
            hint: 'https://api.deepseek.com',
            controller: _baseUrl,
            mono: true,
          ),
          _field(
            s,
            label: '密钥',
            hint: 'sk-（本地模型随便填一个非空值）',
            controller: _apiKey,
            obscure: !_showKey,
            suffix: IconButton(
              icon: Icon(
                _showKey
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
                color: s.muted,
              ),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
          _field(
            s,
            label: '模型名',
            hint: 'deepseek-flash',
            controller: _model,
            mono: true,
          ),

          // ---- 上下文窗口 ----
          //
          // 这一项**直接影响"什么时候弹压缩提示"**：填小了会频繁弹
          // （烦但无害），填大了会在真正溢出时才发现 —— 而那时的表现是
          // 服务端静默截断开头，模型突然"忘了"用户说过什么，
          // 用户根本联想不到是这里填错了。
          //
          // 所以给几个常见档位点选，而不是让他手填一个数字：
          // 多数人不知道自己的模型是多少，但"我买的是不是 128k"是知道的。
          const SizedBox(height: 12),
          Text(
            '上下文窗口',
            style: AppFonts.body(
              size: 12.8,
              weight: FontWeight.w600,
              color: s.muted,
            ),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final (int, String) opt in const <(int, String)>[
                (0, '自动'),
                (32000, '32k'),
                (128000, '128k'),
                (200000, '200k'),
                (1000000, '1M'),
              ])
                ChoiceChip(
                  label: Text(opt.$2),
                  selected: _contextLimit == opt.$1,
                  onSelected: (_) => setState(() => _contextLimit = opt.$1),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _contextLimit == 0
                ? '「自动」= 按模型名猜（只对 DeepSeek 官方两个型号准）。'
                      '中转站的模型建议手选一个，否则可能差十倍。'
                : '已设为 ${_contextLimit >= 1000000 ? '${_contextLimit ~/ 1000000}M' : '${_contextLimit ~/ 1000}k'} token。'
                      '对话用量到这个值的 85% 时会提示压缩。',
            style: AppFonts.body(size: 11.4, color: s.muted, height: 1.5),
          ),

          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => setState(() => _vision = !_vision),
            trailing: IosSwitch(
              value: _vision,
              onChanged: (bool v) => setState(() => _vision = v),
            ),
            title: Text(
              '支持图像理解',
              style: AppFonts.body(
                size: 14.5,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
            subtitle: Text(
              '关掉之后发图会提示"当前模型不支持图片"，'
              '而不是把图片发出去等 API 报错。',
              style: AppFonts.body(size: 12.2, color: s.muted, height: 1.5),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => setState(() => _chat = !_chat),
            trailing: IosSwitch(
              value: _chat,
              onChanged: (bool v) => setState(() => _chat = v),
            ),
            title: Text(
              '可以对话',
              style: AppFonts.body(
                size: 14.5,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
            subtitle: Text(
              _chat
                  ? '这个模型能用来聊天、调用工具。'
                  : '已标记为**仅生图**：它没有 `/chat/completions` 接口，'
                        '拿它发消息只会得到一句「not supported on chat '
                        'completions endpoint」。选模型时会提示，别选它来聊天。',
              style: AppFonts.body(size: 12.2, color: s.muted, height: 1.5),
            ),
          ),
          // ---- 生图：**不再是这里的开关** ----
          //
          // 这里原来有开关（「生成图片」「生成视频」），挂在档案上，
          // 还兼着"注册时要不要给这个模型 generate_image"的判断。
          // 这个作用是错的层级：生图发的是**另一个模型**
          // （设置里单独填的模型名，配当前档案的地址和密钥），
          // 和"这个对话模型能不能画图"无关。
          //
          // 而且它有很具体的后果：中转站批量导入进来的档案，工具集是
          // **显式的空数组**（见 relay_import_page），于是用户平时聊天
          // 的那些模型一个都调不了 `generate_image` —— 说"画一张图"，
          // 模型回"我没有这个能力"，设置里填好的生图模型名一点用没有。
          // 详见 model_profile.dart 里 `ModelProfile.tools` 的说明。
          const SizedBox(height: 8),
          Text(
            '生图',
            style: AppFonts.body(
              size: 12.8,
              weight: FontWeight.w600,
              color: s.muted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '这是**内置工具，任何模型都能调**，所以这里没有开关：'
            '说"画一张"它就调 `generate_image`。\n'
            '画图**用哪个模型**，在「设置 → 模型设置 → '
            '生图模型名」里填（地址和密钥沿用当前档案）。'
            '留空时工具会回一句"去设置里填模型名"，而不是从模型嘴里消失。',
            style: AppFonts.body(size: 12.2, color: s.muted, height: 1.5),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => setState(() => _thinking = !_thinking),
            trailing: IosSwitch(
              value: _thinking,
              onChanged: (bool v) => setState(() => _thinking = v),
            ),
            title: Text(
              '开启思考模式',
              style: AppFonts.body(
                size: 14.5,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
            subtitle: Text(
              '先输出一段思维链再作答。只对支持的模型有效，'
              '不支持的会忽略这个字段。',
              style: AppFonts.body(size: 12.2, color: s.muted, height: 1.5),
            ),
          ),

          // ---- 「思考」参数的形状：**各家不兼容，必须能选** ----
          //
          // 这不是可选的细节：`thinking` 不在 OpenAI 规范里，是各家自己加的，
          // 而服务端大多**严格校验** `type` —— 传错是直接 400 而不是忽略。
          // 最典型的两个：
          //   · DeepSeek 用 {"type":"enabled"|"disabled"}
          //   · Anthropic 系**只认** {"type":"adaptive"}
          // 之前这里写死了 enabled/disabled，绑 Anthropic 的模型就会一直
          // 报参数不合法，而报错本身不会告诉你该换成什么。
          const SizedBox(height: 4),
          Text(
            '思考参数格式',
            style: AppFonts.body(
              size: 12.8,
              weight: FontWeight.w600,
              color: s.muted,
            ),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final ThinkingStyle st in ThinkingStyle.values)
                ChoiceChip(
                  label: Text(st.label),
                  selected: _thinkingStyle == st,
                  onSelected: (_) => setState(() => _thinkingStyle = st),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _thinkingStyle.hint,
            style: AppFonts.body(size: 11.4, color: s.muted, height: 1.5),
          ),
          if (_thinking) ...<Widget>[
            const SizedBox(height: 8),
            Text('推理强度', style: AppFonts.body(size: 12.8, color: s.muted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final (String, String) e in Settings.effortPresets)
                  ChoiceChip(
                    label: Text(e.$2.split(' · ').first),
                    selected: _effort == e.$1,
                    onSelected: (_) => setState(() => _effort = e.$1),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            child: Text(_isNew ? '绑定这个模型' : '保存修改'),
          ),
        ],
      ),
    );
  }

  Widget _field(
    AppSurface s, {
    required String label,
    required String hint,
    required TextEditingController controller,
    bool obscure = false,
    bool mono = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: AppFonts.body(
              size: 12.8,
              weight: FontWeight.w600,
              color: s.muted,
            ),
          ),
          const SizedBox(height: 7),
          TextField(
            controller: controller,
            obscureText: obscure,
            style: mono
                ? AppFonts.code(size: 13, color: s.text)
                : AppFonts.body(size: 14.5, color: s.text),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: mono
                  ? AppFonts.code(size: 12.5, color: s.muted)
                  : AppFonts.body(size: 13.5, color: s.muted),
              suffixIcon: suffix,
            ),
          ),
        ],
      ),
    );
  }
}

