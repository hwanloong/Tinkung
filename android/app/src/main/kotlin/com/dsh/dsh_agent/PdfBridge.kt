package com.dsh.dsh_agent

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * PDF 页面渲染。
 *
 * ChangeWhatYouThink 要在 PDF 上框选，而 Dart 侧没有 PDF 渲染器；
 * Android 自带的 [PdfRenderer] 足够把页面画成位图，不需要额外依赖。
 *
 * 只做两件事：pageCount / renderPage。所有失败都返回明确错误，
 * 让 Dart 侧能显示"这个 PDF 打不开（可能加密）"。
 */
class PdfBridge {
    companion object {
        const val CHANNEL = "dsh/pdf"
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: ""
        if (path.isBlank() || !File(path).exists()) {
            result.error("pdf", "文件不存在", null)
            return
        }
        when (call.method) {
            "pageCount" -> {
                try {
                    withRenderer(path) { r -> result.success(r.pageCount) }
                } catch (e: Throwable) {
                    result.error("pdf", "打不开 PDF：${e.message}", null)
                }
            }

            "renderPage" -> {
                val index = call.argument<Int>("index") ?: 0
                val maxWidth = (call.argument<Int>("maxWidth") ?: 1400).coerceIn(480, 2400)
                try {
                    withRenderer(path) { renderer ->
                        if (index < 0 || index >= renderer.pageCount) {
                            result.error("pdf", "页码超出范围", null)
                            return@withRenderer
                        }
                        val page = renderer.openPage(index)
                        try {
                            val scale = minOf(
                                2.5f,
                                maxWidth.toFloat() / page.width.toFloat().coerceAtLeast(1f)
                            )
                            val w = (page.width * scale).toInt().coerceAtLeast(1)
                            val h = (page.height * scale).toInt().coerceAtLeast(1)
                            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                            bitmap.eraseColor(Color.WHITE)
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            val out = ByteArrayOutputStream()
                            bitmap.compress(Bitmap.CompressFormat.PNG, 92, out)
                            bitmap.recycle()
                            result.success(
                                mapOf(
                                    "bytes" to out.toByteArray(),
                                    "width" to w,
                                    "height" to h,
                                    "pageCount" to renderer.pageCount,
                                )
                            )
                        } finally {
                            page.close()
                        }
                    }
                } catch (e: Throwable) {
                    result.error("pdf", "渲染失败：${e.message}", null)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun <T> withRenderer(path: String, block: (PdfRenderer) -> T): T {
        val pfd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = try {
            PdfRenderer(pfd)
        } catch (e: Throwable) {
            pfd.close()
            throw e
        }
        return try {
            block(renderer)
        } finally {
            renderer.close()
            pfd.close()
        }
    }
}