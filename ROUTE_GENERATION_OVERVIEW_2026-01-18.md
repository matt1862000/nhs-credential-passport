# Route Generation System Overview & Today's Issues (Jan 18, 2026)

## Route Generation Architecture

### High-Level Flow

```
User selects duration (10-30 min)
    ↓
1. POI Fetch (Finding places nearby)
   - Google Places API (New) - Primary source
   - Apple Maps (MKLocalSearch) - Secondary source  
   - OpenStreetMap (OSM) - Tertiary source
   - Filters: Restricted areas, walkability, distance
    ↓
2. Route Calculation (Calculating routes)
   - MapKit (Apple) - FREE, rate-limited (50/min)
   - Tries different waypoint combinations
   - Validates duration (70-130% of target)
    ↓
3. Directions Extraction (Getting directions)
   - Extracts turn-by-turn from MapKit/OSRM
   - Falls back to Google Directions if needed
    ↓
4. Route Naming (Naming your route)
   - Gemini API - AI-generated names
   - Template fallback if Gemini fails/timeouts
    ↓
5. Complete - Route ready to display
```

### POI Fetching Strategy

**Current Implementation (v1.9.44 - after rollback):**
- **Parallel fetch**: All three sources (Google, Apple, OSM) fetch simultaneously
- **Google Places API (New)**: 
  - Uses `places.displayName` (Pro SKU - $32/1000 requests)
  - Single request with 43 categories batched
  - Field mask: `places.id,places.displayName,places.location`
- **Apple Maps**: 
  - FREE, rate-limited to 50 requests/60 seconds
  - 40 priority categories in "Fast Mode"
- **OpenStreetMap**: 
  - FREE, no rate limits
  - Uses Overpass API mirrors (6 fallback servers)
  - Can be slow (15-50+ seconds)

**Deduplication**: POIs merged by proximity (50m threshold) and name matching

---

## Issues Faced Today

### Issue #1: Places API Cost Optimization Attempt (v1.9.45)

**Problem**: 
- Google Places API `displayName` field moved to Pro SKU tier ($32/1000 vs $5/1000)
- Attempted to downgrade to Essentials SKU by using `places.name` instead

**Changes Made**:
- Changed field mask from `places.displayName` to `places.name`
- Updated `NewPlace` struct to use `name: String?` instead of `displayName`
- Removed `DisplayName` struct

**Result**: 
- ❌ **Place names showed as Place IDs** (e.g., "places/ChIJ3Wetb8lgeUgRbEZs6y0BqU8")
- `places.name` field doesn't return display names - it returns internal identifiers
- User experience degraded significantly

**Resolution**: Rolled back to v1.9.44 (restored `displayName`)

---

### Issue #2: POI Fetch Optimization Attempt (v1.9.46)

**Problem**: 
- Route generation was slow (50+ seconds) waiting for slow OSM responses
- Google Places API was fast (~0.6s) but we waited for all sources

**Changes Made**:
- Prioritized Google POIs - route generation starts immediately with Google results
- Added 3-second timeout for OSM/Apple - proceed with Google-only if slow
- Route generation now starts in ~0.6-3s instead of ~50s

**Result**: 
- ✅ Faster route generation start
- ⚠️ But exposed underlying API quota/rate limit issues

---

### Issue #3: "Stuck on Finding Places Nearby" (Today's Critical Issue)

**Root Cause**: All three POI sources failed simultaneously

**Google Places API**:
- ❌ **HTTP 429 - Quota Exceeded**
- Error: `Quota exceeded for quota metric 'SearchNearbyRequest' and limit 'SearchNearbyRequest per day'`
- Daily quota limit reached
- Result: 0 POIs from Google

**Apple Maps**:
- ❌ **Rate Limited**
- Error: `Tried to make more than 50 requests in 60 seconds`
- Rate limit: 50 requests per 60 seconds
- Result: 0 POIs from Apple (after initial 23 POIs)

**OpenStreetMap**:
- ❌ **Network/SSL Errors**
- Multiple mirrors failed with SSL errors
- Timeouts on other mirrors
- Result: 0 POIs from OSM (after some succeeded but too late)

**Combined Result**:
- 0 total POIs found
- Route generation couldn't proceed (needs at least 2-5 POIs)
- Loading screen stuck on "Finding places nearby" stage
- No error message shown to user

**Why It Happened**:
1. Multiple route generation attempts in quick succession
2. Google daily quota exhausted (likely from testing)
3. Apple rate limit hit (50 requests/60s exceeded)
4. OSM network issues (SSL errors, timeouts)
5. No graceful fallback when all sources fail

---

### Issue #4: Place Name Display (Attempted Fix)

**Problem**: After v1.9.45, place names showed as Place IDs

**Attempted Fix**:
- Added local name fetching using `MKLocalSearch` and `CLGeocoder`
- Tried to detect Place IDs and fetch actual names locally
- Multiple strategies: MapKit POI search, reverse geocoding, query-based search

**Result**: 
- ❌ Build errors (scope issues with @State properties)
- ❌ Never fully tested due to rollback
- Would have added latency (multiple API calls per POI)

**Better Solution**: Keep using `places.displayName` (Pro SKU) - the cost is worth the UX

---

## Current State (After Rollback to v1.9.44)

### What's Working:
- ✅ Place names display correctly (using `displayName`)
- ✅ Route generation works when POI sources are available
- ✅ Multi-source POI fetching (Google + Apple + OSM)
- ✅ MapKit route calculation (FREE)
- ✅ Google Directions refresh (when quota available)

### What's Broken:
- ⚠️ **No error handling** when all POI sources fail
- ⚠️ **No timeout** for overall route generation (can hang forever)
- ⚠️ **No user feedback** when APIs are rate-limited/quota-exceeded
- ⚠️ **No graceful degradation** - app just hangs

---

## API Costs & Quotas

### Google Places API (New)
- **Current SKU**: Pro (using `displayName`)
- **Cost**: $32 per 1,000 requests
- **Daily Quota**: Limited by billing account
- **Field Mask**: `places.id,places.displayName,places.location`
- **Optimization**: Single request with 43 categories batched (was 43 separate calls)

### Google Directions API (Legacy REST)
- **SKU**: Essentials
- **Cost**: $0.20 per 1,000 requests
- **Daily Limit**: 100 calls (configurable)
- **Usage**: Route refresh when user taps "Let's Go"
- **Optimization**: Local waypoint optimization (saves $39.80/month vs Premium SKU)

### Apple Maps (MKLocalSearch)
- **Cost**: FREE
- **Rate Limit**: 50 requests per 60 seconds
- **Usage**: POI fetching (40 priority categories)
- **Issue**: Easy to hit rate limit during testing

### OpenStreetMap (Overpass API)
- **Cost**: FREE
- **Rate Limits**: None (public mirrors)
- **Reliability**: Variable (SSL errors, timeouts common)
- **Speed**: Slow (15-50+ seconds typical)

---

## Recommendations

### Immediate Fixes Needed:

1. **Add Error Handling for POI Fetch Failures**
   - Show user-friendly error when all sources fail
   - Suggest retry or different location
   - Don't hang indefinitely

2. **Add Overall Timeout**
   - 60-second timeout for entire route generation
   - Dismiss loading screen and show error
   - Prevent infinite hanging

3. **Better Rate Limit Handling**
   - Track Apple Maps rate limit status
   - Show "Please wait X seconds" message
   - Queue requests instead of failing

4. **Quota Monitoring**
   - Track Google API quota usage
   - Warn when approaching limits
   - Graceful fallback to free sources only

### Cost Optimization (Future):

1. **Places API Strategy**
   - Option A: Keep Pro SKU ($32/1k) for good UX
   - Option B: Use Essentials SKU + local name fetching (complex, adds latency)
   - Option C: Cache place names aggressively (reduce API calls)

2. **POI Fetching Strategy**
   - Keep parallel fetch but add better timeout handling
   - Don't wait for slow OSM if Google/Apple succeed
   - Cache POIs more aggressively (reduce redundant fetches)

3. **Route Generation**
   - Pre-generate routes in background when possible
   - Cache routes by location + duration
   - Reduce redundant route calculations

---

## Key Metrics

### Route Generation Times (Typical):
- **POI Fetch**: 0.6s (Google) to 50s (waiting for OSM)
- **Route Calculation**: 2-10s (MapKit)
- **Directions**: 1-3s (MapKit/OSRM)
- **Naming**: 0s (template) to 3s (Gemini)
- **Total**: 3-66s (varies widely based on POI source speed)

### API Usage (Per Route Generation):
- **Google Places**: 1 request (batched, 43 categories)
- **Apple Maps**: 0-40 requests (depending on rate limit)
- **OSM**: 1-6 requests (trying different mirrors)
- **Google Directions**: 0-1 requests (refresh only, if quota available)
- **Gemini**: 0-1 requests (AI naming, optional)

---

## Summary

**Today's Journey**:
1. ✅ Started with working system (v1.9.44)
2. ❌ Tried to optimize costs (v1.9.45) - broke place names
3. ❌ Tried to optimize speed (v1.9.46) - exposed API issues
4. ❌ Attempted fixes - build errors, stuck on loading
5. ✅ Rolled back to v1.9.44 - stable again

**Key Learnings**:
- Cost optimization can break UX (displayName → name)
- Speed optimization exposes underlying reliability issues
- Need better error handling and timeouts
- All POI sources can fail simultaneously
- User experience > cost savings (for now)

**Current Status**: v1.9.44 (Build 227) - Stable, working, ready for TestFlight
