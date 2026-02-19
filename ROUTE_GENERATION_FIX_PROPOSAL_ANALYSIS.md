# Route Generation Fix Proposal Analysis

## Executive Summary

**Overall Assessment**: ✅ **Strong proposal with well-targeted fixes**

The diagnosis is accurate, and the proposed fixes address root causes. However, there are some considerations and refinements needed before implementation.

---

## 1. Improve "Within Tolerance" Rate (51/83 → Target: ≥75%)

### ✅ **Pre-Filter Relaxation: APPROVED with Modifications**

**Current State**:
- Curated DB (≤20min): 35-130% (with 15% leniency capped at 130%)
- Live POIs: 40-95% to 60-100% (duration-dependent)
- Density tightening: Disabled for curated, aggressive for live

**Proposed Change**: 60-135% for urban cores, 55-135% for long routes

**Analysis**:
- ✅ **Good**: Relaxing pre-filter will help, especially for curated POIs
- ⚠️ **Concern**: Your proposal is actually MORE restrictive than current for curated DB (currently 35-130%, you propose 60-135%)
- 💡 **Recommendation**: 
  - For curated DB: Keep current 35-130% (already lenient)
  - For live POIs: Apply your 60-135% proposal
  - For long routes (≥35min): Apply 55-135% as proposed

**Revised Proposal**:
```swift
// Curated DB (already lenient, keep as-is)
if isUsingCuratedDB && targetDurationMinutes <= 20 {
    // Keep current: 35-130%
}

// Live POIs - apply your relaxation
else if targetDurationMinutes >= 35 {
    minPercent = 55; baseMaxPercent = 135  // Long routes
} else {
    minPercent = 60; baseMaxPercent = 135  // Urban cores
}
```

---

### ✅ **Validation Multiplier Tuning: APPROVED**

**Current State**: 0.85-0.92 (fixed by duration)

**Proposed Change**: 0.86-0.94 with ADS-based context

**Analysis**:
- ✅ **Excellent**: Context-aware multipliers address the core issue
- ✅ **ADS-based logic**: Makes sense - dense areas need different handling
- ⚠️ **Risk**: Need to ensure ADS calculation is reliable (currently calculated, but verify it's accurate)

**Recommendation**: 
- Implement as proposed
- Add logging to track: `(actualDuration / estimatedDuration)` per route
- Use this data to refine multipliers over time

**Implementation Note**:
```swift
let validationMultiplier: Double
if angularDiversityScore < 3 {
    // Dense urban (clustered POIs)
    validationMultiplier = 0.88 + (0.02 * Double(targetDurationMinutes) / 60.0)  // 0.88-0.90
} else {
    // Suburban/rural (spread out)
    validationMultiplier = 0.90 + (0.04 * Double(targetDurationMinutes) / 60.0)  // 0.90-0.94
}
```

---

### ✅ **Extension Trigger Broadening: APPROVED**

**Current State**: 70-95% with ≥1min headroom

**Proposed Change**: 65-98% with ≥45s headroom, two-pass extension

**Analysis**:
- ✅ **Excellent**: This will catch many undershooting routes
- ✅ **Two-pass extension**: Smart - on-route first, then perpendicular detour
- ⚠️ **Risk**: Perpendicular detour might create awkward routes

**Recommendation**:
- Implement 65-98% trigger as proposed
- For two-pass: 
  - Pass 1: On-route POI (≤200m) - **Keep this**
  - Pass 2: Perpendicular detour - **Be cautious**, test thoroughly
  - Consider: Only do Pass 2 if Pass 1 didn't help AND route is still <85% of target

**Implementation Priority**:
1. ✅ Broaden trigger to 65-98% (low risk, high reward)
2. ✅ Add Pass 1 (on-route POI) - proven pattern
3. ⚠️ Pass 2 (perpendicular) - test in A/B first

---

## 2. Increase Waypoint Density (1.5 → 2.5-3.0)

### ✅ **Lower ADS Gate: APPROVED**

**Current State**: ADS ≥ 3 required for multi-waypoint

**Proposed Change**: ADS ≥ 2

**Analysis**:
- ✅ **Good**: Current gate is too restrictive (your test shows avg 1.5 waypoints)
- ⚠️ **Risk**: ADS = 2 might still create poor loops in very clustered areas
- 💡 **Recommendation**: 
  - Lower to 2 as proposed
  - BUT: If ADS = 2, enforce minimum angular spacing (not just sector count)
  - Add fallback: If loop fails with ADS = 2, fall back to endpoint-first

**Implementation**:
```swift
let effectivePreferMultiWaypoint = preferMultiWaypoint && angularDiversityScore >= 2
if angularDiversityScore == 2 {
    // Enforce minimum angular spacing between waypoints
    // Require at least 60° separation between consecutive waypoints
}
```

---

### ✅ **Raise Min Waypoint Targets: APPROVED**

**Current State**:
- 11-20min: 1-3 waypoints
- 21-30min: 2-4 waypoints
- 31-45min: 2-6 waypoints
- 46-60min: 3-8 waypoints

**Proposed Change**:
- 11-20min: 2-3 waypoints
- 21-30min: 3-4 waypoints
- 31-45min: 4-6 waypoints
- 46-60min: 5-7 waypoints

**Analysis**:
- ✅ **Good**: Higher minimums will force more multi-waypoint routes
- ⚠️ **Risk**: Might reduce success rate if POIs are sparse
- 💡 **Recommendation**: 
  - Implement as proposed
  - Add fallback: If no valid routes with min waypoints after N attempts, relax to min-1

**Implementation with Fallback**:
```swift
var minWaypointsForTier: Int
switch targetDurationMinutes {
case 11...20:
    minWaypointsForTier = 2  // Proposed
case 21...30:
    minWaypointsForTier = 3  // Proposed
// ... etc
}

// After 10 failed attempts, relax minimum
if attemptsWithoutValidRoute >= 10 {
    minWaypointsForTier = max(1, minWaypointsForTier - 1)
    print("⚠️ Relaxing min waypoints to \(minWaypointsForTier) after \(attemptsWithoutValidRoute) failures")
}
```

---

### ⚠️ **Loop Incentive Scoring: NEEDS REFINEMENT**

**Proposed**: Add `loopPotentialScore` to POI scoring

**Analysis**:
- ✅ **Concept**: Good idea to encourage diverse routes
- ⚠️ **Risk**: Might over-complicate scoring function
- 💡 **Recommendation**: 
  - Start simpler: Just add small bonus (+0.02-0.05) for underrepresented sectors
  - Don't add complex "projected route" calculations (too expensive)
  - Test if simple bonus is enough before adding complexity

**Simplified Implementation**:
```swift
// In calculatePOIScore, add:
let sector = sectorIndex(from: bearingBetween(origin, poi.coordinate))
let sectorCount = currentSelectedWaypoints.filter { 
    sectorIndex(from: bearingBetween(origin, $0.coordinate)) == sector 
}.count
let diversityBonus = sectorCount == 0 ? 0.03 : 0.0  // +3% if sector is empty
```

---

## 3. Reduce Tail Latency (33s → ≤15s)

### ✅ **Time Budgets: APPROVED with Modifications**

**Proposed**:
- Stage 1 (Quick): 3s budget
- Stage 2 (Systematic): 8s total (cumulative 11s)
- Topology-safe: Activate at 9s

**Analysis**:
- ✅ **Good**: Time budgets prevent runaway searches
- ⚠️ **Risk**: Too aggressive might reduce success rate
- 💡 **Recommendation**:
  - Stage 1: 5s (not 3s) - gives more time for database routes
  - Stage 2: 10s cumulative (not 8s)
  - Topology-safe: Activate at 12s (not 9s) - let POI-first have fair chance

**Revised Budgets**:
```swift
let stage1Budget: TimeInterval = 5.0
let stage2Budget: TimeInterval = 10.0  // Cumulative
let topologySafeActivation: TimeInterval = 12.0
```

---

### ⚠️ **Parallel Evaluation: NEEDS CAREFUL IMPLEMENTATION**

**Proposed**: Evaluate endpoint-first and loop strategies in parallel

**Analysis**:
- ✅ **Concept**: Good for performance
- ⚠️ **Risk**: 
  - Parallel API calls might hit rate limits
  - MapKit rate limiter might not handle parallel well
  - Could increase API costs
- 💡 **Recommendation**:
  - **Don't do full parallel** (too risky)
  - **Do**: Early topology-safe activation (as proposed)
  - **Do**: Cache leg durations (as proposed)
  - **Do**: Combination pruning (as proposed)

---

### ✅ **Combination Pruning: APPROVED**

**Proposed**: Cap attempts by duration (30/40/50)

**Analysis**:
- ✅ **Excellent**: Prevents exhaustive searches
- ✅ **Duration-based caps**: Makes sense
- 💡 **Recommendation**: Implement exactly as proposed

---

### ✅ **Early Trim on Overshoot: APPROVED**

**Proposed**: If route >140%, trim immediately

**Analysis**:
- ✅ **Good**: Saves time on obviously bad routes
- 💡 **Recommendation**: 
  - Implement as proposed
  - Consider: Also trim if route >130% AND we already have a valid route

---

## 4. Algorithm Tweaks

### ✅ **Scoring Function Changes: APPROVED (Simplified)**

**Recommendation**: 
- Add diversity bonus (simple version)
- Don't add complex "projected route" calculations
- Keep it simple and test

### ✅ **Multi-Waypoint Selection: APPROVED**

**Proposed**: Diverse-first, capped at 24 combinations

**Analysis**:
- ✅ **Good**: Balances quality and performance
- 💡 **Recommendation**: Implement as proposed

### ⚠️ **Two-Pass Extension: PARTIAL APPROVAL**

**Recommendation**:
- ✅ Pass 1 (on-route POI): Implement
- ⚠️ Pass 2 (perpendicular detour): Test in A/B first, might create awkward routes

---

## 5. Area-Specific Guidance

### ✅ **S1 4JP (City Centre): APPROVED**

**Proposed**: Dense urban validation range, lower ADS gate, topology-safe earlier

**Analysis**:
- ✅ **Makes sense**: City centre has different characteristics
- 💡 **Recommendation**: Implement as proposed

### ✅ **S11 9BF (Edge + Parks): APPROVED**

**Proposed**: Allow validation up to 0.93-0.94

**Analysis**:
- ✅ **Makes sense**: Parks often have shorter paths
- 💡 **Recommendation**: Implement as proposed

---

## 6. Telemetry: CRITICAL

### ✅ **ALL PROPOSED TELEMETRY: APPROVED**

**Analysis**:
- ✅ **Essential**: Need data to refine parameters
- 💡 **Recommendation**: 
  - Implement ALL proposed telemetry
  - Add: Pre-filter pass rate (how many POIs filtered out)
  - Add: Extension success rate (how often extension helps)
  - Add: Trimming success rate

---

## Implementation Priority

### **Phase 1: Quick Wins** (Low Risk, High Reward)
1. ✅ Broaden extension trigger (65-98%)
2. ✅ Add Pass 1 extension (on-route POI)
3. ✅ Lower ADS gate (3 → 2)
4. ✅ Raise min waypoint targets
5. ✅ Add combination pruning caps
6. ✅ Early trim on >140% overshoot

### **Phase 2: Medium Risk** (Test in A/B)
1. ⚠️ Validation multiplier tuning (ADS-based)
2. ⚠️ Pre-filter relaxation (for live POIs)
3. ⚠️ Time budgets
4. ⚠️ Simple diversity bonus in scoring

### **Phase 3: Higher Risk** (Test Carefully)
1. ⚠️ Pass 2 extension (perpendicular detour)
2. ⚠️ Parallel evaluation (if at all)
3. ⚠️ Complex loop incentive scoring

---

## Expected Impact Assessment

### **Optimistic Scenario**
- Within tolerance: 51/83 (61.4%) → **75/83 (90%)**
- Avg waypoints: 1.5 → **2.5**
- p99 latency: 33s → **12s**
- Success rate: Maintain ≥94%

### **Realistic Scenario**
- Within tolerance: 51/83 (61.4%) → **65/83 (78%)**
- Avg waypoints: 1.5 → **2.2**
- p99 latency: 33s → **18s**
- Success rate: Maintain ≥92%

### **Conservative Scenario**
- Within tolerance: 51/83 (61.4%) → **60/83 (72%)**
- Avg waypoints: 1.5 → **2.0**
- p99 latency: 33s → **25s**
- Success rate: Maintain ≥90%

---

## Risks & Mitigations

### **Risk 1: Reduced Success Rate**
- **Mitigation**: Implement fallbacks (relax min waypoints after failures)
- **Monitoring**: Track success rate in A/B test

### **Risk 2: Awkward Routes from Perpendicular Detour**
- **Mitigation**: Test Pass 2 in A/B, only enable if metrics improve
- **Monitoring**: Track user feedback on route quality

### **Risk 3: Increased API Costs**
- **Mitigation**: Keep database-first approach, limit parallel calls
- **Monitoring**: Track API call counts

### **Risk 4: Over-Complexity**
- **Mitigation**: Start with simple changes, add complexity only if needed
- **Monitoring**: Code review, maintainability checks

---

## Final Recommendation

### **✅ PROCEED with Implementation**

**Recommended Approach**:
1. **Implement Phase 1** (Quick Wins) - Low risk, high reward
2. **A/B Test Phase 2** (Medium Risk) - Compare against current
3. **Evaluate Phase 3** (Higher Risk) - Only if Phase 2 shows promise

**Key Modifications to Proposal**:
1. Keep curated DB pre-filter as-is (already lenient)
2. Relax time budgets slightly (5s/10s/12s instead of 3s/8s/9s)
3. Simplify loop incentive (simple diversity bonus, not complex projection)
4. Test Pass 2 extension in A/B before full rollout

**Success Criteria**:
- Within tolerance: ≥75% (up from 61.4%)
- Avg waypoints: ≥2.2 (up from 1.5)
- p99 latency: ≤18s (down from 33s)
- Success rate: Maintain ≥92%

---

## Next Steps

1. **Create implementation plan** with phased rollout
2. **Set up A/B test framework** for safe testing
3. **Implement Phase 1** changes
4. **Run batch test** to validate improvements
5. **Analyze results** and decide on Phase 2/3

---

*Analysis Date: 2026-01-23*
*Proposal Version: v2.0.3*
*Status: ✅ Approved with Modifications*
