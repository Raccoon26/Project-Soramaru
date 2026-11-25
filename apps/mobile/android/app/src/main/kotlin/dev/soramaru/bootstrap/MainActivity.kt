package dev.soramaru.bootstrap

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.soramaru/photos")
            .setMethodCallHandler { call, result ->
                if (call.method != "convertHeic") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.arguments as? ByteArray
                if (bytes == null || bytes.size !in 16..20_971_520 || Build.VERSION.SDK_INT < 28) {
                    result.error("photo_decode", "HEIF is unavailable", null)
                    return@setMethodCallHandler
                }
                thread(name = "soramaru-photo-decode") {
                    try {
                        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
                            val (width, height) = info.size.width to info.size.height
                            check(!info.isAnimated)
                            check(width in 1..16384 && height in 1..16384 && width.toLong() * height <= 64_000_000)
                            val scale = minOf(1.0, 2048.0 / max(width, height))
                            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
                            decoder.setTargetSize(max(1, (width * scale).roundToInt()), max(1, (height * scale).roundToInt()))
                        }
                        val encoded = try {
                            ByteArrayOutputStream().use { output ->
                                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 96, output))
                                output.toByteArray()
                            }
                        } finally {
                            bitmap.recycle()
                        }
                        runOnUiThread { result.success(encoded) }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("photo_decode", "HEIF conversion failed", null) }
                    }
                }
            }
    }
}
