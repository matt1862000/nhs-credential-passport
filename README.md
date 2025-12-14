# Walking Waiting Room 🚶‍♂️

**A gamified walking and wellbeing app for NHS Decisions Unit patients**

Transform waiting time into health time with real-time wait displays, walking routes, and wellbeing activities.

---

## Overview

The Walking Waiting Room app addresses a critical healthcare challenge: **uncertain waits increase anxiety and lead to early self-discharge**. This iOS app provides:

- **Real-time wait information** fed from clinic systems (EPR)
- **Walking routes** matched to wait duration with smart return alerts
- **Gamified wellbeing content** via QR markers
- **Step tracking** with HealthKit integration
- **Anxiety monitoring** with before/after comparisons

## Key Features

### 1. Real-Time Wait Display
- Live estimated wait time from clinic flow
- Queue position and clinician information
- Last updated timestamp for transparency

### 2. Walking Routes
Four routes optimized for different wait durations:

| Route | Duration | Steps | Indoor |
|-------|----------|-------|--------|
| Corridor Circuit | 5 min | ~400 | ✅ |
| Courtyard Calm | 10 min | ~650 | ❌ |
| Green Loop | 15 min | ~1,200 | ❌ |
| Longley Explorer | 20 min | ~1,600 | ❌ |

### 3. Smart Notifications
- **Halfway alerts**: "Start heading back" at route midpoint
- **Return alerts**: When route is complete
- **Clinician ready**: Immediate return notification
- **Delay updates**: If wait time changes

### 4. Gamification
- Points for completing routes and scanning QR markers
- Badges for achievements (First Steps, Explorer, Step Champion)
- Level progression system
- Digital literacy progress tracking

### 5. Wellbeing Content
- **Breathing exercises**: Box Breathing, 4-7-8 Relaxation, Grounding Breath
- **Gratitude journal**: Daily prompts and reflection
- **Nature facts**: Mindful connection to surroundings
- **Digital skills**: NHS App tips, QR scanning guidance

### 6. Health Integration
- HealthKit step counting during walks
- Heart rate monitoring (if Apple Watch connected)
- Anxiety level tracking (VAS scale)

---

## Project Structure

```
WalkingWR/
├── Models/
│   └── Models.swift           # Data models (routes, badges, content)
├── Services/
│   ├── HealthKitService.swift # HealthKit integration
│   └── NotificationService.swift
├── ViewModels/
│   └── WaitingRoomViewModel.swift
├── Views/
│   ├── Theme/
│   │   └── AppTheme.swift     # Colors, fonts, modifiers
│   ├── MainTabView.swift      # App navigation + onboarding
│   ├── WaitTimeView.swift     # Main wait display
│   ├── RouteSelectionView.swift
│   ├── WellbeingView.swift
│   ├── ProfileView.swift
│   └── QRScannerView.swift
└── Assets.xcassets/
    └── Colors/                # Custom color palette
```

---

## Design System

### Colors
- **Teal Accent** `#2EA3A3` - Primary actions
- **Mint Green** `#8FD1BA` - Success, nature
- **Forest Green** `#337859` - Routes, outdoor
- **Soft Amber** `#F3C46B` - Warnings, digital tips
- **Coral Pink** `#F38C8C` - Alerts, anxiety indicators
- **Lavender Mist** `#BAADDE` - Wellbeing, breathing

### Typography
- Display: SF Rounded Bold (48pt)
- Titles: SF Rounded Semibold (20-24pt)
- Body: SF Rounded Regular (15-17pt)

---

## Requirements

- iOS 17.0+
- Xcode 15.0+
- HealthKit capability (optional)
- Camera permission (for QR scanning)

## Getting Started

1. Open `WalkingWR.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Enable HealthKit capability if using step tracking
4. Build and run on device (QR scanner requires physical device)

---

## Success Metrics (90-day pilot)

| Metric | Target |
|--------|--------|
| Patient uptake | ≥ 50% eligible |
| Steps per visit | ≥ 1,000 average |
| Positive feedback | ≥ 80% |
| Digital literacy engagement | ≥ 30% |
| Left-before-seen | ↓ from baseline |

---

## Future Roadmap

- [ ] EPR integration (live clinic flow)
- [ ] SMS notification fallback
- [ ] Apple Watch companion app
- [ ] Social prescribing links (Sheffield Health Walks)
- [ ] Multi-language support
- [ ] Inpatient ward adaptation (Section 17 leave)

---

## Clinical Safety

This app is designed to comply with:
- **DCB0129/DCB0160** Clinical Safety Standards
- **DTAC** Digital Technology Assessment Criteria
- **UK GDPR** Data protection
- **NHS DSPT** Data Security and Protection Toolkit

---

## Contributors

Developed for the Decisions Unit at Longley Centre, Sheffield Health & Social Care NHS Foundation Trust.

Part of the Quality Improvement initiative to reduce waiting-related anxiety and improve patient experience.

---

*"Turning waiting time into health time"* 💚


