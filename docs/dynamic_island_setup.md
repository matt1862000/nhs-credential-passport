# Dynamic Island & Live Activity Setup

WalkingWR can show an **active walk** in the **Dynamic Island** (iPhone 14 Pro and later) and on the **Lock Screen** via Live Activities.

## What’s included

- **WalkingWRWidget/** – Widget Extension source (attributes + UI).
- **WalkLiveActivityBridge** – App-side start/update/end in `WalkingWR/Services/WalkLiveActivityBridge.swift`.
- **ViewModel** – `WaitingRoomViewModel` starts the activity in `startWalk()`, updates it every second in `updateSession()`, and ends it in `endWalk()`.

## Xcode setup (already done)

The project is already configured: **WalkingWRWidget** target is added and embedded in the app; **WalkActivityAttributes.swift** is compiled in both targets. Just build the **WalkingWR** scheme.

_(Previously: manual steps)_

1. **Add the Widget Extension target**
   - In Xcode: **File → New → Target…**
   - Choose **Widget Extension**, Next.
   - **Product Name:** `WalkingWRWidget`
   - **Include Live Activity:** checked
   - **Include Configuration App Intent:** unchecked (optional)
   - Finish. If asked “Activate scheme?”, choose **Cancel** (keep running the main app).

2. **Replace the generated widget code**
   - Delete the Swift files Xcode created inside the new **WalkingWRWidget** group (e.g. a default widget + maybe an attributes file).
   - In the Project Navigator, **right‑click the WalkingWRWidget group → Add Files to "WalkingWR"...**
   - Select the **WalkingWRWidget** folder at the project root (the one that contains `WalkActivityAttributes.swift`, `WalkLiveActivity.swift`, `WalkingWRWidgetBundle.swift`).
   - Leave **Copy items if needed** unchecked, **Add to targets:** **WalkingWRWidget** only.
   - Ensure the three Swift files are in the **WalkingWRWidget** target (check Target Membership in the File inspector).

3. **Embed the extension in the app**
   - Select the **WalkingWR** project → **WalkingWR** app target → **General** tab.
   - Under **Frameworks, Libraries, and Embedded Content**, click **+**.
   - Add **WalkingWRWidget.appex** and set it to **Embed & Sign** (so the app can use the Live Activity and the system can show it).

4. **Build**
   - Build the **WalkingWR** scheme. The app will start/update/end the Live Activity when a walk starts, runs, and ends.

## Behaviour

- **Compact (Dynamic Island):** Walking icon + “Xm” (minutes left) or elapsed.
- **Expanded (long‑press island):** Route name, elapsed time, minutes left, “Heading back” when relevant, progress bar.
- **Lock Screen:** Same as expanded content.

The activity is started in `startWalk()`, updated every second from `updateSession()`, and ended in `endWalk()`. No push notification is used; updates are local only.

## Requirements

- **iOS 16.2+** for Live Activities.
- **iPhone 14 Pro or later** for the Dynamic Island; older devices still get the Lock Screen (and banner) presentation.

## Why am I seeing a “widget” instead of the Dynamic Island?

- **Dynamic Island (the pill)** only appears on devices that have it: **iPhone 14 Pro / 14 Pro Max, iPhone 15 / 15 Plus / 15 Pro / 15 Pro Max, iPhone 16 series**, etc.  
  If you’re on **iPhone 14 or 14 Plus** (notch), or an older device/simulator, you’ll only see the **Lock Screen card** or the **banner** at the top — that’s the same Live Activity, not a different widget.

- **Simulator:** to see the island, pick a simulator that has it, e.g. **iPhone 15 Pro**, **iPhone 16**, or **iPhone 16 Pro** (not “iPhone 14” or “iPhone SE”).

- **When the device is locked**, the system shows the **full card** on the Lock Screen (the big “widget” view). That’s normal. To see the **compact pill in the island**, **unlock** the device, start a walk, then **leave the app** (home button or swipe up). The pill should appear in the black island at the top of the screen; long‑press it to see the expanded view.

## Optional

- To disable Live Activities for testing, you can gate the bridge calls in `WaitingRoomViewModel` (e.g. with a feature flag or `#if DEBUG`).
