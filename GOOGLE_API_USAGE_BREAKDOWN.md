# Google API Usage Breakdown for WalkingWR

## Overview
This document details all Google API calls made by the app, their frequency, and associated costs.

---

## 1. Places API (New) - SearchNearby

### Endpoint
```
https://places.googleapis.com/v1/places:searchNearby
```

### When It's Called
- **Trigger**: User generates a route at a **new location** (not previously cached)
- **Frequency**: Once per new location (cached indefinitely within 1km radius)
- **Caching**: POIs are cached by location (1km radius match). Once cached, no API calls are made for that area.

### API Call Details
- **Number of calls per location**: **43 parallel API calls** (one per place category)
- **Categories searched**: 
  - Stores (store, convenience_store, supermarket, shopping_mall, hardware_store, florist, pet_store, liquor_store)
  - Food & Drink (restaurant, cafe, bar, bakery, meal_takeaway)
  - Health & Wellness (pharmacy, doctor, dentist, veterinary_care, spa)
  - Services (bank, post_office, hair_care, laundry, car_wash, gas_station)
  - Culture & Leisure (park, museum, library, art_gallery, book_store, gym, church, movie_theater, bowling_alley)
  - Education & Community (school, community_center)
  - Outdoors & Nature (cemetery, campground)
  - Transport (bus_station, train_station)
  - Lodging (lodging)
  - Government & Landmarks (local_government_office, fire_station, police)

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
- **Per new location**: 43 requests × $0.005 = **$0.215 per new location**

### Example Usage Scenarios
- **New user at hospital**: 43 API calls (one-time, then cached)
- **Same user, same location**: 0 API calls (uses cache)
- **User moves 2km away**: 43 API calls (new location)
- **10 new locations in a month**: 430 API calls = **$2.15** (within free credit)

### Quota Management
- **Daily quota**: Configurable in Google Cloud Console (default: 650 requests/day)
- **What happens if exceeded**: App gracefully falls back to Apple Maps + OpenStreetMap (FREE sources)
- **No user-facing error**: App continues working with fewer POIs

---

## 2. Directions API (Legacy REST)

### Endpoint
```
https://maps.googleapis.com/maps/api/directions/json
```

### When It's Called
- **Trigger**: User presses **"Let's Go"** button to start a walk
- **Frequency**: Once per route generation (when user confirms route)
- **Purpose**: Refreshes route with Google's high-quality walking directions and detailed polylines

### API Call Details
- **Request includes**:
  - Origin: User's current location
  - Destination: User's current location (loop route)
  - Waypoints: All POI waypoints in the route
  - Mode: `walking`
- **Response**: Detailed turn-by-turn directions, encoded polyline, distance, duration

### Cost Structure
- **Pricing**:
  - **FREE**: First 2,500 requests per month
  - **After free tier**: $5.00 per 1,000 requests
  - **Per request**: $0.005 (after free tier)

### Example Usage Scenarios
- **Light usage (10 routes/month)**: FREE (within 2,500 free tier)
- **Heavy usage (500 routes/month)**: 500 requests = **$2.50** (after free tier)
- **Very heavy (1,000 routes/month)**: 1,000 requests = **$5.00** (after free tier)

### Notes
- This is a **quality assurance** call - the route is already generated using MapKit (FREE)
- Google Directions provides more accurate polylines and better turn-by-turn instructions
- Falls back to MapKit if Google Directions fails
- **Waypoint Optimization**: Uses local Nearest Neighbor (Greedy) algorithm to optimize waypoint order (saves $5.00/1k calls)
- **SKU Enforcement**: `optimize:true` flag removed; max 10 waypoints per call
  - If route has >10 waypoints, only first 10 are sent to Google
  - Advanced SKU ($10+/1k) is triggered if >10 waypoints or if `optimize:true` parameter is used
  - Local optimization ensures requests stay in Essentials SKU ($5/1k) instead of Advanced SKU
- **Coordinate Format**: Waypoints formatted as `lat,lng|lat,lng|lat,lng` using 6 decimal places for precision
- **URL Structure**: Origin and destination are the same (loop route), waypoints parameter contains only intermediate POIs

---

## 3. Generative Language API (Gemini)

### Endpoint
```
https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent
```

### When It's Called
- **Trigger**: When generating route names and descriptions
- **Frequency**: Once per route generation
- **Timeout**: 1 second (falls back to template if slow)

### API Call Details
- **Model**: `gemini-1.5-flash-latest` (fast, cost-effective)
- **Purpose**: Generate creative route names (e.g., "Taste & Faith Trek") and descriptions
- **Fallback**: If API fails, times out, or quota exceeded → uses privacy-safe templates (FREE)

### Cost Structure
- **Pricing**: 
  - **FREE tier**: Generous free tier available
  - **After free tier**: Pay-as-you-go (varies by model and tokens)
  - **Gemini 1.5 Flash**: Very cost-effective (typically <$0.001 per request)

### Example Usage Scenarios
- **10 routes/month**: Likely FREE (within free tier)
- **100 routes/month**: Likely FREE or <$0.10
- **1,000 routes/month**: ~$1.00 (estimated)

### Notes
- Has 1-second timeout - if slow, automatically falls back to templates
- Templates are privacy-safe and always work (no API dependency)

---

## Monthly Cost Estimates

### Scenario 1: Light User (1 new location, 10 routes/month)
- **Places API**: 43 requests = FREE (within $200 credit)
- **Directions API**: 10 requests = FREE (within 2,500 free tier)
- **Gemini API**: 10 requests = FREE (within free tier)
- **Total**: **$0.00/month**

### Scenario 2: Moderate User (5 new locations, 50 routes/month)
- **Places API**: 215 requests = FREE (within $200 credit)
- **Directions API**: 50 requests = FREE (within 2,500 free tier)
- **Gemini API**: 50 requests = FREE (within free tier)
- **Total**: **$0.00/month**

### Scenario 3: Heavy User (20 new locations, 200 routes/month)
- **Places API**: 860 requests = FREE (within $200 credit)
- **Directions API**: 200 requests = FREE (within 2,500 free tier)
- **Gemini API**: 200 requests = FREE (within free tier)
- **Total**: **$0.00/month**

### Scenario 4: Very Heavy User (100 new locations, 1,000 routes/month)
- **Places API**: 4,300 requests = FREE (within $200 credit)
- **Directions API**: 1,000 requests = FREE (within 2,500 free tier)
- **Gemini API**: 1,000 requests = ~$1.00
- **Total**: **~$1.00/month**

### Scenario 5: Extreme Usage (500 new locations, 3,000 routes/month)
- **Places API**: 21,500 requests = FREE (within $200 credit)
- **Directions API**: 3,000 requests = 500 over free tier = **$2.50**
- **Gemini API**: 3,000 requests = ~$3.00
- **Total**: **~$5.50/month**

---

## Cost Optimization Features

### 1. POI Caching
- **Impact**: Reduces Places API calls by ~90-95% for repeat locations
- **How it works**: POIs cached by location (1km radius), no expiry
- **Benefit**: Most users only generate routes at 1-2 locations (home/work), so only pay for those

### 2. Essentials SKU Only
- **Impact**: Reduced from Pro SKU ($32/1000) to Essentials SKU ($5/1000)
- **Savings**: ~84% cost reduction
- **Trade-off**: No `formattedAddress` or `types` fields (app still works perfectly)

### 3. Graceful Fallbacks
- **Places API fails**: Falls back to Apple Maps + OpenStreetMap (FREE)
- **Directions API fails**: Falls back to MapKit (FREE)
- **Gemini API fails**: Falls back to templates (FREE)
- **Result**: App always works, even if all Google APIs fail

### 4. Timeout Protection
- **Gemini**: 1-second timeout prevents slow/expensive calls
- **Places API**: 30-second timeout prevents hanging requests

---

## Quota Management Recommendations

### 1. Set Daily Quotas
- **Places API**: Lower from 650 to 20-50 for testing
- **Directions API**: Set to 100-200 per day
- **Gemini API**: Set to 50-100 per day

### 2. Set Budget Alerts
- **Alert at $1.00**: Get notified immediately if spending starts
- **Alert at $5.00**: Warning before significant charges

### 3. Monitor Usage
- Check Google Cloud Console regularly
- Review API call summaries in app logs
- Watch for unexpected spikes

---

## Summary

**Most users will pay $0/month** due to:
1. Generous free tiers ($200 Places API credit, 2,500 Directions API free requests)
2. Effective caching (most users only use 1-2 locations)
3. Graceful fallbacks (app works even if APIs fail)

**Heavy users** (100+ new locations/month, 1,000+ routes/month) might see:
- **$1-5/month** in costs
- Still very affordable compared to Pro SKU pricing

**The app is designed to be cost-effective** while maintaining excellent functionality through intelligent caching and fallback mechanisms.
