# Anchor: PSU Second Brain (FYP prototype)

Flutter Android app for *AI-Based Health-Oriented Second Brain for Predictive Intervention of Problematic Smartphone Use*.

## How it maps to the thesis
| Thesis | Where |
|---|---|
| FR1–FR3 logging, Table 4.3 schema | `lib/models/log_entry.dart`, `lib/screens/log_screen.dart` |
| Feature mapping (Table 3.1) | `lib/services/features.dart` |
| FR4 risk (heuristic MVP → Random Forest) | `lib/services/risk_model.dart`, `ml/train_model.py` |
| FR5 LLM companion + weekly summary, offline fallback | `lib/services/companion_ai.dart` |
| FR6 dashboards / memory timeline | `lib/screens/insights_screen.dart`, `lib/screens/memory_screen.dart` |
| FR7 companion UI | `lib/screens/home_screen.dart`, `lib/screens/companion_screen.dart` |
| 3.4.6 synthetic demo data (flagged) | `AppState.seedDemoData` |
| 3.8 privacy: local JSON storage, anonymised export | `lib/services/app_state.dart` |

## Run
    flutter pub get
    flutter run

Or install `mira-debug.apk` on a phone.

On Windows, keep the project at a short path (e.g. `C:\dev\mira`). Very long paths break the Gradle and shader build steps.

## Train the model
    pip install pandas scikit-learn
    python ml/train_model.py smartphone_usage_addiction.csv

This writes `assets/model/rf_model.json` (the app switches to it automatically) and `ml/results.txt` (metrics for Table 5.2).

## AI replies
Settings → paste a Gemini API key. Without a key, Mira uses template replies built from your logs.

## Screen time (opt-in)
Mira uses Android's **Usage access** (`PACKAGE_USAGE_STATS`) to read app foreground time, unlocks and late-night use. It never sees content.
The user grants it on the Settings page the app opens (Home → "Let Mira see your screen time").

- `android/.../UsageReader.kt` reads events and groups apps into social, video, games, chat or other.
- `android/.../MiraWorker.kt` is a WorkManager job that runs about every 15 min. It sends limit warnings, doomscroll nudges (one long session) and a daily log reminder.
- Tapping a notification opens the log or check-in sheet.
- With screen time on, real `daily_screen_time_hours`, `social_media_hours`, `gaming_hours` and `app_opens_per_day` go into the Random Forest. Proxies are only used when it's off.

Note: `PACKAGE_USAGE_STATS` is fine for sideloaded FYP builds. Publishing on Google Play would need a policy declaration.

## AI providers
Settings → choose OpenAI (default model `gpt-4.1-mini`) or Gemini, paste a key, then tap **Test connection**. The model name is editable.
Chat uses a playful pet-and-friend persona. Weekly recaps use a professional report persona (`lib/services/companion_ai.dart`).
