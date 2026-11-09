package com.dsh.privtasker.sandbox

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.util.concurrent.Executors

/**
 * 独立的 Ubuntu 沙箱终端。
 *
 * 不注册桌面图标；PrivTasker 通过显式 Intent 启动。
 * rootfs 和 proot 都在这个 APK 内，安装后自包含。
 */
class SandboxActivity : Activity() {
    private lateinit var runtime: SandboxRuntime
    private lateinit var terminal: TextView
    private lateinit var input: EditText
    private lateinit var status: TextView
    private lateinit var runButton: Button
    private lateinit var installButton: Button
    private val worker = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        runtime = SandboxRuntime(applicationContext)
        setContentView(buildUi())

        append(
            "PrivTasker Sandbox\n" +
                "Ubuntu 24.04 base · proot · 独立 APK\n" +
                "------------------------------\n",
        )

        if (runtime.isInstalled()) {
            status.text = "Ubuntu 已就绪 · /shared 为共享目录"
            installButton.text = "重装 Ubuntu"
            append("Ubuntu 已安装，可以直接运行命令。\n\n")
        } else {
            status.text = "首次使用：正在准备 Ubuntu…"
            append("正在解压 Ubuntu rootfs，第一次需要几十秒。\n\n")
            install(false)
        }
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun buildUi(): ViewGroup {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(11, 15, 20))
            setPadding(dp(14), dp(14), dp(14), dp(10))
        }

        root.addView(TextView(this).apply {
            text = "PrivTasker Sandbox"
            setTextColor(Color.WHITE)
            textSize = 21f
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
        })

        root.addView(TextView(this).apply {
            text = "Ubuntu 24.04 · proot · apt"
            setTextColor(Color.rgb(150, 163, 176))
            textSize = 12f
            setPadding(0, dp(2), 0, dp(8))
        })

        status = TextView(this).apply {
            text = "正在检查环境…"
            setTextColor(Color.rgb(154, 230, 180))
            textSize = 12f
            setPadding(0, 0, 0, dp(8))
        }
        root.addView(status)

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.rgb(16, 22, 30))
            isFillViewport = true
        }
        terminal = TextView(this).apply {
            setTextColor(Color.rgb(215, 224, 234))
            textSize = 11.5f
            typeface = Typeface.MONOSPACE
            setPadding(dp(12), dp(10), dp(12), dp(10))
            setTextIsSelectable(true)
            setLineSpacing(0f, 1.12f)
        }
        scroll.addView(
            terminal,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        root.addView(
            scroll,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ).apply { setMargins(0, 0, 0, dp(8)) },
        )

        val commandRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        input = EditText(this).apply {
            hint = "输入命令，例如 apt-get update"
            setHintTextColor(Color.rgb(120, 132, 145))
            setTextColor(Color.WHITE)
            textSize = 13f
            typeface = Typeface.MONOSPACE
            setBackgroundColor(Color.rgb(22, 29, 39))
            setPadding(dp(10), dp(8), dp(10), dp(8))
            maxLines = 3
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE
            imeOptions = EditorInfo.IME_ACTION_DONE
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE) {
                    runCurrent()
                    true
                } else {
                    false
                }
            }
        }
        commandRow.addView(
            input,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        runButton = Button(this).apply {
            text = "运行"
            setTextColor(Color.rgb(20, 20, 20))
            setBackgroundColor(Color.rgb(255, 162, 0))
            setOnClickListener { runCurrent() }
        }
        commandRow.addView(
            runButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { setMargins(dp(8), 0, 0, 0) },
        )
        root.addView(commandRow)

        val quick = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(8), 0, 0)
        }
        quick.addView(quickButton("apt 更新") {
            input.setText("apt-get update")
            runCurrent()
        })
        quick.addView(quickButton("共享目录") {
            val path = "${filesDir.absolutePath}/linux/shared"
            val clip = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clip.setPrimaryClip(ClipData.newPlainText("shared", "/shared（宿主路径）\n$path"))
            Toast.makeText(this, "共享目录路径已复制\n/shared\n$path", Toast.LENGTH_LONG).show()
        })
        installButton = quickButton("重装 Ubuntu") { install(true) }
        quick.addView(installButton)
        quick.addView(quickButton("清屏") {
            terminal.text = ""
        })
        root.addView(quick)

        root.addView(TextView(this).apply {
            text = "提示：首次 apt 操作前先运行 apt-get update；安装软件会占用 /data 空间。"
            setTextColor(Color.rgb(120, 132, 145))
            textSize = 10.5f
            setPadding(0, dp(8), 0, 0)
        })

        return root
    }

    private fun quickButton(label: String, action: () -> Unit): Button {
        return Button(this).apply {
            text = label
            textSize = 11.5f
            setTextColor(Color.rgb(220, 228, 236))
            setBackgroundColor(Color.rgb(28, 37, 49))
            setPadding(dp(10), 0, dp(10), 0)
            setOnClickListener { action() }
            val lp = LinearLayout.LayoutParams(
                0,
                dp(42),
                1f,
            )
            lp.setMargins(dp(2), 0, dp(2), 0)
            layoutParams = lp
        }
    }

    private fun runCurrent() {
        val cmd = input.text.toString().trim()
        if (cmd.isEmpty()) return
        input.setText("")
        append("\n$ $cmd\n")
        runButton.isEnabled = false
        worker.execute {
            val r = runtime.exec(cmd, null, 120_000, null)
            runOnUiThread {
                val out = (r["stdout"]?.toString() ?: "").trim()
                val err = (r["stderr"]?.toString() ?: "").trim()
                if (out.isNotEmpty()) append("$out\n")
                if (err.isNotEmpty()) append("$err\n")
                val code = (r["exitCode"] as? Number)?.toInt() ?: -1
                if (r["ok"] != true) {
                    append("失败：${r["error"] ?: "未知错误"}\n")
                } else {
                    append("[退出码 $code]\n")
                }
                runButton.isEnabled = true
            }
        }
    }

    private fun install(reinstall: Boolean) {
        installButton.isEnabled = false
        status.text = if (reinstall) "正在重装 Ubuntu…" else "正在安装 Ubuntu…"
        worker.execute {
            val r = if (reinstall) runtime.reset() else runtime.install()
            runOnUiThread {
                installButton.isEnabled = true
                if (r["ok"] == true) {
                    status.text = "Ubuntu 已就绪 · /shared 为共享目录"
                    installButton.text = "重装 Ubuntu"
                    append(
                        if (r["alreadyInstalled"] == true) {
                            "Ubuntu 已经安装好了。\n"
                        } else {
                            "Ubuntu 安装完成。先运行 apt-get update。\n"
                        },
                    )
                } else {
                    status.text = "安装失败"
                    append("安装失败：${r["error"] ?: "未知错误"}\n")
                }
            }
        }
    }

    private fun append(text: String) {
        terminal.append(text)
        val scroll = terminal.parent as? ScrollView
        scroll?.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
}
