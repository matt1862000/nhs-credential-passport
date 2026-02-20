# default.csv in WalkingWR

## What it is

`WalkingWR/default.csv` is a small placeholder file in the app bundle (content: the single line `default`). It was added in case some code looked for a resource named `default.csv`.

## Why you might see "Failed to locate resource named default.csv"

That log message **does not come from our app**. It comes from **Apple’s MapKit** (internal framework behaviour when the app uses maps). MapKit looks for internal resources (including `default.csv` and e.g. `satellite.styl`) inside **its own** framework bundle, not the app bundle.

- **Source:** [Apple Developer Forums – “Failed to locate resource”](https://developer.apple.com/forums/thread/771614) (MapKit; Apple staff confirm these are internal framework messages).
- **Impact:** None. The message can be **safely ignored**; it does not indicate a bug in our app and does not affect behaviour.

## Do we need the file?

Our `default.csv` does **not** fix the MapKit warning (MapKit doesn’t load from the app bundle). We keep the file in the project so that:

- If any other code path (e.g. a dependency) ever looks for `default.csv` in the app bundle, the resource exists.
- Future readers don’t wonder whether something is “missing” when they see the log line.

**Summary:** The log line is from MapKit and is safe to ignore. The in-repo `default.csv` is a harmless placeholder we leave in place for the reasons above.
