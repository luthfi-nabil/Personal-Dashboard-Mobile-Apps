package com.example.personal_dashboard

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/// Own subclass so its manifest entry can never clash with the FileProviders
/// that plugins (share_plus, image_picker) declare.
class UpdateFileProvider : FileProvider()

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Native half of lib/core/app_update.dart: what Dart cannot do on its
        // own - read the installed versionCode, hash the downloaded APK, and
        // hand it to the system installer (which always asks the user).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "personal_dashboard/app_update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" -> {
                        @Suppress("DEPRECATION")
                        val info = packageManager.getPackageInfo(packageName, 0)
                        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode
                        else @Suppress("DEPRECATION") info.versionCode.toLong()
                        result.success(mapOf("name" to info.versionName, "code" to code))
                    }
                    "sha256" -> {
                        val path = call.argument<String>("path")!!
                        Thread {
                            try {
                                val digest = MessageDigest.getInstance("SHA-256")
                                File(path).inputStream().use { input ->
                                    val buf = ByteArray(1 shl 16)
                                    while (true) {
                                        val n = input.read(buf)
                                        if (n < 0) break
                                        digest.update(buf, 0, n)
                                    }
                                }
                                val hex = digest.digest().joinToString("") { "%02x".format(it) }
                                runOnUiThread { result.success(hex) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("hash", e.message, null) }
                            }
                        }.start()
                    }
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()
                    )
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT >= 26) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                            )
                        }
                        result.success(null)
                    }
                    "install" -> {
                        try {
                            val file = File(call.argument<String>("path")!!)
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                            startActivity(
                                Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
