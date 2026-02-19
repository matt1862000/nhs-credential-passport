# Batch Telemetry Schema (v2.0.13)

## Per-Route Telemetry Fields

Each route generation emits the following telemetry fields (already implemented):

```swift
{
  "elapsed_ms": Int,                    // Total generation time in milliseconds
  "stop_reason": String,                 // "NORMAL" | "SOFT_STOP" | "HARD_STOP"
  "stage_exited": String,                // Which stage triggered hard-stop
  "engine_calls": {
    "mapkit": Int,
    "osrm": Int,
    "skipped": Int
  },
  "duration_bucket": String,            // "10" | "15" | ... | "60"
  "bias_applied": Double,               // Duration bias correction applied (e.g., 1.050)
  
  "early_band_hit": Bool,               // Did we hit target band early (≤7s)?
  "best_so_far_committed": Bool,        // Did we commit early (95-105% or 90-110%)?
  "commit_band": String,                // "95-105" | "90-110" | "none"
  "early_commit_opportunity": Bool,      // Did we have an early commit opportunity?
  
  "sector_quota_used": Bool,             // Were sector quotas applied?
  "ads": Int,                           // Angular Diversity Score (1-8)
  
  "kbest_candidates": Int,              // Number of k-best candidates
  "valid_candidates": Int,              // Number of valid candidates found
  
  "waypoints_required": Int,            // Minimum waypoints for this duration
  "wp_before_finalization": Int,        // Waypoint count before finalization
  "wp_after_finalization": Int,         // Waypoint count after finalization
  "repair_attempt": Bool,               // Did we attempt WP repair?
  "repair_success": Bool,               // Did repair meet minWP?
  
  "hinge_penalty_fired": Bool,          // Did hinged penalty (>120%) fire?
  "overshoot_selected": Bool,           // Was selected route >120%?
  
  "per_leg_cap_applied": Bool,          // Was per-leg cap applied?
  "cap_after_good_candidate": Bool,     // Did per-leg cap run after good candidate?
  
  "fallback_fired": Bool,               // Did fallback trigger?
  "fallback_reason": String,            // "engine_cap" | "no_candidates" | "quality_floor" | "exceeds_130_percent"
  "fallback_accuracy": Double,          // Fallback route accuracy (if fallback fired)
  
  "expansions": Int,                    // Radius expansion count
  "repair_passes": Int,                 // Overshoot repair attempts
  "nudges": Int,                        // Waypoint nudge count
  "micro_spurs": Int,                   // Micro-spur insertion count
  "per_leg_over_cap": Bool             // Did any leg exceed 50% of target?
}
```

## Batch Roll-Up Schema

After every 264-generation batch (8 postcodes × 11 durations × 3 seeds), emit a one-line JSON roll-up:

```json
{
  "batch_total": 264,
  "tight_90_110": 0,                    // Count of routes in 90-110% accuracy band
  "within_80_130": 0,                   // Count of routes in 80-130% accuracy band
  "avg_accuracy": 0.0,                  // Mean accuracy (actual/target ratio)
  "avg_elapsed_ms": 0,                  // Mean generation time in milliseconds
  "p50_ms": 0,                          // Median (p50) generation time
  "p95_ms": 0,                          // 95th percentile generation time
  "p99_ms": 0,                          // 99th percentile generation time
  "avg_waypoints": 0.0,                 // Mean waypoint count
  "routes_ge_2_wp": 0,                  // Count of routes with ≥2 waypoints
  "valid_routes_per_gen": 0.0,          // Mean valid routes per generation
  "early_commit_opportunities": 0,      // Total early commit opportunities detected
  "early_commits_taken": 0,             // Total early commits actually taken
  "per_leg_cap_applied": 0,             // Count of routes where per-leg cap was applied
  "cap_after_good_candidate": 0,         // Count of routes where cap ran after good candidate
  "fallback_fired": 0,                  // Count of routes that used fallback
  "fallback_over_130pct": 0,            // Count of fallbacks that exceeded 130%
  "overshoot_selected_gt_120pct": 0,    // Count of selected routes >120%
  "bias_table": {                       // Duration-bucket bias values
    "10": 1.05,
    "15": 1.08,
    "20": 1.10,
    "25": 1.12,
    "30": 1.14,
    "35": 1.16,
    "40": 1.17,
    "45": 1.18,
    "50": 1.18,
    "55": 1.17,
    "60": 1.16
  },
  "sector_quota_used_count": 0          // Count of routes where sector quotas were used
}
```

## Implementation Notes

1. **Early Commit Opportunity**: Set to `true` whenever a candidate met the commit band (95-105% for ≤30min, 90-110% for ≥35min) AND waypoints ≥ min OR min-1, whether or not we actually committed. This enables computing "opportunities vs commits taken" and tying missed commits to p95 outliers.

2. **Batch Roll-Up**: Should be computed after each 264-generation batch by:
   - Aggregating all per-route telemetry
   - Computing percentiles (p50, p95, p99) for latency
   - Counting boolean flags (early_commit_opportunities, fallback_fired, etc.)
   - Extracting bias_table from `RoutingToggles._durationBias` (or persisted bias values)

3. **Bias Table**: Should reflect the current state of duration-bucket biases after EMA smoothing from the batch.

## Usage

This schema enables:
- **Phase-1 validation**: Check if tight_90_110 ≥ 30%, p95_ms ≤ 12000, avg_waypoints ≥ 2.0
- **Diagnostics**: Compare early_commit_opportunities vs early_commits_taken to find missed commits
- **Quality tracking**: Monitor fallback_over_130pct (should be 0) and cap_after_good_candidate (should be 0)
- **Bias monitoring**: Track bias_table evolution across batches
