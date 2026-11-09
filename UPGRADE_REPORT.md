# 手机 Agent 感知 / 执行通道升级

## 这次改了什么

主通道从「截图 + 看图猜坐标」改成「无障碍控件树 + 语义动作」，截图保留为降级路径。

```
模型
 ├─ ui_tree ──→ 无障碍 dump ──→ 过滤/压缩成 ≤40 行文本
 ├─ ui_action ─→ rid/text/desc/index → 节点中心点击 / ACTION_SET_TEXT / ACTION_SCROLL
 │               └─ 失败 → 坐标手势 / xy 兜底
 ├─ draw_path ─→ Python 生成的归一化路径 → dispatchGesture 连续笔画
 └─ 不可用时 ──→ screen_capture + read_image（原路径，未删除）
```

## 新增能力

- **UI 树**：读取前台包名、窗口、屏幕尺寸和控件列表；过滤纯布局容器、
  零面积节点、无文字/描述且不可操作的节点；相同 `rid + text` 去重；
  默认最多 40 行，超出按「可输入 > 可点击 > 可滚动 > 有文字」截断。
- **语义动作**：`click` / `set_text` / `scroll_forward` / `scroll_backward` /
  `swipe` / `tap` / `back` / `home` / `recents` / `wait_for` / `launch` / `open_url`。
  目标解析顺序：`rid` → 文本精确 → 文本包含 → `desc` → `index` → `xy`。
- **执行回读**：动作后重新 dump，比较界面指纹，返回「已变化 / 未变化」。
  未变化时提示不要原样重试。
- **连续手势**：`swipe` 用一条 `dispatchGesture` 路径，支持 2–60 个采样点；
  `draw_path` 每一笔是一条独立连续手势，笔间留 120ms。
- **路径绘制**：支持 `path_file` 或内联 `strokes`，坐标可选
  `normalized`（0–1）或 `screen`；可指定画布 `rect` 和启动绘图 App。
- **历史图片裁剪**：只保留最近两条带图用户消息的 `image_url`，
  更早的图替换成「路径 + 需要时 read_image」的短提示。
- **悬浮窗收敛**：只有本次任务调用过手机控制类动作（`ui_action` /
  `draw_path` / `input` / `am start` / `monkey` / 应用启动）且应用在后台时
  才显示；普通写代码、查资料任务不再弹。

## 改动文件

- `android/app/src/main/kotlin/com/dsh/dsh_agent/AgentAccessibilityService.kt`
- `android/app/src/main/kotlin/com/dsh/dsh_agent/A11yBridge.kt`
- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/res/xml/accessibility_service_config.xml`
- `android/app/src/main/res/values/strings.xml`
- `android/app/src/main/kotlin/com/dsh/dsh_agent/MainActivity.kt`
- `lib/core/a11y.dart`
- `lib/core/ui_tree.dart`
- `lib/core/phone_control.dart`
- `lib/tools/ui_tools.dart`
- `lib/ui/chat_page.dart`
- `lib/ui/settings_sheet.dart`
- `lib/ai/agent.dart`
- `test/ui_tree_test.dart`
- `test/phone_control_test.dart`
- `test/image_attachment_path_test.dart`

## 怎么开启

应用内：`设置 → 自定义设置 → 安全 → 手机控制（无障碍） → 去开启`，
在系统设置里找到「PrivTasker 手机控制」并打开。

Android 13+ 如果显示「受限设置」，先到系统「应用信息 → PrivTasker」
允许受限设置，再回来开启。

## 验证结果

- `flutter analyze`：No issues found
- `flutter test`：全量通过（新增控件树 / 路径 / 悬浮窗判断 / 历史图片裁剪测试）
- 新增 Kotlin 文件用本地 Kotlin 2.4.0 编译器对照 `android-35`、
  Flutter embedding 和现有 release classes 编译通过。
- **未在真机验证**：当前 `adb devices` 为空，没有连接设备；
  坐标映射、真实点击、绘制效果需要装机后实测。

## 已知限制

- 无障碍没开时没有 `uiautomator dump` 兜底，直接退回截图 + `read_image`。
  这是刻意的取舍：少维护一条 XML 解析链，失败提示更明确。
- `set_text` 依赖目标控件暴露 `editable`。自绘输入框可能拒绝
  `ACTION_SET_TEXT`，此时需要坐标点击 + 输入法方案。
- `draw_path` 目前只返回「系统接受了几笔」，最终画面仍要靠
  `screen_capture + read_image` 确认；没有做像素级断言。
- 注入手势没有压感/倾斜，绘图 App 的笔刷动态会按手指处理。
- 部分 OEM 会杀无障碍服务；应用被杀后任务停止，不会后台续跑。
- 没有实现 `uiautomator2` / atx-agent 常驻方案，避免额外安装和保活成本。
