package my.upm.fyp.psu_second_brain

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

/** Settings pushed from Flutter (see lib/services/screen_time.dart). */
class MiraConfig(json: JSONObject) {
    val warnings = json.optBoolean("warningsEnabled", true)
    val limits: Map<String, Int> = json.optJSONObject("limits")?.let { o ->
        o.keys().asSequence().associateWith { o.getInt(it) }
    } ?: mapOf(UsageReader.SOCIAL to 60, UsageReader.GAMES to 60, UsageReader.VIDEO to 90, "total" to 300)
    val sessionMinutes = json.optInt("sessionMinutes", 30)
    val logReminder = json.optBoolean("logReminder", true)
    val reminderHour = json.optInt("reminderHour", 21)
    val petName = json.optString("petName", "Mira")
    val askAfterSession = json.optBoolean("askAfterSession", true)
    val draftMinutes = json.optInt("draftMinutes", 15)

    val anyEnabled get() = warnings || logReminder

    companion object {
        private const val PREFS = "mira_native"

        fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun load(ctx: Context) = MiraConfig(JSONObject(prefs(ctx).getString("config", "{}") ?: "{}"))

        fun save(ctx: Context, json: String) {
            prefs(ctx).edit().putString("config", json).apply()
            schedule(ctx, MiraConfig(JSONObject(json)))
        }

        fun schedule(ctx: Context, cfg: MiraConfig) {
            val wm = WorkManager.getInstance(ctx)
            if (!cfg.anyEnabled) {
                wm.cancelUniqueWork(MiraWorker.NAME)
                return
            }
            // 15 minutes is the shortest interval Android allows for periodic background work.
            val req = PeriodicWorkRequest.Builder(MiraWorker::class.java, 15, TimeUnit.MINUTES).build()
            wm.enqueueUniquePeriodicWork(MiraWorker.NAME, ExistingPeriodicWorkPolicy.KEEP, req)
        }
    }
}

/** Runs every ~15 minutes: screen-time warnings, doomscroll nudges and log reminders. */
class MiraWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {

    companion object {
        const val NAME = "mira_watch"
        const val CH_NUDGE = "mira_nudges"
        const val CH_REMIND = "mira_reminders"
        const val EXTRA_ACTION = "mira_action"
    }

    private val ctx get() = applicationContext
    private val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    override fun doWork(): Result {
        val cfg = MiraConfig.load(ctx)
        val prefs = MiraConfig.prefs(ctx)
        val now = System.currentTimeMillis()

        if (cfg.warnings && UsageReader.hasPermission(ctx)) {
            val r = UsageReader.read(ctx, UsageReader.startOfDay(), now)
            val names = mapOf(
                UsageReader.SOCIAL to "social media", UsageReader.GAMES to "games",
                UsageReader.VIDEO to "videos", "total" to "your phone",
            )
            for ((group, limit) in cfg.limits) {
                if (limit <= 0) continue
                val minutes = (if (group == "total") r.totalMs else r.groupMs(group)) / 60000
                // Warn when the limit is crossed, and once more at double the limit.
                val level = when {
                    minutes >= limit * 2 -> 2
                    minutes >= limit -> 1
                    else -> 0
                }
                val key = "warned_${group}_$today"
                if (level > prefs.getInt(key, 0)) {
                    prefs.edit().putInt(key, level).apply()
                    val what = names[group] ?: group
                    notify(
                        id = 100 + Math.floorMod(group.hashCode(), 50),
                        channel = CH_NUDGE,
                        title = if (level == 1) "You've hit your $what limit" else "Still going on $what…",
                        text = "${fmt(minutes)} on $what today (limit ${fmt(limit.toLong())}). " +
                            "${cfg.petName} is wondering what pulled you in. Tap to log it.",
                        action = "log",
                    )
                }
            }

            val s = r.ongoing
            if (s != null) {
                val (label, group) = UsageReader.describe(ctx, s.pkg)
                val mins = (s.end - s.start) / 60000
                val key = "session_${s.pkg}_${s.start}"
                if (group in setOf(UsageReader.SOCIAL, UsageReader.VIDEO, UsageReader.GAMES) &&
                    mins >= cfg.sessionMinutes && !prefs.getBoolean(key, false)
                ) {
                    prefs.edit().putBoolean(key, true).apply()
                    notify(
                        id = 200,
                        channel = CH_NUDGE,
                        title = "${fmt(mins)} on $label straight",
                        text = "Might be a good moment for a little break. ${cfg.petName} misses you 🐾",
                        action = "log",
                    )
                }
            }
        }

        // Right after a long session ends, ask what pulled the user in. The tap opens
        // the auto-drafted episode, so logging is one or two taps.
        if (cfg.askAfterSession && UsageReader.hasPermission(ctx)) {
            val r = UsageReader.read(ctx, now - 6 * 3600_000L, now)
            val lastAsk = prefs.getLong("lastDraftAsk", 0L)
            val fresh = UsageReader.episodes(ctx, r, cfg.draftMinutes).filter { s ->
                val ongoing = r.ongoing?.let { it.pkg == s.pkg && it.end == s.end } ?: false
                !ongoing && now - s.end <= 60 * 60_000L &&
                    !prefs.getBoolean("asked_${s.pkg}@${s.start}", false)
            }
            val s = fresh.maxByOrNull { it.end }
            // At most one of these every 45 minutes, so it never feels like nagging.
            if (s != null && now - lastAsk >= 45 * 60_000L) {
                val id = "${s.pkg}@${s.start}"
                prefs.edit().putBoolean("asked_$id", true).putLong("lastDraftAsk", now).apply()
                val (label, _) = UsageReader.describe(ctx, s.pkg)
                notify(
                    id = 400,
                    channel = CH_NUDGE,
                    title = "${fmt((s.activeMs + 30_000) / 60000)} on $label",
                    text = "${cfg.petName} saved it for you. What pulled you in? It only takes a tap.",
                    action = "draft:$id",
                )
            }
        }

        if (cfg.logReminder) {
            val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
            val loggedToday = prefs.getString("lastLogDay", "") == today
            val remindedToday = prefs.getString("remindedDay", "") == today
            if (hour >= cfg.reminderHour && !loggedToday && !remindedToday) {
                prefs.edit().putString("remindedDay", today).apply()
                notify(
                    id = 300,
                    channel = CH_REMIND,
                    title = "${cfg.petName} wants to hear about your day",
                    text = "How did your phone habits go today? A 20-second check-in helps me learn.",
                    action = "checkin",
                )
            }
        }
        return Result.success()
    }

    private fun fmt(min: Long) = if (min >= 60) "${min / 60}h ${min % 60}m" else "${min}m"

    private fun notify(id: Int, channel: String, title: String, text: String, action: String) =
        postNotification(ctx, id, channel, title, text, action)
}

fun postNotification(ctx: Context, id: Int, channel: String, title: String, text: String, action: String) {
    if (Build.VERSION.SDK_INT >= 33 &&
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
        PackageManager.PERMISSION_GRANTED
    ) return
    ensureChannels(ctx)
    val intent = Intent(ctx, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        putExtra(MiraWorker.EXTRA_ACTION, action)
    }
    val pi = PendingIntent.getActivity(
        ctx, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val n = NotificationCompat.Builder(ctx, channel)
        .setSmallIcon(R.drawable.ic_stat_mira)
        .setContentTitle(title)
        .setContentText(text)
        .setStyle(NotificationCompat.BigTextStyle().bigText(text))
        .setContentIntent(pi)
        .setAutoCancel(true)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        .build()
    NotificationManagerCompat.from(ctx).notify(id, n)
}

fun ensureChannels(ctx: Context) {
    if (Build.VERSION.SDK_INT < 26) return
    val nm = ctx.getSystemService(NotificationManager::class.java)
    nm.createNotificationChannel(
        NotificationChannel(MiraWorker.CH_NUDGE, "Screen-time nudges", NotificationManager.IMPORTANCE_DEFAULT)
            .apply { description = "Warnings when you pass your limits or scroll for a long time" },
    )
    nm.createNotificationChannel(
        NotificationChannel(MiraWorker.CH_REMIND, "Log reminders", NotificationManager.IMPORTANCE_DEFAULT)
            .apply { description = "Daily reminder to check in with Mira" },
    )
}
