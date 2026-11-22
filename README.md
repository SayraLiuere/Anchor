# Anchor: AI companion for problematic smartphone use (FYP prototype)

Flutter Android app for my SWE4949 Final Year Project at Universiti Putra Malaysia.
Working thesis title: *AI-Based Health-Oriented Application for Predictive Intervention of Problematic Smartphone Use* (final title to be decided).

Anchor helps university students notice **when and why** they overuse their phone. It combines opt-in screen-time data, quick self-reports and a personal schedule; predicts risk with a Random Forest; and lets a companion, **Mira**, give short, non-clinical support and timely nudges. Everything is stored on the phone.

> **Status (22 Nov 2026):** the core features are built and being tested on a real phone. They live on **feature branches**, not on `main` yet. They will be merged into `main` once testing is finished (around week 10).

## Where the code is

**Want the latest version? Use the branch `d2-calendar-nudge`.** The branches are stacked: each one builds on the one before, so `d2-calendar-nudge` contains every feature below. `main` is still the October baseline.

```
git clone https://github.com/SayraLiuere/Anchor
cd Anchor
git checkout d2-calendar-nudge
```

| Branch | Adds | Thesis |
|---|---|---|
| `main` | October baseline: logging, auto-drafted episodes from long sessions, heuristic risk, Mira chat, insights | Ch. 4 |
| `a1-random-forest` | Trained Random Forest in the app (94.1% accuracy, F1 0.956); heuristic fallback when screen time is off | FR4, 4.2.4, 5.4.2 |
| `a2-usage-snapshots` | Daily and hourly usage history saved locally (Android keeps only ~7 days) | FR25, 3.3.4 |
| `a3-timezone-timestamps` | Every timestamp stored with its UTC offset | 3.3.4 |
| `a4-session-end` | Sessions end at lock / shutdown; checked against Digital Wellbeing (within 2–4%) | FR25, 5.4.5 |
| `e2-export-v2` | Versioned JSON export through the share sheet | FR30 |
| `a5-audio-group` | Music and podcast apps as a neutral group, left out of risk | FR26 |
| `b1-llm-proxy` | Cloudflare Worker proxy so no API key is on the phone; dev keys in secure storage | 5.1 |
| `b2-chat-context` | Mira gets today's usage, averages, risk and recent logs, with names and app names scrubbed | FR5, 5.3.3 |
| `b3-weekly-summary` | Weekly report through the same pipeline | FR5 |
| `c1-schedule-blocks` | Schedule with nested blocks (e.g. a University folder containing classes); logs tagged with their block | FR15–17, 3.5.6 |
| `b4-long-term-memory` | "What Mira remembers": facts saved only after the user confirms | FR22–24, 3.5.10 |
| `c2-personal-baseline` | Comparison with the user's own usual day; suggested limits | FR19, 3.5.8 |
| `c3-context-notes` | Notes from chat (e.g. a tough class, a gentle evening) added to the schedule after confirmation; health notes private | FR18, 3.5.7 |
| `d1-time-risk-grid` | Personal weekday × hour risk map; heads-up nudge ~10 min before usual heavy hours | FR12–13, 3.5.4–3.5.5 |
| `d2-calendar-nudge` | Silent nudge when scrolling during class, with buttons that work without opening the app | 3.5.11 |

Branches are listed in build order. `e2-export-v2` was done early so trial data is exported in its final format from the start. `feature/auto-draft-episodes` is an older branch already merged into `main`.

Each commit message explains what was built, how it was checked, and anything that differs from the plan. The full build plan is in [`docs/IMPLEMENTATION_SPEC.md`](docs/IMPLEMENTATION_SPEC.md) (on the feature branches).

### Still to do

- **D3** one-tap answers ("I'll stop here" / "Keep going") on the remaining alerts
- **D4** if-then plans and **D5** evening review with AI trigger suggestions (if time allows)
- **E1** full test on a real phone, then merge everything into `main`

## Run

```
flutter pub get
flutter run
```

On Windows, keep the project at a short path (e.g. `C:\dev\anchor`). Very long paths break the Gradle and shader build steps.

Update an installed build with `flutter run` or `adb install -r`, never by uninstalling first, or the phone's data is lost. Back up first while it is a debug build:

```
adb exec-out run-as <package> tar c . > anchor_backup.tar
```

## Screen time (opt-in)

Anchor uses Android's **Usage access** (`PACKAGE_USAGE_STATS`) to read app foreground time, opens, unlocks and late-night use. It never sees content. The user grants it from Home ("Let Mira see your screen time"); without it, the app runs on self-reports only.

- `android/.../UsageReader.kt` reads usage events and groups apps into social, video, games, chat, audio or other.
- `android/.../MiraWorker.kt` is a WorkManager job (about every 15 min): limit warnings, long-session nudges, heads-ups, class nudges and a daily reminder.

`PACKAGE_USAGE_STATS` is fine for sideloaded FYP builds. Publishing on Google Play would need a policy declaration.

## AI (Mira)

By default the app talks to the proxy in [`proxy/`](proxy/README.md), a Cloudflare Worker that holds the API key and forwards requests (OpenAI gpt-4.1-mini now, OpenRouter possible). No key is stored on the phone. The proxy address is in `lib/config.dart`. Offline or without the proxy, Mira uses template replies built from the user's own data.

Safety: Mira is not a clinician and never diagnoses. Messages mentioning self-harm get a fixed reply with Malaysian helplines, without calling the AI.

Developer option: Settings → OpenAI (dev) or Gemini (dev), with your own key (kept in Android secure storage).

## Train the model

```
pip install pandas scikit-learn
python ml/train_model.py Smartphone_Usage_And_Addiction_Analysis_7500_Rows.csv
```

This writes `assets/model/rf_model.json` (the app uses it automatically) and `ml/results.txt` (metrics for the thesis).

## Privacy

- All data stays in `second_brain.json` on the phone.
- The AI receives numbers and categories only: no names, app names or note text.
- Private health notes are never sent in detail.
- The export leaves out the display name, chat and any key.

## Tests

```
flutter test        # app
cd proxy && node --test   # proxy
```
