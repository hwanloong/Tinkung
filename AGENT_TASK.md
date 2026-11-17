# PrivTasker 改动任务单

项目路径：D:\pj3\PrivTasker（Flutter + Kotlin Android）
Build 命令：`D:\flutter\flutter_windows_3.47.4-stable\flutter\bin\flutter.bat build apk --release`（在项目根目录执行，用 PowerShell terminal tab）

---

## 一、已完成（不要重复改）

### 1. MCP 重构（lib/mcp/mcp_store.dart）
- `sanitizeMcpSchema` 加了 `$ref` 展开（`_expandRefs`，深度上限 8）
- `McpServer` 加了熔断字段：`_failCount`、`_blockedUntil`、`isBlocked`、`recordSuccess()`、`recordFailure()`（3 次失败封锁 60s）
- `McpServer` 加了 `disabledTools: Set<String>` 和 `enabledTools` getter
- `McpStore` 加了 `callHistory`（环形缓冲 200 条）、`McpCallRecord` 类、`setToolEnabled()` 方法
- `McpStore.callTool()` 加了熔断检查和调用记录写入

### 2. mcp_page.dart（lib/ui/mcp_page.dart）
- 每个工具行加了 toggle 开关（调用 `McpStore.instance.setToolEnabled`）
- 显示熔断状态
- "工具"→"技能"（仅这个文件内的显示文字）

### 3. 上下文压缩默认值（lib/core/store.dart）
- `compressMode` 默认值从 `'every'` 改为 `'ratio'`

### 4. 删除折叠/极简过程功能
- **lib/core/store.dart**：删除了 `collapseToolSteps` 和 `minimalProgress` 字段及其 load/save
- **lib/ui/chat_page.dart**：删除了 `_toolsFolded` 状态变量；删除了 `ToolFoldAllRow` 整段逻辑（`showFoldRow`/`firstToolIdx`/`foldRow`/`hideMsgTools`/`lastUserIndex`）；`MessageView` 调用点去掉了 `collapseToolSteps`/`minimalProgress`/`showToolSteps` 三个参数
- **lib/ui/widgets.dart**：`MessageView` 类删除了 `collapseToolSteps`/`showToolSteps`/`minimalProgress` 三个参数字段；`_assistantBlock` 里工具步骤改为 `collapse: false` 直接平铺

---

## 二、未完成（需要继续做）

### 任务 A：修复残留编译错误（优先，先 build 确认）

**A1. lib/ui/widgets.dart 第 641 行附近** — `minimalProgress` 残留引用未删：
```dart
// 现在的错误代码（大约在 _assistantBlock 方法里）：
if (!minimalProgress &&
    (message.reasoning.trim().isNotEmpty ||
        (message.pending && message.content.trim().isEmpty))) {
  children.add(_ThinkingCard(message: message));
}
```
改为：
```dart
if (message.reasoning.trim().isNotEmpty ||
    (message.pending && message.content.trim().isEmpty)) {
  children.add(_ThinkingCard(message: message));
}
```

**A2. lib/ui/chat_page.dart** — 检查是否还有 `_minimalProcessRow`、`collapseToolSteps`、`minimalProgress` 残留引用：
```bash
grep -n "minimalProgress\|collapseToolSteps\|_toolsFolded\|showFoldRow\|ToolFoldAllRow\|_minimalProcess\|lastUserIndex" lib/ui/chat_page.dart
```
如果有，全部删掉相关代码。

**A3. lib/ui/settings_sheet.dart** — 删除以下两个 toggle（搜关键字找到后删整块）：
- 搜 `collapseToolSteps` 找到的 toggle 行 → 删掉
- 搜 `minimalProgress` 找到的 toggle 行 → 删掉

修复后先 build 一次，确认无编译错误再继续。

---

### 任务 B：复制按钮只在最后一条 AI 消息显示

**lib/ui/widgets.dart**

1. 给 `MessageView` 加一个参数：
```dart
// 在构造函数参数列表加
this.isLastAssistant = false,
// 在字段声明加
final bool isLastAssistant;
```

2. 在 `_assistantBlock` 里找到 `_CopyButton` 添加逻辑，改为：
```dart
// 原来（大约是）：
if (!message.pending) {
  children.add(_CopyButton(text: message.content));
}
// 改为：
if (!message.pending && isLastAssistant) {
  children.add(_CopyButton(text: message.content));
}
```

**lib/ui/chat_page.dart**

在 `ListView.builder` 的 `itemBuilder` 里，找到 `MessageView(...)` 的调用处，
在构建之前先计算最后一条 assistant 消息的 index：
```dart
// 在 itemBuilder 外面（ListView.builder 之前）计算一次：
int lastAssistantIndex = -1;
for (final int i in visible) {
  if (conv.messages[i].role == Role.assistant) lastAssistantIndex = i;
}
```
然后在 `MessageView` 调用里加：
```dart
isLastAssistant: index == lastAssistantIndex,
```

---

### 任务 C：Tool → Skill 全量重命名

**涉及文件：**
- `lib/core/folder_tool.dart` → 重命名为 `lib/core/skill.dart`
- `lib/ui/tools_page.dart` → 重命名为 `lib/ui/skills_page.dart`
- `lib/tools/folder_tool_tool.dart` → 重命名为 `lib/tools/skill_tool.dart`

**类名替换（全项目 grep 然后替换）：**
| 旧名 | 新名 |
|------|------|
| `FolderTool` | `Skill` |
| `FolderToolStore` | `SkillStore` |
| `ToolsPage` | `SkillsPage` |
| `ToolIcon` | `SkillIcon` |
| `kToolIconSize` | `kSkillIconSize` |

**import 路径同步更新：**
- `folder_tool.dart` → `skill.dart`
- `tools_page.dart` → `skills_page.dart`
- `folder_tool_tool.dart` → `skill_tool.dart`

**用户可见显示文字（只改 FolderTool/Skill 语境下的"工具"）：**
- `SkillsPage` 内所有 `'工具'` → `'技能'`
- `lib/ui/settings_sheet.dart` 里 FolderTool 入口：`title: '工具'` → `title: '技能'`
- `lib/ui/app_drawer.dart` 里 FolderTool 入口文字 → `'技能'`
- `lib/core/mentions.dart` 里 `@tool:xxx` 相关的 UI label → `'技能'`（token 格式 `@tool:` 保持不变）

**不要改的"工具"：** `GarminPushTool`、`PluginTool`、`AgentTool`、MCP 相关、内置工具类里的显示文字

---

### 任务 D：设置页重构（lib/ui/settings_sheet.dart，2500+ 行）

**D1. 删除"模型列表显示"功能**
搜 `_uiAdvancedOpen`，找到整个可折叠块（约 `bool _uiAdvancedOpen = false;` 和对应的 `_foldHeader` + `if (_uiAdvancedOpen)` 展开块），全部删掉。

**D2. 加顶部搜索框**
在 `_SettingsSheetState` 里加：
```dart
String _searchQuery = '';
final TextEditingController _searchCtrl = TextEditingController();
```
`dispose` 里加 `_searchCtrl.dispose();`

在 `build` 方法的 `Scaffold` body 里，改成 `Column` 包裹搜索栏 + 原来的 `content`（ListView）：
```dart
body: Column(
  children: [
    _buildSearchBar(s),
    Expanded(child: content),
  ],
),
```

搜索栏 widget：
```dart
Widget _buildSearchBar(AppSurface s) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Container(
      decoration: BoxDecoration(
        color: s.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: s.border, width: 0.9),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 17, color: s.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v.trim()),
              style: AppFonts.body(size: 14, color: s.text),
              decoration: InputDecoration(
                hintText: '搜索设置',
                hintStyle: AppFonts.body(size: 14, color: s.muted),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_searchQuery.isNotEmpty)
            GestureDetector(
              onTap: () { _searchCtrl.clear(); setState(() => _searchQuery = ''); },
              child: Icon(Icons.close_rounded, size: 16, color: s.muted),
            ),
        ],
      ),
    ),
  );
}
```

在 `_entryCard` 方法内部第一行加过滤：
```dart
if (_searchQuery.isNotEmpty &&
    !title.toLowerCase().contains(_searchQuery.toLowerCase())) {
  return const SizedBox.shrink();
}
```

在 `_section` 方法里加：搜索时不显示分组标题：
```dart
if (_searchQuery.isNotEmpty) return const SizedBox.shrink();
```

**D3. External Artifact 改为二级页面**

新建文件 `lib/ui/external_artifact_page.dart`，内容见下方。

然后在 `settings_sheet.dart` 里：
- 删掉 `_section(s, 'External Artifact')` 和 `_ExternalArtifactCard(...)` 调用
- 删掉整个 `_ExternalArtifactCard` class（文件末尾附近）
- 在原位置改为入口卡：
```dart
_entryCard(
  s,
  icon: Icons.extension_rounded,
  title: 'External Artifact',
  desc: '已安装的关联 app，AI 可调用其提供的技能',
  trailingText: ExternalArtifactStore.instance.artifacts.isEmpty
      ? '未发现'
      : '${ExternalArtifactStore.instance.artifacts.length} 个',
  onTap: () => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ExternalArtifactPage(
        store: ExternalArtifactStore.instance,
      ),
    ),
  ),
),
```
加 import：
```dart
import 'external_artifact_page.dart';
```

**新建 `lib/ui/external_artifact_page.dart`：**
```dart
import 'package:flutter/material.dart';
import '../core/external_artifact.dart';
import '../core/external_artifact_bridge.dart';
import '../theme/app_theme.dart';
import 'home_shell.dart';

class ExternalArtifactPage extends StatefulWidget {
  const ExternalArtifactPage({super.key, required this.store});
  final ExternalArtifactStore store;

  @override
  State<ExternalArtifactPage> createState() => _ExternalArtifactPageState();
}

class _ExternalArtifactPageState extends State<ExternalArtifactPage> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await ExternalArtifactBridge.instance.discover();
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return Scaffold(
      backgroundColor: s.pageBg,
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final arts = widget.store.artifacts;
          return Column(
            children: [
              AppHeader(
                title: 'External Artifact',
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                actions: [
                  IconButton(
                    onPressed: _refreshing ? null : _refresh,
                    icon: _refreshing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    tooltip: '刷新',
                  ),
                ],
              ),
              Expanded(
                child: arts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.extension_off_rounded,
                                size: 40, color: s.muted.withValues(alpha: 0.5)),
                            const SizedBox(height: 14),
                            Text('未发现已安装的 External Artifact',
                                style: AppFonts.body(size: 14, color: s.muted)),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _refresh,
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('刷新'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        itemCount: arts.length,
                        itemBuilder: (context, i) {
                          final art = arts[i];
                          return _ArtifactTile(artifact: art, s: s);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ArtifactTile extends StatefulWidget {
  const _ArtifactTile({required this.artifact, required this.s});
  final ExternalArtifact artifact;
  final AppSurface s;

  @override
  State<_ArtifactTile> createState() => _ArtifactTileState();
}

class _ArtifactTileState extends State<_ArtifactTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final art = widget.artifact;
    final s = widget.s;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: s.border, width: 0.8),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(Icons.extension_rounded,
                          size: 19, color: AppColors.accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(art.label,
                              style: AppFonts.body(
                                  size: 14.5, color: s.text, height: 1.3)),
                          Text(
                            '${art.tools.length} 个技能 · ${art.packageName}',
                            style: AppFonts.body(
                                size: 11.5, color: s.muted, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(Icons.expand_more_rounded,
                          size: 18, color: s.muted),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded && art.tools.isNotEmpty) ...[
              Divider(height: 1, color: s.border),
              ...art.tools.map((t) => Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: Row(
                      children: [
                        const SizedBox(width: 48),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.title,
                                  style: AppFonts.body(
                                      size: 13.5, color: s.text, height: 1.3)),
                              if (t.description.isNotEmpty)
                                Text(t.description,
                                    style: AppFonts.body(
                                        size: 11.5,
                                        color: s.muted,
                                        height: 1.4)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}
```

**D4. 设置分类标题重排**
把现有 `_section(s, '旧名')` 改成对应的新分类名：
| 原标题 | 新标题 |
|--------|--------|
| `'字号'` | `'外观'` |
| `'模型'` | `'模型'`（保持） |
| `'搜索与抓取'` | `'搜索与网络'` |
| `'开发者选项'` | `'开发者'` |
| `'内容尺度'` | `'安全'` |
| `'实验功能'` | `'实验'` |
| `'存储与权限'` | `'权限'` |
| `'数据与备份'` | `'数据'` |
| `'上下文'` | `'对话'` |
| `'记忆'` | `'记忆'`（保持） |
| `'自学习'` | `'学习'` |
| `'安全确认'` | `'安全确认'`（保持） |
| `'关于'` | `'关于'`（保持） |

---

## 三、完成顺序建议

1. **任务 A**（修编译错误）→ build 确认
2. **任务 B**（复制按钮）→ build 确认
3. **任务 C**（Tool→Skill）→ build 确认
4. **任务 D**（设置页）→ build 确认

每完成一个任务都单独 build 一次，确认无错误再继续下一个。

---

## 四、注意事项

- Build 命令用 PowerShell terminal tab，不要用 bash（flutter 在 bash 里找不到）
- 改 store.dart 时注意 `collapseToolSteps`/`minimalProgress` 的 load/save 也要删
- Tool→Skill 重命名后，`@tool:xxx` 的 token 格式不变，只改 UI 显示文字
- `_ExternalArtifactCard` class 在 settings_sheet.dart 文件末尾附近，全部删掉
- 设置页很长（2500+行），每次只改一小块，不要一次性大改
