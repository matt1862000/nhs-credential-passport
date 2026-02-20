# Route result telemetry (ROUTE_RESULT, ROUTE_START, ROUTE_FIRST_DISPLAYED)

The app prints **grep-friendly lines** for route quality and **when the first route appears in the preview**.

## Time to first route on screen

- **`ROUTE_START`** – When you tap to generate routes (start of the flow). Includes `duration=X`.
- **`ROUTE_FIRST_DISPLAYED`** – When the **first route is shown in the preview** (cache or live). Includes:
  - **`time_to_first_route_sec`** – Seconds from tap to first route on screen.
  - **`duration`** – Requested duration (min).
  - **`source`** – `cache` or `live`.

Search for **`ROUTE_FIRST_DISPLAYED`** to see only time-to-preview. Example:

```
ROUTE_START duration=15 (grep this + first ROUTE_FIRST_DISPLAYED for time-to-preview)
…
ROUTE_FIRST_DISPLAYED time_to_first_route_sec=0.42 duration=15 source=cache
```

or for live: `ROUTE_FIRST_DISPLAYED time_to_first_route_sec=5.23 duration=20 source=live`

## In Xcode console

1. Run the app and generate or load routes (change duration, location, etc.) as usual.
2. In the console, use **Find** (Cmd+F) and search for: **`ROUTE_RESULT`**
3. You’ll see only those lines, e.g.:

```
ROUTE_RESULT target=15 actual=14 ratio_pct=93 in_80_120=Y waypoints=2 elapsed_sec=4.2 mode=quick
ROUTE_RESULT target=20 actual=19 ratio_pct=95 in_80_120=Y waypoints=3 elapsed_sec=— mode=prepop_database
```

## Saving logs to a file, then grepping

1. In Xcode: **Product → Scheme → Edit Scheme → Run → Options**, set "Console" or run from Terminal so stdout goes to a file, e.g.:
   ```bash
   # Run from Terminal (replace with your app path if needed)
   /path/to/WalkingWR.app 2>&1 | tee ~/Desktop/walkingwr_log.txt
   ```
2. Then:
   ```bash
   grep ROUTE_RESULT ~/Desktop/walkingwr_log.txt
   grep ROUTE_FIRST_DISPLAYED ~/Desktop/walkingwr_log.txt   # time to first route on screen
   grep ROUTE_START ~/Desktop/walkingwr_log.txt
   ```

## What each field means

### ROUTE_FIRST_DISPLAYED

| Field                    | Meaning |
|--------------------------|--------|
| `time_to_first_route_sec` | Seconds from tap (ROUTE_START) to first route visible in preview. |
| `duration`               | Requested duration (minutes). |
| `source`                 | **cache** = from cache/prepop; **live** = just generated. |

### ROUTE_RESULT

| Field                    | Meaning |
|--------------------------|--------|
| `target`                 | Requested duration (minutes). |
| `actual`                 | Route duration actually used (minutes). |
| `ratio_pct`              | actual/target × 100. **90–110** = very close to request; **80–120** = in band. |
| `in_80_120`              | **Y** = route is within 80–120% of target (good); **n** = outside that band. |
| `waypoints`              | Number of POIs/waypoints on the route. |
| `elapsed_sec`            | Time to generate the route (seconds). **—** when from cache/prepop. |
| `mode`                   | **quick** = first try; **endpoint** / **loop** = on-device generation; **fallback** = guaranteed fallback; **prepop_database** / **memory_cache** = from cache. |
| `time_to_first_route_sec`| (Cache path only.) Same as ROUTE_FIRST_DISPLAYED – seconds to first route on screen. |

## What “positive” looks like

- **More `in_80_120=Y`** (and ideally more `ratio_pct` in 90–110).
- **Lower `elapsed_sec`** for generated routes (quick mode finishing faster).
- **`mode=quick`** more often (success on first try instead of systematic/fallback).
- Cache/prepop lines with **`ratio_pct`** in 90–110 when you’re in a prepop area.

You can paste only the `grep ROUTE_RESULT` output (or a few dozen lines) to review whether the changes are effective, instead of the full console log.
