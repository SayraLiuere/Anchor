package my.upm.fyp.psu_second_brain

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingAction: String? = null
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingAction = intent?.getStringExtra(MiraWorker.EXTRA_ACTION)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mira/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasUsagePermission" -> result.success(UsageReader.hasPermission(this))
                "openUsageSettings" -> {
                    val pkgIntent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                        .setData(Uri.parse("package:$packageName"))
                    try {
                        startActivity(pkgIntent)
                    } catch (e: Exception) {
                        // Some phones only support the generic list.
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                    }
                    result.success(null)
                }
                "getUsage" -> {
                    val start = (call.argument<Number>("start"))!!.toLong()
                    val end = (call.argument<Number>("end"))!!.toLong()
                    background(result) { UsageReader.toMap(UsageReader.read(this, start, end)) }
                }
                "getDailyUsage" -> {
                    val days = call.argument<Int>("days") ?: 7
                    background(result) {
                        (days - 1 downTo 0).map { d ->
                            val start = UsageReader.startOfDay(d)
                            val end = if (d == 0) System.currentTimeMillis() else UsageReader.startOfDay(d - 1)
                            UsageReader.toMap(UsageReader.read(this, start, end)) + ("dayStart" to start)
                        }
                    }
                }
                "hasNotificationPermission" -> result.success(notificationsAllowed())
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= 33 && !notificationsAllowed()) {
                        ActivityCompat.requestPermissions(
                            this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7,
                        )
                    }
                    result.success(notificationsAllowed())
                }
                "setConfig" -> {
                    MiraConfig.save(this, call.argument<String>("json") ?: "{}")
                    result.success(null)
                }
                "markLogged" -> {
                    MiraConfig.prefs(this).edit()
                        .putString("lastLogDay", call.argument<String>("day")).apply()
                    result.success(null)
                }
                "testNudge" -> {
                    postNotification(
                        this, 999, MiraWorker.CH_NUDGE,
                        "You've hit your social media limit",
                        "1h 2m on social media today (limit 1h 0m). Mira is wondering what pulled you in. Tap to log it.",
                        "log",
                    )
                    result.success(null)
                }
                "checkNow" -> {
                    // One immediate run of the same background check.
                    androidx.work.WorkManager.getInstance(this).enqueue(
                        androidx.work.OneTimeWorkRequest.Builder(MiraWorker::class.java).build(),
                    )
                    result.success(null)
                }
                "takeLaunchAction" -> {
                    result.success(pendingAction)
                    pendingAction = null
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val action = intent.getStringExtra(MiraWorker.EXTRA_ACTION) ?: return
        channel?.invokeMethod("launchAction", action)
    }

    private fun notificationsAllowed() = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
        PackageManager.PERMISSION_GRANTED

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("usage_error", e.message, null) }
            }
        }
    }
}
