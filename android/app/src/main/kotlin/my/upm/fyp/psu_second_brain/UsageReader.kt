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

    /** Music and podcasts (A5): shown, but not counted as screen time for risk or limits. */
    const val AUDIO = "audio"
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
        // Music and podcasts (YouTube itself stays video)
        "com.spotify.music" to AUDIO, "com.google.android.apps.youtube.music" to AUDIO,
        "com.apple.android.music" to AUDIO, "com.soundcloud.android" to AUDIO,
        "com.amazon.mp3" to AUDIO, "deezer.android.app" to AUDIO,
        "com.aspiro.tidal" to AUDIO, "com.joox.joox" to AUDIO,
        "com.shazam.android" to AUDIO, "com.pandora.android" to AUDIO,
        "com.google.android.apps.podcasts" to AUDIO, "au.com.shiftyjelly.pocketcasts" to AUDIO,
        "fm.castbox.audiobook.radio.podcast" to AUDIO, "com.bambuna.podcastaddict" to AUDIO,
        "com.audible.application" to AUDIO, "com.anghami" to AUDIO,
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

    /** [activeMs] is time actually in the app; it differs from end - start after merging. */
    class Session(val pkg: String, val start: Long, val end: Long, val activeMs: Long = end - start)

    class Result(
        val apps: Map<String, AppUsage>,
        val unlocks: Int,
        /** When each unlock happened (for per-day snapshots). */
        val unlockTimes: List<Long>,
        val lateNightMs: Long,
        val longest: Session?,
        /** Session still in the foreground at `end`, if any. */
        val ongoing: Session?,
        val sessions: List<Session>,
    ) {
        fun groupMs(group: String) = apps.values.filter { it.group == group }.sumOf { it.ms }
        val totalMs get() = apps.values.sumOf { it.ms }
        /** Screen time for risk and the total limit: everything except audio (A5). */
        val screenMs get() = totalMs - groupMs(AUDIO)
    }


    /** Groups where a long session usually means doomscrolling or gaming. */
    val PSU_GROUPS = setOf(SOCIAL, VIDEO, GAMES)

    /**
     * Joins sessions of the same app separated by short gaps (e.g. a quick
     * look at a notification) into one "episode", and keeps PSU-relevant ones
     * of at least [minMinutes]. The id (package@start) is stable across reads.
     */
    fun episodes(ctx: Context, r: Result, minMinutes: Int, gapMs: Long = 2 * 60_000L): List<Session> {
        val merged = ArrayList<Session>()
        for (s in r.sessions.sortedBy { it.start }) {
            val last = merged.lastOrNull()
            if (last != null && last.pkg == s.pkg && s.start - last.end <= gapMs) {
                merged[merged.size - 1] = Session(last.pkg, last.start, s.end, last.activeMs + s.activeMs)
            } else {
                merged.add(s)
            }
        }
        return merged.filter {
            describe(ctx, it.pkg).second in PSU_GROUPS && it.activeMs >= minMinutes * 60_000L
        }
    }

    fun episodeMap(ctx: Context, s: Session, ongoing: Session?): Map<String, Any?> {
        val (label, group) = describe(ctx, s.pkg)
        return mapOf(
            "id" to "${s.pkg}@${s.start}", "package" to s.pkg, "label" to label, "group" to group,
            "start" to s.start, "end" to s.end, "minutes" to s.activeMs / 60000.0,
            // Still open if it runs into the session that is in the foreground right now.
            "ongoing" to (ongoing != null && ongoing.pkg == s.pkg && ongoing.end == s.end),
        )
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
                ApplicationInfo.CATEGORY_AUDIO -> AUDIO
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

    /**
     * Events are read from this long before `start`, so a session already
     * running at `start` (e.g. across midnight) is found and counted from
     * `start` on, instead of being missed until the next app switch.
     */
    private const val LOOKBACK_MS = 3 * 3600_000L

    /** A pause not followed by a resume of the same app within this ends the session. */
    private const val PAUSE_GRACE_MS = 3000L

    // Event types added in API 29; the values are inlined, and older phones never send them.
    private const val DEVICE_SHUTDOWN = 26
    private const val DEVICE_STARTUP = 27

    /**
     * Foreground use between [start] and [end], one app at a time.
     *
     * A session ends when another app (or the launcher) comes to the front, the
     * app pauses for more than 3 s, the screen turns off, the lock screen shows,
     * or the phone shuts down. Times in [Result.apps] and late-night minutes are
     * clipped to [start, end); [Result.sessions] keep their real start so draft
     * ids stay stable, and only sessions that reach past [start] are returned.
     */
    fun read(ctx: Context, start: Long, end: Long): Result {
        val usm = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = usm.queryEvents(start - LOOKBACK_MS, end)
        val skip = ignored(ctx)
        val apps = HashMap<String, AppUsage>()
        val sessions = ArrayList<Session>()
        var unlocks = 0
        val unlockTimes = ArrayList<Long>()

        var current: String? = null
        var currentStart = 0L
        var pausedAt = -1L // brief pause inside the same app (activity switch)
        var lastT = start - LOOKBACK_MS

        fun close(at: Long) {
            val pkg = current ?: return
            val from = maxOf(currentStart, start)
            if (at > from) {
                sessions.add(Session(pkg, currentStart, at))
                val (label, group) = describe(ctx, pkg)
                apps.getOrPut(pkg) { AppUsage(pkg, label, group) }.ms += at - from
            }
            current = null
            pausedAt = -1
        }

        fun endAt(t: Long) = close(if (pausedAt >= 0) pausedAt else t)

        val e = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            val t = e.timeStamp
            // Any event long after a pause means the app did not come back.
            if (pausedAt >= 0 && t - pausedAt > PAUSE_GRACE_MS) close(pausedAt)
            when (e.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> {
                    val pkg = e.packageName
                    if (pkg == current) {
                        pausedAt = -1 // same app, keep the session going
                    } else {
                        if (current != null) endAt(t)
                        if (pkg !in skip) {
                            current = pkg
                            currentStart = t
                            if (t >= start) {
                                val (label, group) = describe(ctx, pkg)
                                apps.getOrPut(pkg) { AppUsage(pkg, label, group) }.opens++
                            }
                        }
                    }
                }
                UsageEvents.Event.ACTIVITY_PAUSED -> if (e.packageName == current) pausedAt = t
                UsageEvents.Event.SCREEN_NON_INTERACTIVE,
                UsageEvents.Event.KEYGUARD_SHOWN,
                DEVICE_SHUTDOWN -> endAt(t)
                // Still open at startup: the phone died without a shutdown event,
                // so end it at the last thing we saw before that.
                DEVICE_STARTUP -> endAt(lastT)
                UsageEvents.Event.KEYGUARD_HIDDEN -> if (t >= start) { unlocks++; unlockTimes.add(t) }
            }
            lastT = t
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

        fun clipped(s: Session) = s.end - maxOf(s.start, start)
        return Result(
            apps = apps,
            unlocks = unlocks,
            unlockTimes = unlockTimes,
            // Audio is not screen use (A5), so it never counts as late-night use.
            lateNightMs = sessions.filter { describe(ctx, it.pkg).second != AUDIO }
                .sumOf { lateNightOverlap(maxOf(it.start, start), it.end) },
            longest = sessions.maxByOrNull { clipped(it) }?.let { Session(it.pkg, maxOf(it.start, start), it.end) },
            ongoing = ongoing,
            sessions = sessions,
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

    /**
     * Raw sessions for daily and hourly snapshots (A2): group and times only,
     * no package or label. Dart splits them at hour and midnight boundaries.
     */
    fun sessionsMap(ctx: Context, r: Result): Map<String, Any?> = mapOf(
        "sessions" to r.sessions.map {
            mapOf("group" to describe(ctx, it.pkg).second, "start" to it.start, "end" to it.end)
        },
        "unlocks" to r.unlockTimes,
    )

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
        "audioMinutes" to r.groupMs(AUDIO) / 60000.0,
        "unlocks" to r.unlocks,
        "opens" to r.apps.values.sumOf { it.opens },
        "lateNightMinutes" to r.lateNightMs / 60000.0,
        "longestSessionMinutes" to (r.longest?.let { (it.end - it.start) / 60000.0 } ?: 0.0),
        "longestSessionApp" to r.longest?.let { r.apps[it.pkg]?.label },
    )
}
