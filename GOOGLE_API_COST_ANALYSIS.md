# Google API Cost Analysis - Complete Reference

## Overview
This document provides a complete breakdown of all Google API usage in WalkingWR, including endpoints, call frequency, costs, and optimizations.

---

## 1. Google Places API (New) - SearchNearby

### Endpoint
```
https://places.googleapis.com/v1/places:searchNearby
```

### When Called
- **Trigger**: `findNearbyPlaces()` is called when user generates a route at a **new location**
- **Frequency**: Once per new location (cached indefinitely within 1km radius)
- **Function**: `fetchGooglePOIs()` → `searchMultipleTypes()`

### API Call Details
- **Optimization**: Uses **1 API call** with all 43 place types (was 43 separate calls)
- **Place types searched** (43 total):
  - Stores: store, convenience_store, supermarket, shopping_mall, hardware_store, florist, pet_store, liquor_store
  - Food & Drink: restaurant, cafe, bar, bakery, meal_takeaway
  - Health & Wellness: pharmacy, doctor, dentist, veterinary_care, spa
  - Services: bank, post_office, hair_care, laundry, car_wash, gas_station
  - Culture & Leisure: park, museum, library, art_gallery, book_store, gym, church, movie_theater, bowling_alley
  - Education & Community: school, community_center
  - Outdoors & Nature: cemetery, campground
  - Transport: bus_station, train_station
  - Lodging: lodging
  - Government & Landmarks: local_government_office, fire_station, police

### Field Mask (Essentials SKU)
- `places.id`
- `places.displayName`
- `places.location`
- **Removed** (to avoid Pro SKU): `places.formattedAddress`, `places.types`

### Cost Structure
- **SKU**: Essentials (Basic Data)
- **Pricing**:
  - **FREE**: First $200 monthly credit (covers ~40,000 requests)
  - **After credit**: ~$5.00 per 1,000 requests
  - **Per request**: ~$0.005 (0.5 cents)
- **Per new location**: **1 request** × $0.005 = **$0.005 per new location** (was $0.215 before optimization)

### Caching
- POIs cached by location (1km radius match)
- Cache never expires
- Once cached, no API calls for that area

### Code Location
- **File**: `WalkingWR/Services/GoogleMapsService.swift`
- **Function**: `fetchGooglePOIs()` (line ~1410)
- **Function**: `searchMultipleTypes()` (line ~1525)
- **Called from**: `findNearbyPlaces()` (line ~1106)

---

## 2. Google Directions API (Legacy REST)

### Endpoint
```
https://maps.googleapis.com/maps/api/directions/json
```

### When Called
- **Trigger 1**: `refreshRouteWithGoogleDirections()` - When user presses "Let's Go" to start a walk
- **Trigger 2**: `getGoogleDirectionsRoute()` - During route generation as fallback/quality check
- **Frequency**: 
  - Limited to **100 calls per day** (via `googleDirectionsDailyCap`)
  - Once per route when user confirms route
  - Falls back to MapKit if quota exceeded

### API Call Details
- **Request includes**:
  - Origin: User's current location
  - Destination: User's current location (loop route)
  - Waypoints: All POI waypoints in the route
  - Mode: `walking`
  - **Note**: `optimize:true` removed to stay in free Essentials tier
- **Response**: Detailed turn-by-turn directions, encoded polyline, distance, duration

### Daily Quota Management
- **Daily cap**: 100 calls/day (conservative limit)
- **Tracking**: `googleDirectionsCallsToday` stored in UserDefaults
- **Reset**: Automatically resets at midnight
- **Code**: Lines 249-279 in `GoogleMapsService.swift`

### Cost Structure
- **Pricing**:
  - **FREE**: First 2,500 requests per month
  - **After free tier**: $5.00 per 1,000 requests
  - **Per request**: $0.005 (after free tier)
- **Daily limit**: 100 calls = **$0.50/day max** (if over free tier)
- **Monthly**: 3,000 calls = **$2.50/month** (if over free tier)

### Code Location
- **File**: `WalkingWR/Services/GoogleMapsService.swift`
- **Function**: `refreshRouteWithGoogleDirections()` (line ~3473)
- **Function**: `getGoogleDirectionsRoute()` (line ~6843)
- **Quota check**: `canUseGoogleDirectionsRefresh` (line ~257)

---

## 3. Google Generative Language API (Gemini)

### Endpoint
```
https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent
```

### When Called
- **Trigger**: When generating route names and descriptions
- **Frequency**: Once per route generation
- **Timeout**: 1 second (falls back to template if slow)

### API Call Details
- **Model**: `gemini-2.0-flash` (fast, cost-effective)
- **Purpose**: Generate creative route names (e.g., "Taste & Faith Trek") and descriptions
- **Fallback**: If API fails, times out, or quota exceeded → uses privacy-safe templates (FREE)

### Cost Structure
- **Pricing**: 
  - **FREE tier**: Generous free tier available
  - **After free tier**: Pay-as-you-go (varies by model and tokens)
  - **Gemini 2.0 Flash**: Very cost-effective (typically <$0.001 per request)

### Code Location
- **File**: `WalkingWR/Services/GeminiService.swift`
- **Function**: `tryGeminiGeneration()` (line ~351)
- **Function**: `callGemini()` (line ~538)
- **Called from**: Route name generation in `RouteSelectionView.swift`

---

## Cost Summary by Usage Scenario

### Scenario 1: Light User (1 new location, 10 routes/month)
- **Places API**: 1 request = **FREE** (within $200 credit)
- **Directions API**: 10 requests = **FREE** (within 2,500 free tier)
- **Gemini API**: 10 requests = **FREE** (within free tier)
- **Total**: **$0.00/month**

### Scenario 2: Moderate User (5 new locations, 50 routes/month)
- **Places API**: 5 requests = **FREE** (within $200 credit)
- **Directions API**: 50 requests = **FREE** (within 2,500 free tier)
- **Gemini API**: 50 requests = **FREE** (within free tier)
- **Total**: **$0.00/month**

### Scenario 3: Heavy User (20 new locations, 200 routes/month)
- **Places API**: 20 requests = **FREE** (within $200 credit)
- **Directions API**: 200 requests = **FREE** (within 2,500 free tier)
- **Gemini API**: 200 requests = **FREE** (within free tier)
- **Total**: **$0.00/month**

### Scenario 4: Very Heavy User (100 new locations, 1,000 routes/month)
- **Places API**: 100 requests = **FREE** (within $200 credit)
- **Directions API**: 1,000 requests = **FREE** (within 2,500 free tier)
- **Gemini API**: 1,000 requests = ~$1.00
- **Total**: **~$1.00/month**

### Scenario 5: Extreme Usage (500 new locations, 3,000 routes/month)
- **Places API**: 500 requests = **FREE** (within $200 credit)
- **Directions API**: 3,000 requests = 500 over free tier = **$2.50**
- **Gemini API**: 3,000 requests = ~$3.00
- **Total**: **~$5.50/month**

---

## Cost Optimizations Implemented

### 1. Places API Optimization (v1.9.16)
- **Before**: 43 separate API calls per location = $0.215 per location
- **After**: 1 API call with all types = $0.005 per location
- **Savings**: **97.7% cost reduction**
- **Impact**: Reduced from ~25,800 requests/month to ~600 requests/month

### 2. Essentials SKU Only
- **Impact**: Reduced from Pro SKU ($32/1000) to Essentials SKU ($5/1000)
- **Savings**: **84% cost reduction**
- **Trade-off**: No `formattedAddress` or `types` fields (app still works perfectly)

### 3. POI Caching
- **Impact**: Reduces Places API calls by ~90-95% for repeat locations
- **How it works**: POIs cached by location (1km radius), no expiry
- **Benefit**: Most users only generate routes at 1-2 locations (home/work)

### 4. Daily Quota Limits
- **Directions API**: Limited to 100 calls/day (prevents runaway costs)
- **Tracking**: Automatic daily reset
- **Fallback**: Gracefully falls back to MapKit if quota exceeded

### 5. Graceful Fallbacks
- **Places API fails**: Falls back to Apple Maps + OpenStreetMap (FREE)
- **Directions API fails**: Falls back to MapKit (FREE)
- **Gemini API fails**: Falls back to templates (FREE)
- **Result**: App always works, even if all Google APIs fail

### 6. Timeout Protection
- **Gemini**: 1-second timeout prevents slow/expensive calls
- **Places API**: 30-second timeout prevents hanging requests

---

## API Key Configuration

### Location
- **File**: `WalkingWR/Info.plist`
- **Key**: `GOOGLE_MAPS_API_KEY`
- **Used by**: 
  - `GoogleMapsService.swift` (Places API, Directions API)
  - `GeminiService.swift` (Generative Language API)

### Security
- API key is bundled with app
- **Recommendation**: Consider using a backend proxy in production to hide the key
- Bundle ID restrictions can be set in Google Cloud Console

---

## Monitoring & Tracking

### API Call Tracking
- **Places API**: Tracked in `GoogleMapsService.apiCallRecords`
- **Directions API**: Tracked via `googleDirectionsCallsToday` counter
- **Gemini API**: Tracked in `GeminiService.apiCallRecords`

### Summary Functions
- `GoogleMapsService.printAPICallSummary()` - Prints Places & Directions API usage
- `GeminiService.printAPICallSummary()` - Prints Gemini API usage

### Logging
- All API calls are logged with:
  - Success/failure status
  - HTTP status codes
  - Response times
  - Bundle ID sent status
  - Timestamps

---

## Quota Management Recommendations

### 1. Set Daily Quotas in Google Cloud Console
- **Places API**: 20-50 per day (for testing)
- **Directions API**: 100 per day (already implemented in code)
- **Gemini API**: 50-100 per day

### 2. Set Budget Alerts
- **Alert at $1.00**: Get notified immediately if spending starts
- **Alert at $5.00**: Warning before significant charges
- **Alert at $10.00**: Critical threshold

### 3. Monitor Usage
- Check Google Cloud Console regularly
- Review API call summaries in app logs
- Watch for unexpected spikes
- Review `GOOGLE_API_USAGE_BREAKDOWN.md` for detailed tracking

---

## Summary

**Most users will pay $0/month** due to:
1. Generous free tiers ($200 Places API credit, 2,500 Directions API free requests)
2. Effective caching (most users only use 1-2 locations)
3. Graceful fallbacks (app works even if APIs fail)
4. Cost optimizations (97.7% reduction in Places API costs)

**Heavy users** (100+ new locations/month, 1,000+ routes/month) might see:
- **$1-5/month** in costs
- Still very affordable compared to Pro SKU pricing

**The app is designed to be cost-effective** while maintaining excellent functionality through intelligent caching and fallback mechanisms.
