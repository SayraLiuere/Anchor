package my.upm.fyp.psu_second_brain

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import java.util.Calendar

/**
 * Reads foreground app usage from UsageStatsManager events (opt-in "Usage access").
 * Shared by the Flutter channel (MainActivity) and the background watcher (MiraWorker),
 * so both use the same app grouping and session logic.
 */
object UsageReader {

    /** App groups that matter for PSU (thesis dataset: social_media_hours, gaming_hours). */
    const val SOCIAL = "social"
    const val VIDEO = "video"
    const val GAMES = "games"
    const val CHAT = "chat"
    const val OTHER = "other"

    private val knownGroups = mapOf(
        // Social media
        "com.instagram.android" to SOCIAL, "com.instagram.barcelona" to SOCIAL,
        "com.facebook.katana" to SOCIAL, "com.facebook.lite" to SOCIAL,
        "com.zhiliaoapp.musically" to SOCIAL, "com.ss.android.ugc.trill" to SOCIAL,
        "com.twitter.android" to SOCIAL, "com.reddit.frontpage" to SOCIAL,
        "com.snapchat.android" to SOCIAL, "com.pinterest" to SOCIAL,
        "com.linkedin.android" to SOCIAL, "com.tumblr" to SOCIAL,
        "xyz.blueskyweb.app" to SOCIAL, "com.xingin.xhs" to SOCIAL,
        // Video / streaming
        "com.google.android.youtube" to VIDEO, "com.netflix.mediaclient" to VIDEO,
        "tv.twitch.android.app" to VIDEO, "com.disney.disneyplus" to VIDEO,
        "com.amazon.avod.thirdpartyclient" to VIDEO, "tv.danmaku.bili" to VIDEO,
        "com.viu.phone" to VIDEO, "com.iqiyi.i18n" to VIDEO,
        // Messaging
        "com.whatsapp" to CHAT, "com.whatsapp.w4b" to CHAT,
        "org.telegram.messenger" to CHAT, "com.discord" to CHAT,
        "com.facebook.orca" to CHAT, "jp.naver.line.android" to CHAT,
        "com.google.android.apps.messaging" to CHAT, "com.tencent.mm" to CHAT,
    )

    fun hasPermission(ctx: Context): Boolean {
        val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= 29) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    class AppUsage(val pkg: String, val label: String, val group: String) {
        var ms = 0L
        var opens = 0
    }

    class Session(val pkg: String, val start: Long, val end: Long)

    class Result(
        val apps: Map<String, AppUsage>,
        val unlocks: Int,
        val lateNightMs: Long,
        val longest: Session?,
        /** Session still in the foreground at `end`, if any. */
        val ongoing: Session?,
    ) {
        fun groupMs(group: String) = apps.values.filter { it.group == group }.sumOf { it.ms }
        val totalMs get() = apps.values.sumOf { it.ms }
    }

    private val groupCache = java.util.concurrent.ConcurrentHashMap<String, Pair<String, String>>()

    fun describe(ctx: Context, pkg: String): Pair<String, String> = groupCache.getOrPut(pkg) {
        val pm = ctx.packageManager
        try {
            val info = pm.getApplicationInfo(pkg, 0)
            val label = pm.getApplicationLabel(info).toString()
            val group = knownGroups[pkg] ?: when (if (Build.VERSION.SDK_INT >= 26) info.category else -1) {
                ApplicationInfo.CATEGORY_GAME -> GAMES
                ApplicationInfo.CATEGORY_SOCIAL -> SOCIAL
                ApplicationInfo.CATEGORY_VIDEO -> VIDEO
                else -> if (Build.VERSION.SDK_INT < 26 &&
                    (info.flags and ApplicationInfo.FLAG_IS_GAME) != 0) GAMES else OTHER
            }
            label to group
        } catch (e: PackageManager.NameNotFoundException) {
            pkg to (knownGroups[pkg] ?: OTHER)
        }
    }

    private fun ignored(ctx: Context): Set<String> {
        // Only the default launcher: Settings also declares a (fallback) HOME activity.
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val launcher = ctx.packageManager
            .resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
        return setOfNotNull(
            launcher, ctx.packageName, "com.android.systemui", "android",
            "com.google.android.permissioncontroller", "com.android.permissioncontroller",
        )
    }

    fun read(ctx: Context, start: Long, end: Long): Result {
        val usm = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = usm.queryEvents(start, end)
        val skip = ignored(ctx)
        val apps = HashMap<String, AppUsage>()
        val sessions = ArrayList<Session>()
        var unlocks = 0

        var current: String? = null
        var currentStart = 0L
        var pausedAt = -1L // brief pause inside the same app (activity switch)

        fun close(at: Long) {
            val pkg = current ?: return
            if (at > currentStart) {
                sessions.add(Session(pkg, currentStart, at))
                val (label, group) = describe(ctx, pkg)
                apps.getOrPut(pkg) { AppUsage(pkg, label, group) }.ms += at - currentStart
            }
            current = null
            pausedAt = -1
        }

        val e = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            val t = e.timeStamp
            when (e.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> {
                    val pkg = e.packageName
                    if (pkg == current) {
                        pausedAt = -1 // same app, keep the session going
                    } else {
                        if (current != null) close(if (pausedAt >= 0) pausedAt else t)
                        if (pkg !in skip) {
                            current = pkg
                            currentStart = t
                            val (label, group) = describe(ctx, pkg)
                            apps.getOrPut(pkg) { AppUsage(pkg, label, group) }.opens++
                        }
                    }
                }
                UsageEvents.Event.ACTIVITY_PAUSED -> if (e.packageName == current) pausedAt = t
                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> close(if (pausedAt >= 0) pausedAt else t)
                UsageEvents.Event.KEYGUARD_HIDDEN -> unlocks++
            }
            // A pause that isn't followed by a resume of the same app within 3 s ends the session.
            if (pausedAt >= 0 && t - pausedAt > 3000) close(pausedAt)
        }

        var ongoing: Session? = null
        if (current != null) {
            if (pausedAt >= 0) {
                close(pausedAt)
            } else {
                ongoing = Session(current!!, currentStart, end)
                close(end)
            }
        }

        return Result(
            apps = apps,
            unlocks = unlocks,
            lateNightMs = sessions.sumOf { lateNightOverlap(it.start, it.end) },
            longest = sessions.maxByOrNull { it.end - it.start },
            ongoing = ongoing,
        )
    }

    /** Milliseconds of [start, end) that fall between 23:00 and 05:00. */
    private fun lateNightOverlap(start: Long, end: Long): Long {
        var total = 0L
        val cal = Calendar.getInstance().apply { timeInMillis = start }
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        cal.add(Calendar.DAY_OF_YEAR, -1)
        while (cal.timeInMillis < end) {
            val windowStart = cal.timeInMillis + 23 * 3600_000L
            val windowEnd = windowStart + 6 * 3600_000L
            total += maxOf(0L, minOf(end, windowEnd) - maxOf(start, windowStart))
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        return total
    }

    fun startOfDay(daysAgo: Int = 0): Long = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        add(Calendar.DAY_OF_YEAR, -daysAgo)
    }.timeInMillis

    fun toMap(r: Result): Map<String, Any?> = mapOf(
        "apps" to r.apps.values.filter { it.ms > 0 }.sortedByDescending { it.ms }.map {
            mapOf("package" to it.pkg, "label" to it.label, "group" to it.group,
                "minutes" to it.ms / 60000.0, "opens" to it.opens)
        },
        "totalMinutes" to r.totalMs / 60000.0,
        "socialMinutes" to r.groupMs(SOCIAL) / 60000.0,
        "videoMinutes" to r.groupMs(VIDEO) / 60000.0,
        "gamesMinutes" to r.groupMs(GAMES) / 60000.0,
        "chatMinutes" to r.groupMs(CHAT) / 60000.0,
        "unlocks" to r.unlocks,
        "opens" to r.apps.values.sumOf { it.opens },
        "lateNightMinutes" to r.lateNightMs / 60000.0,
        "longestSessionMinutes" to (r.longest?.let { (it.end - it.start) / 60000.0 } ?: 0.0),
        "longestSessionApp" to r.longest?.let { r.apps[it.pkg]?.label },
    )
}
