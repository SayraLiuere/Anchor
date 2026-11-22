package my.upm.fyp.psu_second_brain

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Data
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Answers given from notifications while the app is closed (D2, later D3).
 * The app takes and merges them into second_brain.json on its next open
 * (lib/services/focus.dart applyPending).
 */
object PendingQueue {
    private const val KEY = "pendingQueue"

    @Synchronized
    fun add(ctx: Context, e: JSONObject) {
        val prefs = MiraConfig.prefs(ctx)
        val arr = JSONArray(prefs.getString(KEY, "[]") ?: "[]")
        arr.put(e)
        prefs.edit().putString(KEY, arr.toString()).commit()
    }

    @Synchronized
    fun take(ctx: Context): String {
        val prefs = MiraConfig.prefs(ctx)
        val s = prefs.getString(KEY, "[]") ?: "[]"
        prefs.edit().putString(KEY, "[]").commit()
        return s
    }
}

/**
 * Calendar-aware nudge (D2, thesis 3.5.11). The app sends the next week's
 * class, study and work ranges (focusPlan); this applies the same rule as
 * calendarNudgeDue in lib/services/focus.dart: inside a range but not its
 * first or last 10 minutes, after 10+ minutes of continuous social, video or
 * game use. Silent and vibration-only; once per block occurrence.
 */
object FocusNudge {
    const val CH_FOCUS = "mira_focus"
    const val NOTIF_ID = 600
    private const val EDGE_MS = 10 * 60_000L
    private const val USE_MS = 10 * 60_000L

    const val A_NO_CLASS = "my.upm.fyp.psu_second_brain.NO_CLASS"
    const val A_IN_CLASS = "my.upm.fyp.psu_second_brain.IN_CLASS"
    const val A_ON_BREAK = "my.upm.fyp.psu_second_brain.ON_BREAK"

    private val groupWords = mapOf(
        UsageReader.SOCIAL to "a social app", UsageReader.VIDEO to "a video app", UsageReader.GAMES to "a game",
    )
    private val typeWords = mapOf("class" to "class", "study" to "study time", "work" to "work")

    fun check(ctx: Context, now: Long) {
        val prefs = MiraConfig.prefs(ctx)
        if (now < prefs.getLong("focusSnoozeUntil", 0L)) return
        val ranges = try {
            JSONObject(prefs.getString("focusPlan", "{}") ?: "{}").optJSONArray("ranges")
        } catch (e: Exception) {
            null
        } ?: return
        val r = UsageReader.read(ctx, now - 6 * 3600_000L, now)
        val s = r.ongoing ?: return
        val group = UsageReader.describe(ctx, s.pkg).second
        if (group !in UsageReader.PSU_GROUPS) return // messaging and audio never count
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(now))

        for (i in 0 until ranges.length()) {
            val b = ranges.getJSONObject(i)
            val start = b.getLong("start")
            val end = b.getLong("end")
            if (now < start + EDGE_MS || now > end - EDGE_MS) continue
            if (now - maxOf(s.start, start) < USE_MS) continue
            val blockId = b.getString("block_id")
            if (prefs.getBoolean("focusSkip_${blockId}_$day", false)) continue
            val key = "focus_${blockId}_$start"
            if (prefs.getBoolean(key, false)) continue
            prefs.edit().putBoolean(key, true).apply()

            val type = b.optString("type", "class")
            val nudgeId = UUID.randomUUID().toString()
            PendingQueue.add(ctx, JSONObject()
                .put("kind", "nudge").put("id", nudgeId).put("fired_at", now)
                .put("type", "calendar").put("group", group).put("block_type", type))
            val minutes = (now - maxOf(s.start, start)) / 60_000
            val extras = Bundle(nudgeId, blockId, type, day, start, end, s.pkg, s.start, group)
            show(
                ctx,
                title = "$minutes min on ${groupWords[group]} during ${typeWords[type] ?: type}",
                text = "${MiraConfig.load(ctx).petName} noticed. What's going on?",
                actions = listOf(
                    (if (type == "class") "No class today" else "Not on today") to A_NO_CLASS,
                    (if (type == "class") "I'm in class" else "I'm on it") to A_IN_CLASS,
                    "On a break" to A_ON_BREAK,
                ),
                extras = extras,
            )
            prefs.edit().putLong("lastNudgeAt", now).apply()
            return
        }
    }

    /** What the buttons need to know about the nudge. */
    data class Bundle(
        val nudgeId: String, val blockId: String, val type: String, val day: String,
        val blockStart: Long, val blockEnd: Long, val pkg: String, val sessionStart: Long, val group: String,
    ) {
        fun into(i: Intent): Intent = i.putExtra("nudge_id", nudgeId).putExtra("block_id", blockId)
            .putExtra("type", type).putExtra("day", day).putExtra("block_start", blockStart)
            .putExtra("block_end", blockEnd).putExtra("pkg", pkg).putExtra("session_start", sessionStart)
            .putExtra("group", group)

        companion object {
            fun from(i: Intent) = Bundle(
                i.getStringExtra("nudge_id") ?: "", i.getStringExtra("block_id") ?: "",
                i.getStringExtra("type") ?: "class", i.getStringExtra("day") ?: "",
                i.getLongExtra("block_start", 0), i.getLongExtra("block_end", 0),
                i.getStringExtra("pkg") ?: "", i.getLongExtra("session_start", 0),
                i.getStringExtra("group") ?: "",
            )
        }
    }

    fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_FOCUS, "Class nudges", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Silent, vibration-only nudges when you scroll during class, study or work"
                setSound(null, null)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 250, 150, 250)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            },
        )
    }

    fun show(
        ctx: Context, title: String, text: String,
        actions: List<Pair<String, String>>, extras: Bundle?, id: Int = NOTIF_ID,
    ) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        ensureChannel(ctx)
        val open = PendingIntent.getActivity(
            ctx, id, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = NotificationCompat.Builder(ctx, CH_FOCUS)
            .setSmallIcon(R.drawable.ic_stat_mira)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setAutoCancel(true)
            // No app or block names in the text, so it can show on the lock screen.
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setSound(null)
            .setVibrate(longArrayOf(0, 250, 150, 250))
        actions.forEachIndexed { n, (label, action) ->
            val i = Intent(ctx, FocusActionReceiver::class.java).setAction(action)
            extras?.into(i)
            val pi = PendingIntent.getBroadcast(
                ctx, id * 10 + n, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            b.addAction(0, label, pi)
        }
        NotificationManagerCompat.from(ctx).notify(id, b.build())
    }
}

/** Handles the buttons without opening the app, also from the lock screen. */
class FocusActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val x = FocusNudge.Bundle.from(intent)
        val now = System.currentTimeMillis()
        NotificationManagerCompat.from(ctx).cancel(FocusNudge.NOTIF_ID)
        fun respond(r: String) = PendingQueue.add(ctx, JSONObject()
            .put("kind", "response").put("nudge_id", x.nudgeId).put("response", r).put("at", now))

        when (intent.action) {
            FocusNudge.A_NO_CLASS -> {
                // Skip this block today, here and (once merged) in the app's schedule.
                respond("no_class")
                PendingQueue.add(ctx, JSONObject()
                    .put("kind", "cancel_block").put("block_id", x.blockId).put("date", x.day))
                MiraConfig.prefs(ctx).edit().putBoolean("focusSkip_${x.blockId}_${x.day}", true).apply()
            }
            FocusNudge.A_IN_CLASS -> {
                respond("in_class")
                PendingQueue.add(ctx, JSONObject()
                    .put("kind", "episode").put("id", UUID.randomUUID().toString()).put("at", now)
                    .put("group", x.group).put("minutes", (now - maxOf(x.sessionStart, x.blockStart)) / 60_000)
                    .put("block_id", x.blockId).put("block_type", x.type).put("nudge_id", x.nudgeId))
                later(ctx, FocusCheckWorker::class.java, 5, x)
            }
            FocusNudge.A_ON_BREAK -> {
                respond("on_break")
                MiraConfig.prefs(ctx).edit().putLong("focusSnoozeUntil", now + 15 * 60_000L).apply()
                later(ctx, FocusBreakWorker::class.java, 15, x)
            }
        }
    }

    private fun later(ctx: Context, cls: Class<out Worker>, minutes: Long, x: FocusNudge.Bundle) {
        val data = Data.Builder()
            .putString("nudge_id", x.nudgeId).putString("pkg", x.pkg).putLong("session_start", x.sessionStart)
            .putLong("block_end", x.blockEnd).putString("type", x.type).putString("group", x.group)
            .build()
        WorkManager.getInstance(ctx).enqueue(
            OneTimeWorkRequest.Builder(cls).setInitialDelay(minutes, TimeUnit.MINUTES).setInputData(data).build(),
        )
    }
}

/** "I'm in class": 5 minutes later, has the user left that app? */
class FocusCheckWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val now = System.currentTimeMillis()
        val pkg = inputData.getString("pkg") ?: return Result.success()
        val r = UsageReader.read(applicationContext, now - 6 * 3600_000L, now)
        // Same app in front now. Not the same session: opening the shade or locking
        // the screen splits a session, which is not leaving the app.
        val stillThere = r.ongoing?.pkg == pkg
        PendingQueue.add(applicationContext, JSONObject()
            .put("kind", "left_check").put("nudge_id", inputData.getString("nudge_id")).put("left", !stillThere))
        return Result.success()
    }
}

/** "On a break": after 15 minutes, one gentler follow-up if still scrolling in class. */
class FocusBreakWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val ctx = applicationContext
        val now = System.currentTimeMillis()
        val end = inputData.getLong("block_end", 0)
        if (now > end - 10 * 60_000L) return Result.success() // block is (nearly) over
        val r = UsageReader.read(ctx, now - 6 * 3600_000L, now)
        val s = r.ongoing ?: return Result.success()
        if (UsageReader.describe(ctx, s.pkg).second !in UsageReader.PSU_GROUPS) return Result.success()
        val until = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(end))
        PendingQueue.add(ctx, JSONObject()
            .put("kind", "nudge").put("id", UUID.randomUUID().toString()).put("fired_at", now)
            .put("type", "calendar_followup").put("group", UsageReader.describe(ctx, s.pkg).second)
            .put("block_type", inputData.getString("type")))
        FocusNudge.show(
            ctx,
            title = "Break still going?",
            text = "No pressure, just a gentle tap. ${inputData.getString("type") ?: "Class"} runs until $until.",
            actions = emptyList(),
            extras = null,
            id = FocusNudge.NOTIF_ID + 1,
        )
        MiraConfig.prefs(ctx).edit().putLong("lastNudgeAt", now).apply()
        return Result.success()
    }
}
