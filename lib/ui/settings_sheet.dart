import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_info.dart';
import '../core/a11y.dart';
import '../core/agent_doc.dart';
import '../core/background.dart';
import '../core/folder_tool.dart';
import '../core/linux.dart';
import '../core/lock.dart';
import '../core/learning.dart';
import '../core/memory.dart';
import '../knowledge/knowledge_store.dart';
import '../core/model_profile.dart';
import '../core/overlay.dart';
import '../core/productivity.dart';
import '../core/rules.dart';
import '../core/store.dart';
import '../core/web_search.dart';
import '../plugins/plugin.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../tools/browser_tool.dart';
import '../tools/webview_loader.dart';
import 'assistant_mode_page.dart';
import 'agent_md_page.dart';
import 'backup_actions.dart';
import 'home_shell.dart';
import 'ios_switch.dart';
import 'knowledge_page.dart';
import 'learning_page.dart';
import 'mcp_page.dart';
import 'memory_page.dart';
import 'chat_memory_page.dart';
import 'models_sheet.dart';
import 'plugins_sheet.dart';
import 'python_console_page.dart';
import 'remote_page.dart';
import 'rules_page.dart';
import 'storage_sheet.dart';
import 'teenspace_page.dart';
import 'terminal_page.dart';
import 'lock_ui.dart';
import 'tools_page.dart';

/// 打开设置。
///
/// **是独立页面，不是底部面板。**
///
/// 原来是 `showModalBottomSheet`。改成页面有三个理由：
/// · 设置内容很长（外观 / 接口 / 安全 / 联网 / 记忆 / 数据 / 更多），
///   面板被高度上限压着，用户得在一个"只有八成屏高"的框里翻半天。
/// · 面板随时可以被下滑手势误关，而设置里有些操作是**未保存的**
///   （滑块、输入框），关了就得重来。
/// · 页面上有明确的返回按钮，"我进了一个新地方"这件事是清楚的；
///   面板会让人不确定"我是不是还在原来的页面上"。
///
/// 名字保留 `showSettingsSheet` 是为了不动调用点 —— 但它的行为已经是
/// "push 一个页面"。下次有人看到这个名字觉得别扭，可以顺手改成
/// `openSettings`。
Future<void> showSettingsSheet(
  BuildContext context, {
  required Settings settings,
  required String workDir,
  required PluginStore plugins,
  required ConversationStore conversations,
  required NoteStore notes,
  required TaskStore tasks,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext _) => _SettingsSheet(
        settings: settings,
        workDir: workDir,
        plugins: plugins,
        conversations: conversations,
        notes: notes,
        tasks: tasks,
      ),
    ),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.settings,
    required this.workDir,
    required this.plugins,
    required this.conversations,
    required this.notes,
    required this.tasks,
  });

  final Settings settings;
  final String workDir;
  final PluginStore plugins;
  final ConversationStore conversations;
  final NoteStore notes;
  final TaskStore tasks;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet>
    with WidgetsBindingObserver {
  // 地址 / 密钥 / 模型名这三个输入框已经搬到「模型」页面（那边能绑多个模型），
  // 所以这里不再持有它们的 controller —— 留着就会变成一个"改了也不落盘"的
  // 影子输入框，比删掉更糟。
  late final TextEditingController _searchKey;
  late final TextEditingController _visionUrl;
  late final TextEditingController _visionKey;
  late final TextEditingController _visionModel;
  late final TextEditingController _imageGenModel;
  late final TextEditingController _improveModel;
  late final TextEditingController _improveInstruction;

  late double _temperature;
  late int _maxRounds;
  late bool _autoApproveSafe;

  /// 「全部放行」：所有工具都不再弹确认框（由确认框里的「全部运行」打开）。
  late bool _autoApproveAll;

  /// 描述改进力度：low / medium / high
  late String _improveLevel;

  /// 描述改进总开关（和输入框旁模型选择器里那个是**同一个值**）
  late bool _improvePrompt;

  /// 输入建议（图片解析 + 上下文揣测）
  late bool _inputSuggest;
  late String _inputSuggestProfile;
  late int _inputSuggestEffort;

  /// 抓网页用桌面版 UA
  late bool _desktopUa;
  late bool _thinking;
  late String _effort;
  late String _engine;
  late String _searchMode;

  /// 「+」面板里搜索用哪条直连通道（bing-rss / duckduckgo）
  late String _webEngine;

  late bool _useOverlay;

  /// 悬浮窗权限状态；null 表示还没查到
  bool? _canOverlay;

  /// 无障碍服务状态；null 表示还没查到
  bool? _a11yOn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 探测后台保活状态（有没有加入电池优化白名单）。
    // 不 await：它是异步的系统查询，不该拖慢设置页打开。
    BackgroundService.instance.refresh().then((_) {
      if (mounted) setState(() {});
    });

    final Settings s = widget.settings;
    _searchKey = TextEditingController(text: s.searchApiKey);
    _visionUrl = TextEditingController(text: s.visionBaseUrl);
    _visionKey = TextEditingController(text: s.visionApiKey);
    _visionModel = TextEditingController(text: s.visionModel);
    _imageGenModel = TextEditingController(text: s.imageGenModel);
    _improveModel = TextEditingController(text: s.promptImproveModel);
    _improveInstruction = TextEditingController(
      text: s.promptImproveInstruction,
    );
    _temperature = s.temperature;
    _maxRounds = s.maxToolRounds;
    _autoApproveSafe = s.autoApproveSafe;
    _autoApproveAll = s.autoApproveAll;
    _improveLevel = s.promptImproveLevel;
    _improvePrompt = s.improvePrompt;
    _inputSuggest = s.inputSuggestEnabled;
    _inputSuggestProfile = s.inputSuggestProfileId;
    _inputSuggestEffort = s.inputSuggestEffort;
    _desktopUa = s.desktopUa;
    _thinking = s.thinkingEnabled;
    _effort = s.reasoningEffort;
    _engine = s.searchEngine;
    _searchMode = s.webSearchMode;
    _webEngine = s.webSearchEngine;
    _useOverlay = s.useOverlayConfirm;

    OverlayService.canDraw().then((bool v) {
      if (mounted) setState(() => _canOverlay = v);
    });
    A11y.enabled().then((bool v) {
      if (mounted) setState(() => _a11yOn = v);
    });
  }

  /// 从系统无障碍设置页回来时重新查一次。用户在那里要翻好几层，
  /// 不可能靠一个固定延迟猜他什么时候回来。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    A11y.enabled().then((bool v) {
      if (mounted && v != _a11yOn) setState(() => _a11yOn = v);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persist();
    _searchKey.dispose();
    _visionUrl.dispose();
    _visionKey.dispose();
    _visionModel.dispose();
    _imageGenModel.dispose();
    _improveModel.dispose();
    _improveInstruction.dispose();
    super.dispose();
  }

  void _persist() {
    // 退出时统一落盘，避免每敲一个字符就写一次 SharedPreferences。
    // 注意：地址 / 密钥 / 模型名不在这里写 —— 它们属于模型档案，
    // 由「模型」页面自己即时保存，设置页只负责剩下这些散项。
    widget.settings.update(() {
      widget.settings.searchApiKey = _searchKey.text.trim();
      widget.settings.visionBaseUrl = _visionUrl.text.trim();
      widget.settings.visionApiKey = _visionKey.text.trim();
      widget.settings.visionModel = _visionModel.text.trim();
      widget.settings.imageGenModel = _imageGenModel.text.trim();
      widget.settings.promptImproveModel = _improveModel.text.trim();
      widget.settings.promptImproveInstruction = _improveInstruction.text
          .trim();
      widget.settings.promptImproveLevel = _improveLevel;
      widget.settings.improvePrompt = _improvePrompt;
      widget.settings.inputSuggestEnabled = _inputSuggest;
      widget.settings.inputSuggestProfileId = _inputSuggestProfile;
      widget.settings.inputSuggestEffort = _inputSuggestEffort;
      widget.settings.desktopUa = _desktopUa;
      widget.settings.temperature = _temperature;
      widget.settings.maxToolRounds = _maxRounds;
      widget.settings.autoApproveSafe = _autoApproveSafe;
      widget.settings.autoApproveAll = _autoApproveAll;
      widget.settings.thinkingEnabled = _thinking;
      widget.settings.reasoningEffort = _effort;
      widget.settings.searchEngine = _engine;
      widget.settings.webSearchMode = _searchMode;
      widget.settings.webSearchEngine = _webEngine;
      widget.settings.useOverlayConfirm = _useOverlay;
    });
  }

  /// 输入建议用哪个档案：'' = 跟随当前，不打开全局模型选择器。
  Future<void> _pickSuggestProfile() async {
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('建议用的模型'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(''),
            child: const Text('跟随当前聊天模型'),
          ),
          // 隐藏的模型不进这个列表 —— 和输入框旁的模型选择器同一套规则；
          // 但**已经选中**的那个例外（否则当前设置看起来"凭空消失"）。
          for (final ModelProfile p in widget.settings.profiles)
            if (!widget.settings.isProfileHidden(p.id) ||
                p.id == _inputSuggestProfile)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(p.id),
                child: Text(p.displayName),
              ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _inputSuggestProfile = picked);
  }

  String _suggestProfileLabel() {
    if (_inputSuggestProfile.isEmpty) return '跟随当前聊天模型';
    final List<ModelProfile> matches = widget.settings.profiles
        .where((ModelProfile p) => p.id == _inputSuggestProfile)
        .toList();
    return matches.isEmpty ? '档案已删除，将跟随当前模型' : matches.first.displayName;
  }

  /// 字号。
  ///
  /// **字体本身不可选。** 三套字体按用途固定：AI 正文用打包的
  /// Noto Sans SC、代码用 Consolas、界面交互用系统默认字体。
  /// 见 `AppFonts` 的类注释。所以这里只有字号 —— 那是可访问性相关的
  /// 东西（有人就是看不清 15px 的正文），和"用哪款字体"不是一类需求。
  Widget _fontOptions(AppSurface s) {
    return _SettingRow(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // ---- 字号 ----
          Row(
            children: <Widget>[
              Text('字号', style: AppFonts.body(size: 13, color: s.text)),
              const Spacer(),
              // 显示**最终**倍率而不是滑杆值 ——
              // 用户关心的是"实际多大"，不是"我调了多少"
              Text(
                '${(AppFonts.baseScale * widget.settings.fontScale * 100).round()}%',
                style: AppFonts.code(size: 12, color: AppColors.accent),
              ),
            ],
          ),
          Slider(
            value: widget.settings.fontScale,
            min: 0.85,
            max: 1.4,
            divisions: 11,
            label:
                '${(AppFonts.baseScale * widget.settings.fontScale * 100).round()}%',
            onChanged: (double v) =>
                widget.settings.update(() => widget.settings.fontScale = v),
          ),
          Text(
            '所有文字（正文、代码块、表格）会一起缩放。'
            '刻意不用系统的字体大小设置 —— markdown 走 RichText，'
            '它不响应那个设置，会导致正文放大而代码块没放大。',
            style: AppFonts.body(size: 11, color: s.muted, height: 1.5),
          ),

          const SizedBox(height: 14),
          Divider(color: s.border, height: 1),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text('横屏字号', style: AppFonts.body(size: 13, color: s.text)),
              const Spacer(),
              Text(
                '${(AppFonts.baseScale * widget.settings.fontScale * widget.settings.landscapeFontScale * 100).round()}%',
                style: AppFonts.code(size: 12, color: AppColors.accent),
              ),
            ],
          ),
          Slider(
            value: widget.settings.landscapeFontScale,
            min: 0.85,
            max: 1.4,
            divisions: 11,
            label: '${(widget.settings.landscapeFontScale * 100).round()}%',
            onChanged: (double v) => widget.settings.update(
              () => widget.settings.landscapeFontScale = v,
            ),
          ),
          Text(
            '只在横屏时叠加到上面的全局字号；竖屏不受影响。'
            '横屏高度更紧，建议比竖屏小一档。',
            style: AppFonts.body(size: 11, color: s.muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 入口行的**统一行高**。所有入口卡（常用 / 更多 / 子页里的条目）
  /// 都用它，一列扫下来节奏才是平的。
  ///
  /// 用 `minHeight` 而不是固定高度：说明偶尔要折两行，固定 64 会把
  /// 第二行裁掉。单行说明的行正好是 64，两行的自然长高 —— 不会挤，
  /// 也不会出现"这一张比那一张矮两像素"。
  static const double _entryRowHeight = 64;

  /// 入口卡左侧的圆形图标：36×36，accent 12% 底。
  ///
  /// 圆形（不是圆角方块）：目录页的每一行都是"去另一个地方"，
  /// 圆形读起来是"入口"，方块读起来是"文件夹"—— 工具页才用方块。
  Widget _entryIcon(IconData icon, {Color? color}) {
    final Color fg = color ?? AppColors.accent;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Center(child: Icon(icon, size: 19, color: fg)),
    );
  }

  /// 入口条目：**纯文字 + 右箭头**。
  ///
  /// ## 为什么去掉了左侧的圆形图标
  ///
  /// 参考图（微信设置页）里每一行只有一行字和一枚 chevron —— 没有图标、
  /// 没有底色。那样做的好处很实在：一屏十几行读下来是一条**等宽的
  /// 文字列**，眼睛扫得动；而每行前面顶一个彩色圆点，视线会被那一列
  /// 彩点牵着走，反而比读字慢。
  ///
  /// 图标参数仍然保留在签名里（调用点太多，一个个删是没必要的风险），
  /// 但**不再渲染** —— 需要恢复时改这一处就行。
  Widget _entryCard(
    AppSurface s, {
    // 图标不再渲染（见上），但参数保留以免动 29 个调用点。
    // ignore: unused_element_parameter
    required IconData icon,
    required String title,
    required String desc,
    required VoidCallback onTap,

    /// 右侧的一句当前值（比如"现在用的是哪个模型"）。
    /// 有它就不用点进去确认状态。
    String? trailingText,
  }) {
    return _SettingRow(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _entryRowHeight),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 15.5,
                        weight: FontWeight.w400,
                        color: s.text,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if ((trailingText ?? '').trim().isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 84),
                  child: Text(
                    trailingText!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: AppFonts.body(size: 13, color: s.muted),
                  ),
                ),
              ],
              const SizedBox(width: 2),
              Icon(Icons.chevron_right_rounded, size: 20, color: s.muted),
            ],
          ),
        ),
      );
  }

  /// 后台保活：前台服务 + 电池优化白名单。
  ///
  /// 两件事放一张卡里，因为它们是**互补**的：
  /// 前台服务挡内存回收，白名单挡 Doze 挂起 CPU。
  /// 分开说用户会以为做一件就够了。
  Widget _bgCard(AppSurface s) {
    final BgStatus st = BackgroundService.instance.status;
    final bool ok = st.batteryIgnored;

    return _SettingRow(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  ok
                      ? Icons.battery_saver_rounded
                      : Icons.battery_alert_outlined,
                  size: 18,
                  color: ok ? AppColors.success : AppColors.warning,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '后台保活',
                    style: AppFonts.body(
                      size: 14,
                      weight: FontWeight.w600,
                      color: s.text,
                      height: 1.3,
                    ),
                  ),
                ),
                Text(
                  ok ? '已加入白名单' : '未加入',
                  style: AppFonts.body(
                    size: 12,
                    color: ok ? AppColors.success : AppColors.warning,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            mdText(
              // 说清"两件事"和"仍不保证"，否则用户会以为开了就一定跑完
              '前台服务挡得住内存回收，但挡不住 Doze（打盹时挂起 CPU、断网），'
              '所以还需要把它加入电池优化白名单。\n\n'
              '⚠️ 部分国产 ROM 有更激进的省电策略，做这两件事**显著提高**长任务存活率，'
              '但不保证一定跑完 —— 所以长任务（编译等）仍建议把输出写进日志文件，'
              '之后回来读，而不是挂着干等。',
              style: AppFonts.body(size: 11.5, color: s.muted, height: 1.6),
            ),
            if (!ok) ...<Widget>[
              const SizedBox(height: 10),
              GlassButton(
                label: '去申请（跳系统弹窗）',
                icon: Icons.open_in_new_rounded,
                fontSize: 12.5,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                onTap: () async {
                  await BackgroundService.instance.requestBattery();
                  // 用户可能在系统弹窗里操作完才回来，延迟一点再刷新，
                  // 免得刚跳过去就查、拿到还是旧状态
                  await Future<void>.delayed(const Duration(seconds: 1));
                  await BackgroundService.instance.refresh();
                  if (mounted) setState(() {});
                },
              ),
            ],
          ],
        ),
      );
  }

  /// 悬浮窗确认开关 + 权限状态
  Widget _overlayRow(AppSurface s) {
    final bool granted = _canOverlay == true;
    final bool unknown = _canOverlay == null;

    return _SettingRow(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '悬浮窗确认',
                      style: AppFonts.body(
                        size: 14,
                        weight: FontWeight.w600,
                        color: s.text,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '工具经常会把别的应用切到前台（打开应用、跳系统设置页等），'
                      '这时应用内弹窗会被盖住，你必须切回来才能点确认。'
                      '开启后改用系统悬浮窗，它始终在最上层。',
                      style: AppFonts.body(
                        size: 12.3,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              IosSwitch(
                value: _useOverlay,
                onChanged: (bool v) => setState(() => _useOverlay = v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Icon(
                granted
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                size: 15,
                color: granted ? AppColors.success : AppColors.warning,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  unknown
                      ? '正在检查权限'
                      : granted
                      ? '已获得「显示在其他应用上层」权限'
                      : '尚未获得悬浮窗权限，目前会退回应用内弹窗',
                  style: AppFonts.body(
                    size: 12.2,
                    color: granted ? AppColors.success : s.muted,
                    height: 1.45,
                  ),
                ),
              ),
              if (!granted && !unknown)
                GlassButton(
                  label: '去授权',
                  accent: true,
                  fontSize: 12.5,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  onTap: () async {
                    await OverlayService.requestPermission();
                    // 用户从系统设置页回来后重新查一次
                    final bool v = await OverlayService.canDraw();
                    if (mounted) setState(() => _canOverlay = v);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 无障碍服务：控件树、语义点击、连续手势都靠它。
  Widget _a11yRow(AppSurface s) {
    final bool on = _a11yOn == true;
    final bool unknown = _a11yOn == null;
    return _SettingRow(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                on ? Icons.touch_app_rounded : Icons.touch_app_outlined,
                size: 19,
                color: on ? AppColors.success : s.muted,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '手机控制（无障碍）',
                      style: AppFonts.body(
                        size: 14,
                        weight: FontWeight.w600,
                        color: s.text,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '让 AI 读取当前界面的控件结构，按名称点击/输入，'
                      '并支持一次手势连续滑动和绘制。不开启时仍可用截图方案，'
                      '但只能看图猜坐标。',
                      style: AppFonts.body(
                        size: 12.3,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Icon(
                on ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                size: 15,
                color: on ? AppColors.success : AppColors.warning,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  unknown
                      ? '正在检查'
                      : on
                      ? '已开启，语义操作可用'
                      : '未开启，目前只能截图猜坐标',
                  style: AppFonts.body(
                    size: 12.2,
                    color: on ? AppColors.success : s.muted,
                    height: 1.45,
                  ),
                ),
              ),
              GlassButton(
                label: on ? '系统设置' : '去开启',
                accent: !on,
                fontSize: 12.5,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                onTap: () async {
                  await A11y.openSettings();
                  await Future<void>.delayed(const Duration(seconds: 1));
                  final bool v = await A11y.enabled();
                  if (mounted) setState(() => _a11yOn = v);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 当前模型入口：显示"现在用的是哪个"，点进去是「模型」页面。
  ///
  /// 为什么这里只留一张卡而不是把配置塞回来：模型档案是**一对多**的，
  /// 而设置页原来的三个输入框（地址 / 密钥 / 模型名）在结构上只装得下
  /// 一个模型 —— 想加第二个就得再加三个框，页面会先垮掉。
  ///
  /// 用 AnimatedBuilder 而不是 setState：切换模型发生在别的页面，
  /// 回到这里时本 State 不一定会重建；直接监听 Settings（它是
  /// ChangeNotifier）才能保证卡片上的名字永远是当前生效的那个。
  Widget _modelCard(AppSurface s) {
    return AnimatedBuilder(
      animation: widget.settings,
      builder: (BuildContext context, Widget? _) {
        final ModelProfile? p = widget.settings.activeProfile;
        // 没绑定 / 绑了但填不全（缺密钥或模型名）都算"还不能用"，
        // 用警告色提示 —— 这两种情况用户看到的现象是一样的：发不出消息。
        final bool ready = p != null && p.usable;

        return _SettingRow(
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext _) =>
                    ModelsPage(settings: widget.settings),
              ),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _entryRowHeight),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  // 和目录里的入口卡同一套图标规格；没绑好模型时整块
                  // 用警告色 —— 底色也跟着换，一眼看得出"这条还不通"。
                  _entryIcon(
                    ready
                        ? Icons.smart_toy_outlined
                        : Icons.error_outline_rounded,
                    color: ready ? AppColors.accent : AppColors.warning,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          ready ? p.displayName : '还没有绑定模型',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.body(
                            size: 15,
                            weight: FontWeight.w600,
                            color: s.text,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          ready ? '${p.model} · ${p.host}' : '点这里绑定第一个模型',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.body(
                            size: 12.5,
                            color: s.muted,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right_rounded, size: 20, color: s.muted),
                ],
              ),
            ),
          );
      },
    );
  }

  /// 复杂设置的折叠状态。默认收起：新手只需要看到常用项。
  bool _uiAdvancedOpen = false;
  bool _modelImageOpen = false;
  bool _modelImproveOpen = false;
  bool _modelSuggestOpen = false;
  bool _modelRoundsOpen = false;
  bool _netAdvancedOpen = false;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    // ---- 单页平铺，**没有分类目录这一层** ----
    //
    // 这里原来是"目录 → 分类"的两级结构：首屏五个入口卡，点进去才看到
    // 那一类的具体设置项。结果是**每次改一个开关都要点两下**，
    // 而且在目录页上根本看不出"我到底有哪些设置"。
    //
    // 现在所有区块按"先常用、后进阶"的顺序排在同一页里，一路往下滑就是
    // 全部设置。类与类之间用一条小节标题分隔（[_section]），
    // 那就是唯一的层级 —— iOS 的设置页本来也是这样：一个长列表，
    // 靠分组标题断开，而不是先让你选分类。
    final Widget content = ListView(
      key: const PageStorageKey<String>('settings'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: <Widget>[
                // ---- 外观与字号 ----
                ...[
                  // 「工作方式」放在**字号之前**：
                  //  · 它决定的是 AI 怎么说话、怎么动手，比字号重，
                  //    排在外观项的最前面，进这一栏第一眼就能看到；
                  //  · 但也不单独开一栏 —— 它只改三选一，撑不起一个
                  //    分类目录（首页的分类是给"一大块设置"用的）。
                  // 右侧直接写当前值，"我现在是什么模式"不用点进去看。
                  _entryCard(
                    s,
                    icon: Icons.tune_rounded,
                    title: '工作方式',
                    desc: '学生 / 日常 / 程序员：决定 AI 怎么解释、怎么动手',
                    trailingText: AssistantModePage.labelOf(
                      widget.settings.assistantMode,
                    ),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              AssistantModePage(settings: widget.settings),
                        ),
                      );
                      // 回来要刷新：右侧那句当前值是从 settings 读的，
                      // 不清一次 setState 就会一直显示进来之前的旧模式。
                      if (mounted) setState(() {});
                    },
                  ),
                  _note(s, '界面配色是固定的；字号影响所有文字。'),
                  _section(s, '字号'),
                  _fontOptions(s),

                  // ---- 模型列表显示多少信息：进阶项，默认收起 ----
                  _foldHeader(
                    s,
                    title: '模型列表显示',
                    icon: Icons.view_list_outlined,
                    desc: '不确定就用默认。影响模型选择列表里显示多少说明',
                    open: _uiAdvancedOpen,
                    onTap: () =>
                        setState(() => _uiAdvancedOpen = !_uiAdvancedOpen),
                  ),
                  if (_uiAdvancedOpen) ...<Widget>[
                    for (final (String, String) opt in ModelChipInfo.options)
                      _SettingRow(
                          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
                          borderColor: widget.settings.modelChipInfo == opt.$1
                              ? AppColors.accent
                              : null,
                          onTap: () {
                            widget.settings.modelChipInfo = opt.$1;
                            setState(() {});
                          },
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  opt.$2,
                                  style: AppFonts.body(
                                    size: 13,
                                    color: s.text,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                              if (widget.settings.modelChipInfo == opt.$1)
                                Icon(
                                  Icons.check_rounded,
                                  size: 18,
                                  color: AppColors.accent,
                                ),
                            ],
                          ),
                        ),
                  ],
                ],

                // ---- 模型设置 ----
                ...<Widget>[
                  _note(
                    s,
                    '先选在用的模型。下面的「思考」决定回答的深浅，'
                    '其余选项保持默认就能用。',
                  ),
                  _section(s, '模型'),
                  // 模型的配置（地址 / 密钥 / 模型名 / 能力 / 工具）
                  // 已经整块搬到「模型」页面：那里能绑定多个模型并随时切换，
                  // 而设置页里那三个输入框在结构上只装得下一个模型。
                  //
                  // 这里保留的是**入口 + 当前状态**：用户进设置想干的事
                  // 通常就是"看看现在用的哪个 / 去改一下"。
                  _modelCard(s),

                  // 思考模式并入「接口与模型」—— 它也是"怎么用模型"的一部分，
                  // 单独一节会让设置页看起来比实际复杂
                  _switchRow(
                    s,
                    label: '开启思考模式',
                    desc:
                        '模型先输出一段思维链再作答。DeepSeek 默认开启。'
                        '注意：思考模式下 temperature、presence_penalty、'
                        'frequency_penalty 均不生效（官方说明「设置不报错但也不生效」）。',
                    value: _thinking,
                    onChanged: (bool v) => setState(() => _thinking = v),
                  ),
                  if (_thinking) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      '推理强度',
                      style: AppFonts.body(
                        size: 12.8,
                        color: s.muted,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...Settings.effortPresets.map(((String, String) e) {
                      final bool active = _effort == e.$1;
                      return _SettingRow(
                          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
                          borderColor: active ? AppColors.accent : null,
                          onTap: () => setState(() => _effort = e.$1),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  e.$2,
                                  style: AppFonts.body(
                                    size: 13,
                                    color: s.text,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                              Text(
                                e.$1,
                                style: AppFonts.code(size: 12, color: s.muted),
                              ),
                              if (active) ...<Widget>[
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.check_circle_rounded,
                                  size: 17,
                                  color: AppColors.accent,
                                ),
                              ],
                            ],
                          ),
                        );
                    }),
                    Text(
                      '官方映射：minimal/low → low，medium/high/xhigh → high，max/ultra → max。',
                      style: AppFonts.body(
                        size: 11.6,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                  ],

                  const SizedBox(height: 14),
                  _slider(
                    s,
                    label: '温度${_thinking ? '（思考模式下不生效）' : ''}',
                    value: _temperature,
                    min: 0,
                    max: 2,
                    divisions: 20,
                    display: _temperature.toStringAsFixed(1),
                    enabled: !_thinking,
                    onChanged: (double v) => setState(() => _temperature = v),
                  ),
                  _foldHeader(
                    s,
                    title: '生图',
                    icon: Icons.auto_awesome_outlined,
                    desc: '想让它画图时再填，留空就是不启用',
                    open: _modelImageOpen,
                    onTap: () =>
                        setState(() => _modelImageOpen = !_modelImageOpen),
                  ),
                  if (_modelImageOpen) ...<Widget>[
                    // ---- 生图：只剩"用哪个模型名"这一项 ----
                    //
                    // 生图是**内置工具**（`generate_image`），所有模型都能调，
                    // 不用在档案上开什么。这里只回答"发给哪个模型"——
                    // 因为一个中转站常常一条档案、多个模型：地址和 Key 相同，
                    // 对话用 `gpt-4o`、画图用 `gpt-image-2`。
                    //
                    // 地址和密钥不在这里配：档案里已经有，再选一遍是重复劳动。
                    const SizedBox(height: 16),
                    _field(
                      s,
                      label: '生图模型名（留空 = 不启用生图）',
                      controller: _imageGenModel,
                      hint: 'gpt-image-2 / dall-e-3 / flux-schnell ',
                    ),
                    _note(
                      s,
                      '走**标准**的 `POST {地址}/images/generations`（OpenAI 规范，'
                      'DALL·E / gpt-image / FLUX / Kolors 都是这个形状），'
                      '用**当前模型档案**的地址和密钥。\n'
                      '工具本身**不用再开**：所有模型都能调 `generate_image`，'
                      '填了模型名它就生效。\n'
                      '尺寸不发 —— 各家支持的值不同，填错是 400，'
                      '交给服务端按模型自己决定。',
                    ),
                  ],
                  _foldHeader(
                    s,
                    title: '描述改进',
                    icon: Icons.auto_fix_high_outlined,
                    desc: '发消息前先把话改写清楚；不确定就别开',
                    open: _modelImproveOpen,
                    onTap: () =>
                        setState(() => _modelImproveOpen = !_modelImproveOpen),
                  ),
                  if (_modelImproveOpen) ...<Widget>[
                    // ---- 描述改进：档位 / 用哪个模型 / 自定义要求 ----
                    //
                    // 三样东西各管一件事，不能合并：
                    //  · **档位** = 改写器能动多少（低：只把读不通的改到读得通；
                    //    高：允许重写成一条结构化的任务描述）；
                    //  · **模型** = 拿谁去改写。改写是"短、快、要稳"的活
                    //    （它不做推理，只补指代），拿主模型去干纯属浪费 ——
                    //    而且当前模型响应慢的话，每发一条消息都要多等它一次；
                    //  · **自定义要求** = 用户本人对改写器的额外指令，
                    //    优先级高于内置规则。
                    const SizedBox(height: 18),
                    Text(
                      '描述改进',
                      style: AppFonts.body(
                        size: 12.8,
                        weight: FontWeight.w600,
                        color: s.muted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 开关**这一节里也要有**。
                    //
                    // 配置项（力度 / 模型 / 自定义要求）全在眼前，却要退回
                    // 输入框旁边才能把它打开 —— 那是设计上最容易让人放弃的
                    // 一种：找得到旋钮，找不到开关。
                    // 模型选择器里那个保留：那是"发消息前顺手调"的位置。
                    _switchRow(
                      s,
                      label: '发消息前先改进描述',
                      desc:
                          '打开后，你的原话会先被改写成更清楚的任务描述，'
                          '再把**改写版**交给模型执行。适合"帮我看看那个文件"'
                          '这类省略了指代的说法。\n'
                          '代价：每次多一次往返（一两秒）。原话仍然完整显示在'
                          '消息里，改写版折在它下面，随时可以核对。',
                      value: _improvePrompt,
                      onChanged: (bool v) => setState(() => _improvePrompt = v),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '下面三项决定**它怎么改**。'
                      '（输入框旁的模型选择器里也能开关。）',
                      style: AppFonts.body(
                        size: 12,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        for (final (String, String, String) lv
                            in <(String, String, String)>[
                              ('low', '低 · 最小改动', '只在指代不清、动作含糊时动手，句子结构和用词保持原样'),
                              ('medium', '中 · 默认', '补全指代、说明意图、去掉口语噪声，仍然保持一句话'),
                              (
                                'high',
                                '高 · 写成任务描述',
                                '允许重写成结构化的任务说明（目标 / 约束 / 产出），缺的信息留成待确认项',
                              ),
                            ])
                          ChoiceChip(
                            // **选中态必须显式给白字。**
                            //
                            // 芯片的选中底色是强调蓝，而 `ChipThemeData.labelStyle`
                            // 给的是正文色（近黑）—— 蓝底配黑字对比度只有 3.0:1，
                            // 三个按钮里选中的那个反而最看不清。
                            // 这不是"调淡一点"能解决的，是两个色角色没对上：
                            // 底色换了，字色就得跟着换。
                            label: Text(lv.$2),
                            labelStyle: AppFonts.body(
                              size: 12,
                              color: _improveLevel == lv.$1
                                  ? AppColors.onAccent
                                  : s.text,
                              weight: _improveLevel == lv.$1
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            selected: _improveLevel == lv.$1,
                            onSelected: (_) =>
                                setState(() => _improveLevel = lv.$1),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switch (_improveLevel) {
                        'low' => '低：最不容易改变你的原意，但只能修掉"读不通"的地方。',
                        'high' =>
                          '高：改动最大，会补出结构；适合"我懒得写需求，'
                              '你先帮我理清楚"。代价是它可能补出你没说过的细节 —— '
                              '所以改写结果会在原话下面折叠显示，发之前能核对。',
                        _ => '中：默认档位。多数情况下"补全指代 + 说明意图"就够了。',
                      },
                      style: AppFonts.body(
                        size: 11.6,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _field(
                      s,
                      label: '改进用的模型名（留空 = 用当前对话模型）',
                      controller: _improveModel,
                      hint: 'deepseek-flash / gpt-4o-mini ',
                    ),
                    _field(
                      s,
                      label: '自定义改进要求（可选，优先级最高）',
                      controller: _improveInstruction,
                      hint: '例如：把所有代词换成具体的名字；按分点输出',
                    ),
                    _note(
                      s,
                      '自定义要求会**原样追加**给改写器，并明确告诉它"这条优先于'
                      '上面所有规则"。写自己的习惯就行，比如"我说话很省略，'
                      '帮我补成完整句子"。\n'
                      '改写用的地址和密钥沿用当前档案；改写失败或结果不像话时'
                      '**自动退回你的原话**，不会因为它出问题就发不出消息。',
                    ),
                  ],
                  _foldHeader(
                    s,
                    title: '输入建议',
                    icon: Icons.lightbulb_outline_rounded,
                    desc: '输入框上方给可点的建议；会多一次短调用',
                    open: _modelSuggestOpen,
                    onTap: () =>
                        setState(() => _modelSuggestOpen = !_modelSuggestOpen),
                  ),
                  if (_modelSuggestOpen) ...<Widget>[
                    // ---- 输入建议 ----
                    //
                    // 两块：图片一挂上来就解析，给出"这道题怎么写 / 这是什么"
                    // 这类可点的建议；以及根据上下文揣测下一句。
                    // 都走一次**很短**的模型请求，所以给独立的开关、模型和
                    // 思考强度 —— 不该跟主对话模型绑死。
                    const SizedBox(height: 18),
                    Text(
                      '输入建议',
                      style: AppFonts.body(
                        size: 12.8,
                        weight: FontWeight.w600,
                        color: s.muted,
                      ),
                    ),
                    _switchRow(
                      s,
                      label: '在输入框上方给建议',
                      desc:
                          '发图片时先解析图片，给出「这道题怎么写」「这是什么」\n'
                          '根据最近几轮对话，揣测你接下来可能想说什么\n'
                          '建议只是可点的气泡，点了才填入输入框，不会替你发送',
                      value: _inputSuggest,
                      onChanged: (bool v) => setState(() => _inputSuggest = v),
                    ),
                    if (_inputSuggest) ...<Widget>[
                      _entryCard(
                        s,
                        icon: Icons.auto_awesome_outlined,
                        title: '建议用的模型',
                        desc: _suggestProfileLabel(),
                        onTap: _pickSuggestProfile,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '建议的思考强度',
                        style: AppFonts.body(size: 12.5, color: s.muted),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: <Widget>[
                          for (final (int, String) e in const <(int, String)>[
                            (0, '关闭'),
                            (1, '低'),
                            (2, '高'),
                            (3, '最高'),
                          ])
                            ChoiceChip(
                              label: Text(e.$2),
                              selected: _inputSuggestEffort == e.$1,
                              labelStyle: AppFonts.body(
                                size: 12,
                                color: _inputSuggestEffort == e.$1
                                    ? AppColors.onAccent
                                    : s.text,
                              ),
                              onSelected: (_) =>
                                  setState(() => _inputSuggestEffort = e.$1),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _note(
                        s,
                        '建议会消耗一次很短的模型调用（图片解析那次除外）。'
                        '选一个便宜、快的模型更合适；把强度设为「关闭」可以再省一点。',
                      ),
                    ],
                  ],
                  _foldHeader(
                    s,
                    title: '工具调用次数',
                    icon: Icons.build_outlined,
                    desc: '复杂任务被中途停住时才来调',
                    open: _modelRoundsOpen,
                    onTap: () =>
                        setState(() => _modelRoundsOpen = !_modelRoundsOpen),
                  ),
                  if (_modelRoundsOpen) ...<Widget>[
                    // ---- 单轮工具调用次数 ----
                    //
                    // 「不设限」= `maxToolRounds = 0`（见 Settings 里那一段）。
                    // 为什么要有这个选项：复杂任务要几轮根本估不准，而被
                    // 硬停住的代价比多花点 token 大得多 —— 模型不会说
                    // "我被限制了"，它只会含糊地总结一下，用户看到的是
                    // "它好像没做完"，还找不到原因。
                    _switchRow(
                      s,
                      label: '工具调用不设限',
                      desc:
                          '关着的时候最多跑 ${Settings.maxToolRoundsCeiling} 轮。'
                          '复杂任务（批量处理文件、多轮搜索核对）中途被停住时，'
                          '模型不会说自己被限制了，只会含糊地收尾 —— '
                          '打开这一项让它自己做判断。随时可以点停止键中断。',
                      value: _maxRounds <= 0,
                      onChanged: (bool v) =>
                          setState(() => _maxRounds = v ? 0 : 100),
                    ),
                    if (_maxRounds > 0)
                      _slider(
                        s,
                        label: '单轮最多工具调用次数',
                        value: _maxRounds.toDouble().clamp(
                          1,
                          Settings.maxToolRoundsCeiling.toDouble(),
                        ),
                        min: 1,
                        // 上限跟着 `Settings.maxToolRoundsCeiling` 走：
                        // value 越界时 Slider 会直接断言失败、整页崩掉，
                        // 所以这里和设置里的默认值必须同源。
                        max: Settings.maxToolRoundsCeiling.toDouble(),
                        divisions: Settings.maxToolRoundsCeiling - 1,
                        display: '$_maxRounds 次',
                        onChanged: (double v) =>
                            setState(() => _maxRounds = v.round()),
                      ),
                  ],
                ],

                // ---- 联网设置 ----
                ...<Widget>[
                  _note(s, '搜索通道、结果条数、识图模型'),
                  _section(s, '搜索与抓取'),
                  // ---- 抓网页用哪套 UA ----
                  //
                  // 同样的地址，手机版和桌面版常常是两份内容：
                  // 手机版把正文砍短、要点"展开全文"，桌面版是完整的。
                  // 抓资料时后者经常更好用，但**不该替他猜** —— 做成开关。
                  _switchRow(
                    s,
                    label: '抓网页时使用桌面版',
                    desc:
                        '关着＝按手机网页抓（默认）。\n'
                        '打开后按桌面站抓：一部分站点的正文只在桌面版才完整，'
                        '抓回来的资料更全；代价是少数站点会因此给出"电脑版"的更宽布局。',
                    value: _desktopUa,
                    onChanged: (bool v) => setState(() {
                      _desktopUa = v;
                      // 立刻生效：下一次抓取就用新 UA。
                      WebViewLoader.useDesktopUa = v;
                    }),
                  ),
                  Text(
                    '联网方式',
                    style: AppFonts.body(
                      size: 12.8,
                      color: s.muted,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...Settings.searchModePresets.map(((String, String) m) {
                    final bool active = _searchMode == m.$1;
                    return _SettingRow(
                        padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
                        borderColor: active ? AppColors.accent : null,
                        onTap: () => setState(() => _searchMode = m.$1),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                m.$2,
                                style: AppFonts.body(
                                  size: 13,
                                  color: s.text,
                                  height: 1.4,
                                ),
                              ),
                            ),
                            if (active)
                              Icon(
                                Icons.check_circle_rounded,
                                size: 17,
                                color: AppColors.accent,
                              ),
                          ],
                        ),
                      );
                  }),
                  const SizedBox(height: 6),
                  Text(
                    '浏览器抓取使用的搜索引擎',
                    style: AppFonts.body(
                      size: 12.8,
                      color: s.muted,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: SearchEngine.all.map((SearchEngine e) {
                      final bool active = _engine == e.id;
                      return _SettingRow(
                        // 胶囊不是列表行：没有底部分隔线。
                        divider: false,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        borderColor: active ? AppColors.accent : null,
                        onTap: () => setState(() => _engine = e.id),
                        child: Text(
                          e.label,
                          style: AppFonts.body(
                            size: 13,
                            weight: FontWeight.w600,
                            color: active ? AppColors.accent : s.text,
                            height: 1.2,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  _foldHeader(
                    s,
                    title: '接口与识图',
                    icon: Icons.visibility_outlined,
                    desc: 'Tavily Key、直连通道、视觉模型；留空就复用主模型',
                    open: _netAdvancedOpen,
                    onTap: () =>
                        setState(() => _netAdvancedOpen = !_netAdvancedOpen),
                  ),
                  if (_netAdvancedOpen) ...<Widget>[
                    _field(
                      s,
                      label: 'Tavily API Key（可选）',
                      controller: _searchKey,
                      hint: '填了会优先用 Tavily，结果更完整',
                    ),

                    const SizedBox(height: 14),
                    Text(
                      '「+」面板里搜索走哪条通道',
                      style: AppFonts.body(
                        size: 12.8,
                        color: s.muted,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 这两条是**直连**通道（不走内置浏览器），所以它们在
                    // 国内网络下的可用性和上面的"浏览器引擎"完全不是一回事：
                    // 浏览器那条是拿系统 WebView 去抓，通用但慢；
                    // 这两条是直接请求接口，快，但可能被墙/被限流。
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: WebSearchSource.all.map((WebSearchSource src) {
                        final bool active = _webEngine == src.id;
                        return _SettingRow(
                          // 同上：胶囊不画分隔线。
                          divider: false,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          borderColor: active ? AppColors.accent : null,
                          onTap: () => setState(() => _webEngine = src.id),
                          child: Text(
                            src.label,
                            style: AppFonts.body(
                              size: 13,
                              weight: FontWeight.w600,
                              color: active ? AppColors.accent : s.text,
                              height: 1.2,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 6),
                    _note(
                      s,
                      'Bing RSS 走 `search?format=rss`，国内可达而且结构稳定；'
                      'DuckDuckGo 走 lite 页，结果质量通常更好但国内经常连不上。'
                      '**首选失败会自动改用另一条**，所以选哪个都不会搜不到。',
                    ),

                    // 识图收在这一组：视觉模型同样是"选一个外部服务"
                    _note(
                      s,
                      '识图流程：screen_capture 截图 → read_image 把图片交给模型。'
                      '当前模型勾了「支持图像理解」就直接用它；'
                      '没勾会用同一套地址和密钥试一次这里的视觉模型（默认 deepseek-flash），'
                      '都失败才降级为本地 OCR。'
                      '下面三项**留空就复用主模型**，只填其中一两项也可以。',
                    ),
                    _field(
                      s,
                      label: '视觉接口地址（可选，覆盖主模型）',
                      controller: _visionUrl,
                      hint: '留空则复用主模型的地址',
                    ),
                    _field(
                      s,
                      label: '视觉 API Key（可选）',
                      controller: _visionKey,
                      hint: '留空则复用主模型的 Key',
                      obscure: true,
                    ),
                    _field(
                      s,
                      label: '视觉模型（可选）',
                      controller: _visionModel,
                      hint: '留空则用 deepseek-flash',
                    ),
                  ],
                ],

                // ---- 开发者选项 ----
                //
                // 从前这里是一张入口卡（"高级设置" → 再点"开发者选项"）。
                // 现在所有区块平铺，这一节直接出现；[_section] 就是它的标题。
                ...<Widget>[
                    _section(s, '开发者选项'),
                    _note(
                      s,
                      '这些是排障工具，不是功能开关。打开之后，'
                      '对话页的「性能」面板会多出一页「耗时明细」：'
                      '把每一轮的模型思考、工具执行、以及它们之外的等待时间全列出来，'
                      '并且可以导出成 log 文本。',
                    ),
                    _switchRow(
                      s,
                      label: '启用开发者选项',
                      desc:
                          '打开后性能面板会多出「耗时明细」页。'
                          '关掉只是藏起入口，已记录的耗时不会被删。',
                      value: widget.settings.developerMode,
                      onChanged: (bool v) async {
                        await widget.settings.update(
                          () => widget.settings.developerMode = v,
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                    if (widget.settings.developerMode) ...<Widget>[
                      _switchRow(
                        s,
                        label: '逐轮列出',
                        desc:
                            '默认只给汇总。长对话里逐轮明细会有几百行，'
                            '只在"第 12 轮为什么这么慢"时才需要打开。',
                        value: widget.settings.showPerTurnTimings,
                        onChanged: (bool v) async {
                          await widget.settings.update(
                            () => widget.settings.showPerTurnTimings = v,
                          );
                          if (mounted) setState(() {});
                        },
                      ),
                      _note(
                        s,
                        '怎么看：对话页右上角「性能」→「耗时明细」。'
                        '那里有一条堆叠比例条（思考 / 工具 / 等待各占多少），'
                        '数字和百分比都在下面。',
                      ),
                      _note(
                        s,
                        '导出：在「耗时明细」页底部。可以复制到剪贴板'
                        '（直接粘进反馈里），或者存成 .txt 到手机「下载」目录。',
                      ),
                    ],
                ],

                // ---- 内容尺度与实验 ----
                ...<Widget>[
                    _section(s, '内容尺度'),
                    _entryCard(
                      s,
                      icon: Icons.shield_moon_outlined,
                      title: 'TeenSpace',
                      desc: '成人内容 / 政治议题 / 题目查询的回答尺度',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) =>
                              TeenSpacePage(settings: widget.settings),
                        ),
                      ),
                    ),
                    // ---- 实验与未完成 ----
                    //
                    // 原来这一整块叫「更多」，是个垃圾桶分类：未实现的功能、
                    // 内容尺度、存储位置、能力扩展全堆在一起。用户扫一眼
                    // 找不到任何规律 —— 那正是"设置没有逻辑关系"的来源。
                    //
                    // 现在按**功能性质**拆成四组，顺序也是"越常用越靠前"。
                    _section(s, '实验功能'),
                    _entryCard(
                      s,
                      icon: Icons.desktop_windows_outlined,
                      title: '远程控制',
                      desc: '从电脑浏览器操作这台手机 —— **尚未实现**，先占位',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) => const RemotePage(),
                        ),
                      ),
                    ),
                ],

                // ---- 存储与权限 ----
                ...<Widget>[
                    _section(s, '存储与权限'),
                    //
                    // ---- 密码与安全 ----
                    //
                    // 放在「工具」之前：它是**总开关级别**的东西，工具是内容。
                    _entryCard(
                      s,
                      icon: Icons.lock_outline_rounded,
                      title: '密码与安全',
                      desc:
                          '设置密码并选择保护范围：设置、笔记、计划、记忆、'
                          '规则、工具、敏感权限，以及打开应用。支持指纹 / 面部。',
                      trailingText: (appLock?.hasPassword ?? false)
                          ? '已启用'
                          : '未设置',
                      onTap: () async {
                        final LockStore? lock = appLock;
                        if (lock == null) return;
                        if (!await ensureUnlocked(
                          context,
                          LockScope.settings,
                        )) {
                          return;
                        }
                        if (!context.mounted) return;
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (BuildContext _) =>
                                LockSettingsPage(store: lock),
                          ),
                        );
                        if (context.mounted) setState(() {});
                      },
                    ),
                    _entryCard(
                      s,
                      icon: Icons.folder_copy_outlined,
                      title: '工具',
                      desc:
                          '文件夹式的成套做法：`tool.md` 写怎么做，'
                          '旁边可以放脚本和模板。模型按需取用。',
                      trailingText: FolderToolStore.instance.tools.isEmpty
                          ? '还没有'
                          : '${FolderToolStore.instance.tools.length} 个',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) => const ToolsPage(),
                        ),
                      ),
                    ),

                    // ---- 终端 ----
                    //
                    // 入口在这里，是因为聊天页那个终端图标**只在命令跑着时
                    // 出现**（空闲时它没有信息量，还占地方）。
                    // 所以不跑命令的时候，这个入口是用户能找到终端页的唯一路径。
                    //
                    // 终端用的是**应用自带的 Alpine Linux**（proot + rootfs
                    // 都在 APK 里），不需要装 Termux、也不用改设置。
                    _entryCard(
                      s,
                      icon: Icons.terminal_rounded,
                      title: '终端',
                      desc:
                          '自带一套 Alpine Linux（proot），不用装 Termux。'
                          '可以看 agent 跑过什么命令，也可以自己敲。',
                      trailingText: LinuxService.instance.installed
                          ? '已安装'
                          : '未安装',
                      onTap: () => openTerminal(context),
                    ),
                ],

                // ---- 数据与备份 ----
                ...<Widget>[
                    _section(s, '数据与备份'),
                    _entryCard(
                      s,
                      icon: Icons.gavel_rounded,
                      title: 'Agent.md',
                      desc: '最高优先级规范：写法、术语、交付格式。冲突时以它为准',
                      trailingText: AgentDocStore.instance.isEmpty
                          ? '未设置'
                          : '${AgentDocStore.instance.text.length} 字',
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (BuildContext _) => AgentMdPage(
                              store: AgentDocStore.instance,
                            ),
                          ),
                        );
                        if (context.mounted) setState(() {});
                      },
                    ),
                    _entryCard(
                      s,
                      icon: Icons.rule_folder_outlined,
                      title: '自定义规则',
                      desc: '当的时候，就 —— 用自己的话规定 Agent 的行为',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) =>
                              RulesPage(store: RuleStore.instance),
                        ),
                      ),
                    ),
                    _entryCard(
                      s,
                      icon: Icons.terminal_rounded,
                      title: 'Python 控制台',
                      desc: '内嵌 CPython 3.13，零配置。在这里直接跑代码验证它是否可用',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) =>
                              const PythonConsolePage(),
                        ),
                      ),
                    ),
                    _entryCard(
                      s,
                      icon: Icons.extension_outlined,
                      title: '插件',
                      desc: '自定义工具：声明参数和命令模板，给 Agent 加能力',
                      onTap: () => showPluginsSheet(
                        context,
                        store: widget.plugins,
                        builtinNames: <String>{
                          'run_shell',
                          'app_manage',
                          'file_op',
                          'system_settings',
                          'screen_capture',
                          'web',
                          'browser',
                          'read_image',
                          'notes',
                          'tasks',
                        },
                      ),
                    ),
                    _entryCard(
                      s,
                      icon: Icons.menu_book_outlined,
                      title: '知识库',
                      desc: '真 RAG：导入文档 → 切片 → 向量检索 → 带出处回答',
                      trailingText: KnowledgeStore.maybeInstance == null
                          ? null
                          : '${KnowledgeStore.instance.bases.length} 个',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) =>
                              KnowledgePage(settings: widget.settings),
                        ),
                      ),
                    ),
                    _entryCard(
                      s,
                      icon: Icons.hub_outlined,
                      title: 'MCP 服务器',
                      desc: '接入外部 MCP 服务：连上就能把它的工具交给 AI 调用',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) => const McpPage(),
                        ),
                      ),
                    ),
                    _entryCard(
                      s,
                      icon: Icons.ios_share_rounded,
                      title: '导出备份',
                      desc: '会话、笔记、任务、插件和设置（API Key 默认不含）',
                      onTap: () async {
                        final String? msg = await BackupActions.export(
                          context,
                          settings: widget.settings,
                          conversations: widget.conversations,
                          notes: widget.notes,
                          tasks: widget.tasks,
                          plugins: widget.plugins,
                        );
                        if (msg != null && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(msg),
                              duration: const Duration(seconds: 4),
                            ),
                          );
                        }
                      },
                    ),
                    _entryCard(
                      s,
                      icon: Icons.download_rounded,
                      title: '导入备份',
                      desc: '从 JSON 备份恢复，可选合并或覆盖',
                      onTap: () async {
                        final String? msg = await BackupActions.import(
                          context,
                          settings: widget.settings,
                          conversations: widget.conversations,
                          notes: widget.notes,
                          tasks: widget.tasks,
                          plugins: widget.plugins,
                        );
                        if (msg != null && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(msg),
                              duration: const Duration(seconds: 4),
                            ),
                          );
                        }
                      },
                    ),

                    // 存储并入「数据与扩展」—— 插件、导入导出、存储清理
                    // 都是"数据从哪来、往哪去"，归到一起更好找
                    _SettingRow(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                      onTap: () =>
                          showStorageSheet(context, workDir: widget.workDir),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.folder_outlined,
                            size: 18,
                            color: AppColors.accent,
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  '管理存储空间',
                                  style: AppFonts.body(
                                    size: 14,
                                    weight: FontWeight.w600,
                                    color: s.text,
                                    height: 1.3,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '查看并清理截图、录屏和聊天附件',
                                  style: AppFonts.body(
                                    size: 12,
                                    color: s.muted,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: s.muted,
                          ),
                        ],
                      ),
                    ),
                ],

                // ---- 记忆与自学习 ----
                ...<Widget>[
                    _section(s, '上下文'),
                    // ---- 压缩时机：三选一 ----
                    //
                    // 原来是一个开关（开 = 每轮都压）。开关的问题是它只回答
                    // "压不压"，回答不了"什么时候压" —— 而后者才是用户真正
                    // 在意的那件事：多数会话离上下文上限很远，每轮都压
                    // 等于白付一份有损的代价。
                    //
                    // 现在拆成三档，一眼能看出区别：
                    //  · 每轮压缩 —— 原来的行为，最省 token，也最损原文；
                    //  · 80% 压缩 —— 宽裕时给全文，吃紧了再压（推荐）；
                    //  · 不压缩 —— 核对输出、复现报错时用。
                    for (final (String id, String title, String desc)
                        in const <(String, String, String)>[
                          (
                            'every',
                            '每轮压缩',
                            '每次发请求前都压一遍较早的工具输出。最省 token，'
                                '但模型回看旧输出时看到的已经是摘要。',
                          ),
                          (
                            'ratio',
                            '80% 压缩',
                            '用量到上下文上限的 80% 才开始压。宽裕时给模型看完整原文，'
                                '吃紧时自动收紧。',
                          ),
                          (
                            'off',
                            '不压缩',
                            '原样发送。需要模型精确回看某段工具原文时用，'
                                '代价是更容易撞上限。',
                          ),
                        ])
                      _SettingRow(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        onTap: () async {
                          await widget.settings.update(
                            () => widget.settings.compressMode = id,
                          );
                          if (mounted) setState(() {});
                        },
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    title,
                                    style: AppFonts.body(
                                      size: 14.5,
                                      weight:
                                          widget.settings.compressMode == id
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: s.text,
                                      height: 1.3,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    desc,
                                    style: AppFonts.body(
                                      size: 12,
                                      color: s.muted,
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            if (widget.settings.compressMode == id)
                              Icon(
                                Icons.check_rounded,
                                size: 18,
                                color: AppColors.accent,
                              ),
                          ],
                        ),
                      ),
                    if (widget.settings.compressContext)
                      _stepperRow(
                        s,
                        label: '保留最近几轮全文',
                        desc: '数值越大越保守，越不压。',
                        value: widget.settings.compressKeepTurns,
                        min: 1,
                        max: 10,
                        onChanged: (int v) async {
                          await widget.settings.update(
                            () => widget.settings.compressKeepTurns = v,
                          );
                          if (mounted) setState(() {});
                        },
                      ),
                    _section(s, '记忆'),
                    _switchRow(
                      s,
                      label: '启用记忆',
                      desc: '关闭后记忆不再注入对话，但不会被删除',
                      value: widget.settings.memoryEnabled,
                      onChanged: (bool v) async {
                        await widget.settings.update(
                          () => widget.settings.memoryEnabled = v,
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                    _switchRow(
                      s,
                      label: '跨聊天记忆',
                      desc:
                          'AI 能看到其他对话的摘要，需要时用 recall 检索原话。'
                          '只读，不会修改任何对话；关闭后立即停止注入和检索。',
                      value: widget.settings.crossChatMemory,
                      onChanged: (bool v) async {
                        await widget.settings.update(
                          () => widget.settings.crossChatMemory = v,
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                    _entryCard(
                      s,
                      icon: Icons.psychology_outlined,
                      title: '管理记忆',
                      desc: '查看记住了什么、逐条删除、清空全部',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) =>
                              MemoryPage(store: MemoryStore.instance),
                        ),
                      ),
                    ),
                    _entryCard(
                      s,
                      icon: Icons.forum_outlined,
                      title: '可回忆的对话',
                      desc: '看看 AI 能读到的其他对话（只读，不会修改）',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) => ChatMemoryPage(
                            currentId: widget.conversations.currentId ?? '',
                          ),
                        ),
                      ),
                    ),

                    // ---- 自学习 ----
                    //
                    // 和「记忆」并排，但方向相反：记忆是 agent 记**用户**的事，
                    // 自学习是 agent 记**自己**的事（走过的弯路、犯过的错、
                    // 学会的技能）。所以这里没有"手动添加"，只有查看和删除。
                    _section(s, '自学习'),
                    _switchRow(
                      s,
                      label: '启用自学习',
                      desc:
                          'AI 会把自己走过的弯路、犯过的错、学到的技能写进笔记，'
                          '每轮对话都带上。关闭后不再注入，笔记仍然保留。',
                      value: widget.settings.learningEnabled,
                      onChanged: (bool v) async {
                        await widget.settings.update(
                          () => widget.settings.learningEnabled = v,
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                    _entryCard(
                      s,
                      icon: Icons.school_outlined,
                      title: '自学习笔记',
                      desc: 'AI 自己写，你只能查看和删除（不能添加）',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext _) =>
                              LearningPage(store: LearningStore.instance),
                        ),
                      ),
                    ),
                ],

                // ---- 安全确认 ----
                ...<Widget>[
                    _section(s, '安全确认'),
                    _bgCard(s),
                    _switchRow(
                      s,
                      label: '只读命令自动执行',
                      desc:
                          '关闭后每一条命令都需要你确认。'
                          '危险操作（卸载、清除数据、删除文件等）始终会弹窗确认，不受此项影响。',
                      value: _autoApproveSafe,
                      onChanged: (bool v) =>
                          setState(() => _autoApproveSafe = v),
                    ),
                    _switchRow(
                      s,
                      label: '全部放行（之后不再询问）',
                      desc:
                          '关着的时候，每个有副作用的工具都会弹确认框。'
                          '打开它 = 等价于点过确认框里的「全部运行」：'
                          '**所有工具都不再询问，包括危险命令**。\n'
                          '平时不用来这里开 —— 在任意一个确认框里点「全部运行」'
                          '就会打开，输入框旁边也会出现一个感叹号随时能暂停。'
                          '这一项只是给"我知道我在干什么"的人一个总开关。',
                      value: _autoApproveAll,
                      onChanged: (bool v) =>
                          setState(() => _autoApproveAll = v),
                    ),
                    // 这里原来有个 `SizedBox(height: 10)`。`_switchRow` 现在
                    // 自带 9 的下间距，再补一个就变成 19 —— 比别处都宽。
                    _overlayRow(s),
                    _a11yRow(s),
                ],

                // ---- 关于 ----
                ...<Widget>[
                  _section(s, '关于'),
                  _note(s, '应用信息、作者 GitHub、内容尺度与说明'),
                  _entryCard(
                    s,
                    icon: Icons.info_outline_rounded,
                    title: kAppName,
                    desc: '$kAppTagline\n版本 $kAppVersionLabel',
                    trailingText: 'v$kAppVersion',
                    onTap: () => showAboutDialog(
                      context: context,
                      applicationName: kAppName,
                      applicationVersion: kAppVersionLabel,
                      applicationLegalese: 'MIT License · $kAppTagline',
                      children: <Widget>[
                        const SizedBox(height: 12),
                        Text(
                          'Zeus 把大模型接到手机本地能力上：'
                          '对话、笔记、任务、联网搜索、Python、'
                          '内置浏览器与文件管理。模型配置与 API Key '
                          '只保存在本机。',
                          style: AppFonts.body(
                            size: 13,
                            color: s.text,
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _entryCard(
                    s,
                    icon: Icons.code_rounded,
                    title: '作者 GitHub：$kAuthorName',
                    desc:
                        'github.com/$kAuthorGithubName\n'
                        '源代码、更新日志与问题反馈',
                    onTap: () => launchUrl(
                      Uri.parse(kAuthorGithubUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ],
            );

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          // 页头用和笔记/任务页同一个 AppHeader —— 三个页面的头部样式
          // 必须完全一致，否则"设置"看起来像另一个应用。
          AppHeader(
            // 平铺之后只有一页，标题恒为「设置」；返回箭头直接退出。
            title: '设置',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          // 单页平铺之后**没有内容切换**，所以不再需要 `AnimatedSwitcher`
          // —— 那个动画是为"目录 ↔ 分类"换内容准备的。
          Expanded(child: content),
        ],
      ),
    );
  }

  /// 可折叠的分组头。**和 [_entryCard] 同一套规格**：同样的圆形图标、
  /// 同样的 15/12.5 文字层级、同样的行高与 8 的卡片间距 ——
  /// 它本质上也是一个入口（点一下展开），只是箭头换成了上下方向。
  Widget _foldHeader(
    AppSurface s, {
    required String title,
    required String desc,
    required bool open,
    required VoidCallback onTap,
    IconData icon = Icons.tune_rounded,
  }) {
    return _SettingRow(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _entryRowHeight),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _entryIcon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 15,
                        weight: FontWeight.w600,
                        color: s.text,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 20,
                  color: s.muted,
                ),
              ),
            ],
          ),
        ),
      );
  }

  /// 分组标题：11.5 / w600 / muted，左对齐，上 18 下 8。
  Widget _section(AppSurface s, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(
        title,
        style: AppFonts.body(
          size: 11.5,
          weight: FontWeight.w600,
          color: s.muted,
          height: 1.2,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _field(
    AppSurface s, {
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: AppFonts.body(size: 12.8, color: s.muted, height: 1.3),
          ),
          const SizedBox(height: 5),
          Container(
            decoration: BoxDecoration(
              color: s.surface,
              // 胶囊，和聊天页的输入框、以及所有按钮统一。
              // 它是个普通 Container，不存在 OutlineInputBorder 在
              // 大圆角处描边畸变的问题，所以可以直接拉到最大。
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: s.border, width: 0.9),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: controller,
                    obscureText: obscure,
                    style: AppFonts.body(size: 14, color: s.text, height: 1.4),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      hintText: hint,
                      hintStyle: AppFonts.body(size: 13.5, color: s.muted),
                    ),
                  ),
                ),
                ?suffix,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    AppSurface s, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: AppFonts.body(
                      size: 12.8,
                      color: s.muted,
                      height: 1.3,
                    ),
                  ),
                ),
                Text(display, style: AppFonts.code(size: 12.5, color: s.text)),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: s.border,
                thumbColor: AppColors.accent,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 数值加减的一行（保留几轮全文这类"1..N"的设置）。
  ///
  /// 用加减而不是滑杆：这类值范围小、需要精确（3 和 4 结果不同），
  /// 滑杆在小屏上一拖就越过一格。
  Widget _stepperRow(
    AppSurface s, {
    required String label,
    required String desc,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    // 不要外间距：行与行之间只隔一条发丝线（见 [_SettingRow]）。
    return _SettingRow(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: AppFonts.body(
                    size: 14,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: AppFonts.body(size: 12.3, color: s.muted, height: 1.5),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_rounded, size: 18),
            tooltip: '减少',
            onPressed: value <= min ? null : () => onChanged(value - 1),
          ),
          SizedBox(
            width: 22,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: AppFonts.body(
                size: 15,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 18),
            tooltip: '增加',
            onPressed: value >= max ? null : () => onChanged(value + 1),
          ),
        ],
      ),
    );
  }

  Widget _switchRow(
    AppSurface s, {
    required String label,
    required String desc,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _SettingRow(
      // **不再自带下间距。**
      //
      // 卡片时代它需要 9px 的缝，否则和下一张卡贴在一起。
      // 现在条目之间靠 [_SettingRow] 底部那条发丝线分隔，
      // 再补 9 反而会在连成一列的行里插进一段空白。
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: AppFonts.body(
                    size: 14,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: AppFonts.body(size: 12.3, color: s.muted, height: 1.5),
                ),
              ],
            ),
          ),
          IosSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// 说明条：**一行灰字，不是一块卡片**。
  ///
  /// 之前它有自己的底色、描边和圆角 —— 在"全是条目"的设置页里，
  /// 它是唯一一个还带底色的块，反而比正文显眼（用户的要求是
  /// "栏目不要板块/卡片的"）。
  ///
  /// 现在只剩：一个 14 号的信息图标 + 一段 12.5 的灰字。
  /// 靠**左边缩进 14 + 上方 10** 和真正的条目区分开 —— 它是注释，
  /// 不该有和条目一样的视觉重量。
  Widget _note(AppSurface s, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded, size: 14, color: s.muted),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: mdText(
              text,
              style: AppFonts.body(size: 12.5, color: s.muted, height: 1.55),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置页的一行：**条目型，不是卡片**。
///
/// ## 为什么设置页不再用卡片
///
/// 卡片适合"一屏只有三块"的页面 —— 每一块自己成一个单位，靠底色和
/// 圆角从页面里浮出来。而设置页是**几十行**：每行一张卡就成了
/// "一堆小方块贴在灰底上"，行与行之间的空隙比行本身还显眼，
/// 扫起来断断续续。
///
/// 条目型的做法是 iOS 设置页那一套：**行与行之间只有一条发丝线**，
/// 整列读起来是一个连续的列表。分组靠 [_SettingsSheetState._section]
/// 那条小标题，不靠底色。
///
/// ## 参数为什么和 [SurfaceCard] 一样
///
/// 15 个调用点原来都写着 `SurfaceCard(padding: …, onTap: …)`。
/// 保持同样的签名，替换时只需要改类名 —— 那些调用的内部结构
/// （图标 + 标题 + 说明 + 右箭头）本来就和容器无关。
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.borderColor,
    this.onTap,
    this.divider = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 非 null = **这一行被选中**（单选列表里那几处）。
  ///
  /// 原来用卡片描边表示选中（描一圈强调色）。没有卡片之后描边没地方画了，
  /// 改成**极淡的强调色底**（8%）——在一片灰里刚好能读出"是这行"，
  /// 又不会像一块标签那样跳出来。同一行右侧本来就有勾，两者互相印证。
  final Color? borderColor;

  final VoidCallback? onTap;

  /// 要不要在底部画那条发丝线。
  ///
  /// `Wrap` 里那几个**选项胶囊**要关掉它：它们不是列表行，是一条条
  /// 并排的小块，每条底下挂一根线就成了"带下划线的按钮"。
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final bool selected = borderColor != null;

    final Widget body = Padding(padding: padding, child: child);

    return Material(
      // `Material` + `InkWell` 才有水波纹；而底色必须是透明的，
      // 否则每一行都会刷出一块白色（M2 的 Material 默认带 surface 色）。
      color: selected
          ? (borderColor ?? AppColors.accent).withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: DecoratedBox(
          // 行与行之间的那条线。0.6 是"发丝线"的宽度 ——
          // 1.0 在 3x 屏上会渲染成 3 个物理像素，看起来像一条实线。
          decoration: BoxDecoration(
            border: divider
                ? Border(bottom: BorderSide(color: s.border, width: 0.6))
                : null,
          ),
          child: body,
        ),
      ),
    );
  }
}
