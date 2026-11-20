# Anchor — Implementation Spec for Claude Code

Nov 20, 2026 · @Mary

## How to use this with Claude Code

Export this doc as Markdown, save it in the repo as `docs/IMPLEMENTATION_SPEC.md`, then tell Claude Code: *"Read docs/IMPLEMENTATION\_SPEC.md and implement item A1. Stop after it for me to test."* Work one item at a time, in the order of the work items section, and test on the phone before starting the next.

This spec is based on commit `813f850` (30 Oct). If you have local changes that are not pushed, push them first, or tell Claude Code which items are already done.

**Ground rules for Claude Code**

1. **Never lose user data.** All data lives in `second_brain.json`. Add a `schema_version` field; when new fields are added, read old files with safe defaults. Do not rename or remove existing keys.
2. **Keep fallbacks working.** The app must still run with no screen-time permission, no internet and no API key (heuristic risk model and template replies).
3. **Privacy.** Read usage *times and app categories only*, never content. Never send names, IDs, app names or note text to the LLM; send aggregated numbers and categories ("a social app").
4. **Not clinical.** Keep the existing safety rules and crisis filter in `CompanionAI` unchanged. No diagnosis language.
5. **Small commits.** One commit per work item, message starting with its ID (e.g. `A2: daily and hourly snapshots`). Run `flutter analyze` and `flutter test` before each commit; add a unit test for each new calculation.
6. **Match the thesis.** Each item lists the thesis requirement (FR) and section it implements. If the implementation has to differ, note the difference in the commit message so the thesis can be updated.
7. **Ask before adding dependencies** beyond those named here.

## Repo map (current code)

Flutter app (Dart) with one state class, a single JSON file for storage, and a native Kotlin module for usage data and background notifications.

| Path | What it does | Touched by |
| --- | --- | --- |
| `lib/services/app_state.dart` | `AppState` (Provider): logs, chat, settings, features, risk; `init`, `addLog`, `reactToLog`, `sendToCompanion`, `generateWeeklySummary`, `refreshDevice`, `exportJson`, `_save` (atomic write of `second_brain.json`) | Almost every item |
| `lib/models/log_entry.dart` | `LogEntry`, `ChatMessage`, trigger enum, `isLateNight` (23:00–05:00); timestamps via `toIso8601String()` | A3, D3, D5 |
| `lib/services/features.dart` | `BehaviourFeatures.fromLogs` (7-day window), `ScreenTimeFeatures.fromDaily` | A2, C2, D1 |
| `lib/services/risk_model.dart` | `RiskModel.load()` reads `assets/model/rf_model.json`, else `HeuristicRiskModel`; `ForestRiskModel` with `featureSource` map | A1 |
| `lib/services/companion_ai.dart` | `CompanionAI`: personas, `_safety`, crisis regex, `_openAi` / `_gemini`, template fallback | B1–B4, C3, D4 |
| `lib/services/screen_time.dart` | `ScreenTimeService` (method channel `mira/native`), `NudgeSettings` | A2, A5, D2, D3 |
| `android/.../UsageReader.kt` | Reads `UsageEvents`, groups apps (`describe`), sessions, late-night overlap, unlocks | A2, A4, A5 |
| `android/.../MiraWorker.kt` | WorkManager job (\~15 min): limit warnings, doomscroll nudge, daily reminder | D1–D3 |
| `lib/screens/*.dart` | 8 screens: onboarding, home, companion, log, memory, insights, screen time, settings | C1, C2, D4, E2 |
| `ml/train_model.py` | Trains RF / GB / LR on the Kaggle CSV, exports `rf_model.json` | A1 |
| `test/risk_test.dart`, `test/screen_time_test.dart` | Existing unit tests | Keep green |

Kotlin files live in `android/app/src/main/kotlin/my/upm/fyp/psu_second_brain/`. Dependencies today: `provider`, `path_provider`, `http`, `intl`, `uuid`; Android `work-runtime` 2.9.1.

## Work items

Do them in this order: each group builds on the one before. Each item gives what to change, where, and how to tell it is done.

### A. Foundations

**A1. Random Forest in the app** (FR4, thesis 4.2.4 and 5.3.1)

- Put the provided `rf_model.json` in `assets/model/` and check `pubspec.yaml` lists `assets/model/`. Replace `ml/train_model.py` with the fixed version (text columns checked with `pd.api.types.is_numeric_dtype`).
- In `AppState`, use `ForestRiskModel` only when screen-time features exist (`f.screen != null`); otherwise use `HeuristicRiskModel`. Log-only proxies are too weak for the forest (thesis 5.4.2).
- Show the active model name on Home.
- **Done when:** Home shows "Random Forest" with Usage access on and "Heuristic" with it off; a test covers both paths; existing tests pass.

**A2. Daily and hourly usage snapshots** (FR25, thesis 3.3.4)

- Kotlin: a method-channel call returning, for each complete day in the last N days, minutes per group (social, video, games, audio, chat, other), unlocks and late-night minutes (23:00–05:00), plus minutes per group per hour. Reuse `UsageReader.read` and split sessions at hour and midnight boundaries.
- Dart: store `usage_daily` rows `{date, total_min, social_min, video_min, games_min, audio_min, chat_min, other_min, unlocks, late_night_min}` and `usage_hourly` rows `{date, hour, category, minutes}` (non-zero only) in `second_brain.json`.
- On `init` and `refreshDevice`, backfill any missing complete days from the last 7. Never overwrite a saved day. Today is computed live and saved only once complete.
- `ScreenTimeFeatures.fromDaily` reads the stored rows when they exist.
- **Done when:** after two days, each day has rows that survive an app restart and an update; a test checks a session split across midnight.

**A3. Time zone on every timestamp** (thesis 3.3.4)

- Add a helper that writes local time with offset, e.g. `2026-11-16T12:18:01+08:00`. Use it for log, chat, summary and snapshot timestamps.
- Parsing accepts both forms; an old value without offset is treated as local time.
- **Done when:** a round-trip test passes and an old `second_brain.json` still loads.

**A4. Session end and the 8.8 h/day check** (FR25)

- `UsageReader` already closes a session on `SCREEN_NON_INTERACTIVE`. Also close it on `KEYGUARD_SHOWN`.
- Compare one full day with Android Digital Wellbeing. If Anchor is more than 10% higher, check for double-counted overlapping `ACTIVITY_RESUMED` events and picture-in-picture.
- **Done when:** the gap is 10% or less, or explained. Write the two numbers in the commit message for thesis 5.4.5.

**A5. Audio/Music group** (FR26)

- In `UsageReader.describe`, map `ApplicationInfo.CATEGORY_AUDIO` to a new `audio` group; add known music and podcast packages to `knownGroups`. YouTube stays `video`.
- Show audio in the breakdown, but subtract it from screen time used for risk, and give it no default limit. No user relabelling of apps.
- **Done when:** Spotify shows under Audio, and a test shows audio minutes do not change the risk score.

### B. AI backbone

**B1. LLM proxy** (thesis 5.1)

- A Cloudflare Worker (or Firebase Function) that accepts OpenAI-format chat requests and forwards them to OpenRouter. The OpenRouter key is a server secret only.
- Each install sends a random install ID (UUID made on first launch, stored in the JSON). The Worker allows about 50 calls a day per ID, has a model allowlist and a body-size limit, and does not log message content. Set a credit limit on the OpenRouter key.
- App: add a `proxy` option to `LlmProvider` and make it the default, with no API key needed. Keep direct OpenAI/Gemini as a developer option.
- Model: \[decide which OpenRouter model to use\].
- **Done when:** chat works on a fresh install with no key; the 51st call of the day gets a friendly message; the key is not in the APK.

**B2. Mira chat context** (FR5, thesis 5.3.3)

- Extend the structured context in `CompanionAI.reply`: today's minutes per category, 7-day averages, risk level and reasons, the last 3 logs (time, trigger, mood, stress, craving, resisted; no note text). Once C1, D4 and B4 exist, also add today's block types, active plans and memory facts.
- Keep the last 8 turns, the personas, the safety rules and the crisis filter.
- **Done when:** replies quote a real number from the context, and a test on the prompt builder shows no names, app labels or note text.

**B3. Weekly summary** (FR5)

- Same pipeline as B2 with the recap persona. Add the RF result and, after C2, the comparison with the user's usual week. Keep the Overview / Patterns / Suggestions headings.
- **Done when:** a report generates through the proxy, and the template still works offline.

**B4. Long-term memory** (FR22–FR24, thesis 3.5.10)

- Add `facts` to the JSON: `{id, text, category (preference|trigger|what_helps|pattern), source (chat|rating|weekly), private, created_at, last_confirmed, times_helped}`.
- Ask the LLM to return JSON `{reply, notes[], facts[]}`; if parsing fails, treat the whole response as the reply. Suggested facts show on a confirm card; nothing is saved without a tap.
- Put the 10–15 most relevant facts (matching the current trigger, block or hour, then newest) in the prompt. Private facts are sent only as "a private health note exists".
- Settings gets a "What Mira remembers" list with edit and delete.
- **Done when:** a confirmed fact changes a later reply, and deleting it removes it from prompts.

### C. Schedule and baseline

**C1. Schedule blocks** (FR15–FR17, thesis 3.5.6; wireframes on the design canvas)

- Add `blocks` to the JSON: `{id, title, type (class|study|work|sleep|break|personal|folder), start "HH:mm", end, weekdays [1–7], parent_id?, quiet, cancelled_dates[]}`.
- A Schedule tab with today's list: child blocks nested inside their folder, gaps inside a folder shown as "on campus, free". An add/edit form with title, type, times, weekdays, parent folder and a quiet toggle. No week grid and no .ics import for now.
- A `ScheduleService` with `currentBlock(now)` and `todayLoad()` (hours by type, labelled light, normal or packed). Each new `LogEntry` gets `block_id` and `block_type` when saved.
- Push today's blocks to the Kotlin side (like `pushSettings`) for D1 and D2.
- **Done when:** tests cover `currentBlock` for nested blocks, gaps and midnight, and a log made during class is labelled `class`.

**C2. Personal baseline** (FR19, thesis 3.5.8)

- After 7 or more snapshot days, compute the median per category per weekday; with fewer than 2 samples for that weekday, use the overall median.
- Home shows a card like "Videos +40% vs your usual Monday". Suggested limit = median minus 10%, offered for the user to accept. Large deviations become risk reasons.
- **Done when:** median tests pass and the card stays hidden before day 7.

**C3. Context notes from chat** (FR18, thesis 3.5.7)

- Use `notes[]` from the B4 JSON: `{label, type (health|mood|block_feedback|plan), scope (day|block), block_id?}`. Show an "Add to today?" card with checkboxes; save only on Add.
- Store `{id, date, block_id?, type, label, private, source}`. Show notes as chips on today's schedule. A "gentle evening" plan pauses limit warnings for that night.
- Health notes are private: later prompts only say a health note exists.
- **Done when:** the period-day example from the wireframe saves two chips, and the next prompt contains no health details.

### D. Nudges and logging

**D1. Time-risk grid and pre-emptive nudge** (FR12–FR13, thesis 3.5.4–3.5.5)

- From `usage_hourly` (social + video + games) over the last 14–28 days, compute the mean minutes per weekday × hour. Flag slots above the user's 75th percentile with at least 20 minutes.
- Recompute daily and push the grid to `MiraWorker`. At each run, if a flagged slot starts in the next 10–25 minutes, the user is not in a quiet block, no nudge was sent in the last hour and nudges are not muted, send a heads-up.
- **Done when:** a grid test passes, and with demo data a nudge fires about 10 minutes before the flagged hour.

**D2. Calendar-aware nudge** (thesis 3.5.11)

- In `MiraWorker`: during a class, study or work block (not a folder gap, not the first or last 10 minutes), after 10+ minutes of continuous social, video or games use, send a silent, vibration-only notification. Messaging and audio never trigger it.
- Actions: "No class today" adds today to the block's `cancelled_dates`; "I'm in class" saves a high-risk episode and checks after 5 minutes whether the app was left; "On a break" snoozes 15 minutes, then sends one gentler follow-up.
- **Done when:** each button works from the lock screen without opening the app.

**D3. One-tap answers on alerts** (FR27, thesis 3.5.11)

- Notifications are native in `MiraWorker`, so add the actions there. "I'll stop here" / "Keep going" save an episode (resisted or continued, app group, duration, `source: self`, `nudge_id`) without opening the app.
- A `BroadcastReceiver` writes to a pending queue that the app merges into `second_brain.json` on next open.
- Record a `NudgeEvent` `{id, fired_at, type, group, slot_risk?, response, left_within_10min, minutes_next_30}`; the worker fills the last two afterwards.
- **Done when:** tapping a button logs an episode that appears in Memory after opening the app.

**D4. If-then plans** (FR20–FR21, thesis 3.5.9) \[Should\]

- `{id, trigger or time window, block_type?, action, active, times_offered, times_helped}`, a simple list editor, and active plans matching the current trigger or hour added to Mira's prompt.
- **Done when:** a plan is recalled in Mira's words when its trigger is logged.

**D5. Evening review and AI trigger suggestions** (FR28–FR29) \[Should\]

- After the last block of the day, a notification opens a list of today's sessions of 15+ minutes; the user taps the worst one.
- Suggest a trigger from history (the most common confirmed trigger for the same group and hour ±1). After 3 matching confirmations, save it automatically as `inferred`. Never infer mood or stress. Store `source`, the AI suggestion and the final answer. About 1 in 5 times, ask without a suggestion and record whether they agree.
- **Done when:** the agreement rate can be computed from the stored data.

### E. Wrap-up

**E1. End-to-end test** — full run on the phone, plus the label fix in Small fixes. Back up first: `adb exec-out run-as <package> tar c . > anchor_backup.tar`. Update with `flutter run` or `adb install -r`, never uninstall.

**E2. Export v2** (FR30) \[Should\]

- JSON `{schema_version: 2, exported_at (with offset), app_version, daily[], hourly[], logs[], nudges[]}`, without the display name or any key, shared through `share_plus`.
- **Done when:** the exported file opens and contains the snapshot history.

## Small fixes

These are quick and can go in with the nearest work item.

| Fix | Where | Change |
| --- | --- | --- |
| App name sent to the LLM | `AppState.reactToLog` | Replace `"...min on ${e.appLabel}"` with the app group, e.g. "a video app". Do with B2. |
| API key stored as plain text | `AppState._write` (`apiKey` in `second_brain.json`) | Goes away with the B1 proxy. If direct keys stay as a developer option, store them with `flutter_secure_storage` and drop them from the JSON. |
| Training script crash on newer pandas | `ml/train_model.py` | Use the provided fixed version (A1). |
| Limit label wraps | Screen-time screen | Show `1h 27m / 1h` with spaces, or widen the column (E1). |
| Old thesis numbers in comments and README | `risk_model.dart` ("Section 4.6"), README | Point to thesis 4.2.4 and Table 4.9. |
| Future feature mapping | `ForestRiskModel.featureSource` | No entry for `work_study_hours`. If the model is retrained with it, map it to scheduled class, study and work hours from C1. |

## If time runs short, and when it is done

A1, A2–A4, B1–B2 and C1 must exist: thesis objectives 1, 3 and 4 depend on them. If the week runs out, cut in this order and mark the item "planned" in the thesis:

1. D5 evening review and trigger suggestions
2. E2 export v2 (use `adb` for your own data instead)
3. C3 context notes from chat
4. D4 if-then plans (keep one hard-coded example plan in the prompt)
5. A5 audio group (note it as a limitation)

If B1–B2 are not working by mid-week, pause everything in D except D2 and get the AI working first.

**Each item is done when** its acceptance check passes on the phone, `flutter analyze` and `flutter test` are clean, it is committed and pushed, and its thesis section has lost its shading (Chapter 5 placeholder filled, one or two rows added to the test-case table).
