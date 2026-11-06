# FitSync

Personal iOS app that copies Fitbit data from the **Google Health API** into **Apple Health**, one way, without ever duplicating anything.

Synced: workout calories and distance (as plain samples over the workout, so they count toward the Move ring), all-day active energy, steps, sleep stages.
Not synced: the workouts themselves and heart rate. Google Health's own Apple Health sharing writes those; FitSync only adds the workout data that sharing leaves out.

## Setup (about 20 minutes)

1. **Google Cloud console** (console.cloud.google.com)
   - Create a project and enable **Google Health API**.
   - OAuth consent screen: user type *External*; add your Google account under *Test users*; add the scopes
     `googlehealth.activity_and_fitness.readonly`, `googlehealth.health_metrics_and_measurements.readonly`, `googlehealth.sleep.readonly`.
   - Click **Publish app** ("In production"). Unverified apps are allowed up to 100 users. In "Testing" status the sign-in expires every 7 days.
   - Credentials → Create OAuth client → type **iOS**, with the bundle id you will put in `APP_BUNDLE_ID`.
2. **Config.xcconfig**: `cp Config.example.xcconfig Config.xcconfig` (it is git-ignored), set `APP_BUNDLE_ID`, then paste the client id into `GOOGLE_CLIENT_ID` and the "iOS URL scheme" (reversed client id) into `GOOGLE_REDIRECT_SCHEME`. Optionally set `DEVELOPMENT_TEAM`.
3. **Generate the Xcode project** on your Mac:
   ```sh
   brew install xcodegen
   cd FitSync
   xcodegen generate
   open FitSync.xcodeproj
   ```
4. Select your iPhone, set your team under *Signing & Capabilities* if needed, and Run. Run the tests with ⌘U.
5. In the **Google Health app**, keep Apple Health sharing **on** for workouts and heart rate, and turn it **off** for activity and sleep (FitSync writes those).

A free Apple ID works, but the app must be re-installed from Xcode every 7 days. A paid developer account removes that.
To automate it, pair the iPhone with "Connect via network" in Xcode and run `scripts/auto-resign.sh install`: a launchd agent checks every 4 hours and rebuilds and reinstalls over Wi-Fi once a day (log: `~/Library/Logs/FitSync-resign.log`).

## How duplicates are prevented

| Layer | What it does |
| --- | --- |
| HealthKit sync identifiers | Every object carries `HKMetadataKeySyncIdentifier = gh:<type>:<google point id>` and `HKMetadataKeySyncVersion` (epoch ms). Saving the same id again **replaces** the old object. This alone guarantees no duplicates, even after a reinstall. |
| Ledger (SwiftData) | Remembers a SHA-256 of each record written; unchanged records are skipped, so repeat syncs write nothing. |
| One `SyncEngine` actor | Syncing is manual only (the Sync button; no launch or background syncs). A second tap while a sync runs joins it instead of starting another. |
| Orphan cleanup | After a fully successful fetch, FitSync deletes its own samples in the window whose id Google no longer returns (deleted or replaced in Google Health). Never touches other apps' data. |
| Calories counted once | A workout's summary calories (`caloriesKcal`) are written over its time span and the per-minute active-energy samples inside it are skipped. Only when a workout has no summary calories are those samples kept instead. |
| No double workouts | FitSync writes no workouts or heart rate (Google Health shares them). A one-time cleanup deletes those (and resting energy) written by older FitSync versions, only from FitSync itself. |
| Apple Health data skipped | Points that Google Health imported from Apple Health (`dataSource.platform = HEALTH_KIT`) are ignored, so iPhone data and the workouts Google Health shared are never copied back. |

The planning and dedup logic is pure Swift and covered by `FitSyncTests/DedupTests.swift`.

## Project layout

```
FitSync/
  App/        FitSyncApp, AppModel (UI state, Sync button)
  Auth/       GoogleAuth (OAuth + PKCE, token refresh), Keychain
  API/        GoogleHealthClient (paging, retries), Models
  Sync/       Planner (Google → records), ChangeDetector, Ledger, SyncEngine
  HealthKit/  HealthKitWriter (workouts, samples, orphan deletion)
  UI/         ContentView
```

## Roadmap

- v1.1: resting heart rate, weight, all-day distance (attach in-workout distance the same way as energy).
- v2: Cloud Run webhook receiver (Google Health `projects.subscribers`) → APNs silent push → app syncs within minutes. Needs a paid Apple developer account.
