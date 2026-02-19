'use client'

import Link from 'next/link'
import Navbar from '../../components/Navbar'
import Footer from '../../components/Footer'

export default function HelpCentre() {
  return (
    <>
      <Navbar />
      <div className="min-h-screen bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight pt-20 sm:pt-24">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 py-12 sm:py-16">
          <Link href="/" className="inline-flex items-center gap-2 text-teal-600 dark:text-teal-accent hover:text-teal-700 dark:hover:text-teal-400 mb-8">
            ← Back to Home
          </Link>
          
          <h1 className="text-4xl sm:text-5xl font-bold dark:text-white text-slate-900 mb-4">Help Centre</h1>
          <p className="text-slate-600 dark:text-white/60 mb-8">Step-by-step guides and tutorials to help you get the most out of WaitWell</p>

          <div className="prose prose-slate dark:prose-invert max-w-none space-y-8 text-slate-700 dark:text-white/80">
            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Getting Started</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">First Time Setup</h3>
                  <p>After downloading WaitWell from the App Store:</p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li>Open the app and grant location permissions when prompted</li>
                    <li>Allow HealthKit access if you want to track your steps and activity (optional)</li>
                    <li>Grant camera permissions if you want to scan QR codes</li>
                    <li>Complete the onboarding tutorial (first time only)</li>
                    <li>You're ready to use WaitWell at your next clinic appointment!</li>
                  </ol>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How to Scan the Clinic QR Code</h3>
                  <ol className="list-decimal pl-6 space-y-2">
                    <li>Open WaitWell when you arrive at your clinic</li>
                    <li>Look for the QR code displayed in the waiting area or at reception</li>
                    <li>Tap the QR scanner icon in the app</li>
                    <li>Point your camera at the QR code</li>
                    <li>The app will automatically detect and load your appointment information</li>
                    <li>If scanning fails, you can manually enter your clinic and clinician details</li>
                  </ol>
                  <p className="mt-4 text-sm text-slate-600 dark:text-white/60">
                    <strong>Tip:</strong> Ensure good lighting and hold your phone steady. The QR code should fill most of the camera viewfinder.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How to Select a Walking Route</h3>
                  <ol className="list-decimal pl-6 space-y-2">
                    <li>After scanning the QR code, you'll see your current wait time</li>
                    <li>Tap the "Walk" tab at the bottom of the screen</li>
                    <li>Browse the available routes - each shows duration, distance, and steps</li>
                    <li>Routes are automatically filtered to fit within your wait time</li>
                    <li>Tap on a route to see details and points of interest</li>
                    <li>Tap "Start Walk" to begin navigation</li>
                  </ol>
                  <p className="mt-4 text-sm text-slate-600 dark:text-white/60">
                    <strong>Tip:</strong> Choose a route that's shorter than your wait time to ensure you have time to return.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How to Use Turn-by-Turn Navigation</h3>
                  <ol className="list-decimal pl-6 space-y-2">
                    <li>After starting a route, the map view will appear</li>
                    <li>The top banner shows your next turn instruction (e.g., "Turn right onto Park Lane")</li>
                    <li>Follow the teal route line on the map</li>
                    <li>Waypoint markers show key points: Start, Pharmacy, Dentist, End</li>
                    <li>As you approach each waypoint, directions will automatically update</li>
                    <li>The bottom card shows distance remaining and your current step count</li>
                  </ol>
                  <p className="mt-4 text-sm text-slate-600 dark:text-white/60">
                    <strong>Tip:</strong> Keep your phone accessible but stay aware of your surroundings. The app will alert you when it's time to return.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How to Use Breathing Exercises</h3>
                  <ol className="list-decimal pl-6 space-y-2">
                    <li>Tap the "Wellbeing" tab at the bottom of the screen</li>
                    <li>Select "Breathing Exercises" from the categories</li>
                    <li>Choose an exercise (e.g., 4-7-8 Pattern, Box Breathing)</li>
                    <li>Follow the on-screen instructions and animated guide</li>
                    <li>Breathe in sync with the expanding circle</li>
                    <li>Complete the cycle as shown on screen</li>
                  </ol>
                  <p className="mt-4 text-sm text-slate-600 dark:text-white/60">
                    <strong>Tip:</strong> Breathing exercises can be done anywhere - in the waiting room or during your walk.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How to View Your Progress</h3>
                  <ol className="list-decimal pl-6 space-y-2">
                    <li>Tap the "Progress" tab at the bottom of the screen</li>
                    <li>View your total steps, distance walked, and points earned</li>
                    <li>Check your badges and achievements</li>
                    <li>See your walking history and route completions</li>
                    <li>View your HealthKit integration status (if enabled)</li>
                  </ol>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How to Edit Appointment Details</h3>
                  <ol className="list-decimal pl-6 space-y-2">
                    <li>On the main wait time screen, look for the pencil icon next to "Your appointment"</li>
                    <li>Tap the pencil icon to edit</li>
                    <li>Update your clinic location or clinician name</li>
                    <li>Tap "Save" to confirm changes</li>
                  </ol>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">How Route Generation Works</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">AI-Powered Route Naming</h3>
                  <p>
                    WaitWell uses Google's Gemini AI to generate creative, personalized names and descriptions for each route:
                  </p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li><strong>Route Analysis:</strong> The AI analyzes all points of interest (POIs) along your route, including their types (cafes, parks, churches, shops, etc.) and locations</li>
                    <li><strong>Creative Naming:</strong> Based on the specific POIs, route duration, and distance, the AI generates a fun, memorable route name (e.g., "Pub & Spire Stroll", "Bakery Loop", "Garden Gateway")</li>
                    <li><strong>Detailed Descriptions:</strong> The AI creates warm, specific descriptions mentioning actual places you'll pass, what you might see or experience, and concrete details about each location</li>
                    <li><strong>Template Fallback:</strong> If AI generation isn't available, the app uses intelligent templates based on the route's key features</li>
                  </ol>
                  <p className="mt-4">
                    <strong>Why AI?</strong> This ensures every route feels unique and personalized, making your walk more engaging and helping you remember the route by its distinctive name and description.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How POI Arrival Detection Works</h3>
                  <p>
                    When you approach a point of interest (POI) along your route, WaitWell automatically detects your arrival:
                  </p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li><strong>GPS Tracking:</strong> The app continuously monitors your location using GPS as you walk</li>
                    <li><strong>Dynamic Activation Radius:</strong> Each POI has a "detection zone" that adapts based on how far the POI is from the walking route:
                      <ul className="list-disc pl-6 mt-2 space-y-1">
                        <li>POIs right on the route (cafes, bus stops): ~25 meter detection radius</li>
                        <li>POIs set back from the route (schools, parks): up to 75 meter detection radius</li>
                      </ul>
                    </li>
                    <li><strong>Proximity Check:</strong> When you enter a POI's detection zone, the app calculates your distance to the POI</li>
                    <li><strong>Arrival Confirmation:</strong> Once you're within the activation radius, the app:
                      <ul className="list-disc pl-6 mt-2 space-y-1">
                        <li>Records that you've visited the POI</li>
                        <li>Sends you a notification about the arrival</li>
                        <li>Offers to take a photo at the location (for QR markers)</li>
                        <li>Awards points for visiting the POI</li>
                        <li>Tracks the visit in your progress</li>
                      </ul>
                    </li>
                    <li><strong>Smart Filtering:</strong> The app filters out GPS inaccuracies and only records arrivals when you're genuinely close to the POI, preventing false detections</li>
                  </ol>
                  <p className="mt-4">
                    <strong>Note:</strong> POI detection works best when you're actively walking and have good GPS signal. If you're indoors or in an area with poor GPS, detection may be delayed until you're closer to the POI.
                  </p>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Navigation & Routes</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What if I Get Lost or Need to Return Early?</h3>
                  <p>
                    If you need to return to the clinic early or get lost:
                  </p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li>Look for the "Return to Clinic" button or option in the app</li>
                    <li>The app will calculate a direct route back to your clinic</li>
                    <li>Follow the return route directions shown on the map</li>
                    <li>The app will guide you back with turn-by-turn navigation</li>
                    <li>If you're truly lost, you can also use your phone's standard Maps app with the clinic address</li>
                  </ol>
                  <p className="mt-4">
                    <strong>Tip:</strong> The app automatically alerts you when it's time to head back based on your wait time, so you shouldn't need to manually return unless there's an emergency.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">QR Marker Scanning Guide</h3>
                  <p>
                    Some routes include QR markers for additional content:
                  </p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li>QR markers appear as special waypoints along certain routes</li>
                    <li>When you approach a marker, you'll receive a notification</li>
                    <li>Tap the notification to open the QR scanner</li>
                    <li>Point your camera at the QR marker</li>
                    <li>Scan the marker to unlock wellbeing content, nature facts, or digital skills tips</li>
                    <li>Earn bonus points for scanning markers</li>
                    <li>Markers you've visited are tracked in your progress</li>
                  </ol>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Understanding the Interface</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Understanding the Map View</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li><strong>Teal Route Line:</strong> Your walking path - follow this line</li>
                    <li><strong>Blue Circle (You):</strong> Your current location with a pulsing animation</li>
                    <li><strong>Waypoint Markers:</strong> Colored circles showing key points:
                      <ul className="list-disc pl-6 mt-2 space-y-1">
                        <li>Teal circle = Start/End point</li>
                        <li>Red/Brown circle = Pharmacy or POI</li>
                        <li>Gold/Brown circle = Dentist or destination</li>
                      </ul>
                    </li>
                    <li><strong>Route Labels:</strong> Text labels (Start, Pharmacy, Dentist, End) appear next to waypoints</li>
                    <li><strong>Return Route:</strong> Dashed blue line showing your path back to the clinic</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Reading the Navigation Banner</h3>
                  <p>
                    The top navigation banner shows:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li><strong>Turn Instruction:</strong> Your next turn (e.g., "Turn right onto Park Lane")</li>
                    <li><strong>Distance to Turn:</strong> How far until the turn (e.g., "50m")</li>
                    <li><strong>Distance Walked:</strong> Total distance covered so far</li>
                    <li><strong>Time Remaining:</strong> Minutes left until you should return</li>
                    <li><strong>Distance Remaining:</strong> Kilometers left on your route</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Using the Wellbeing Features</h3>
                  <p>
                    The Wellbeing tab includes:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li><strong>Breathing Exercises:</strong> 4-7-8 Pattern, Box Breathing, Grounding Breath</li>
                    <li><strong>Gratitude Journal:</strong> Daily prompts for reflection and mindfulness</li>
                    <li><strong>Nature Facts:</strong> Mindful connection to your surroundings</li>
                    <li><strong>Digital Skills:</strong> Tips for using the NHS App and QR scanning</li>
                    <li>Access these features anytime, even when not walking</li>
                  </ul>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Best Practices</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Tips for Safe Walking</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li><strong>Stay Aware:</strong> Always be conscious of your surroundings - don't stare at your phone</li>
                    <li><strong>Weather Check:</strong> Dress appropriately for the weather conditions</li>
                    <li><strong>Footwear:</strong> Wear comfortable, supportive shoes suitable for walking</li>
                    <li><strong>Traffic:</strong> Follow pedestrian crossings and traffic signals</li>
                    <li><strong>Visibility:</strong> If walking in low light, wear reflective clothing</li>
                    <li><strong>Health First:</strong> If you feel unwell or tired, return to the clinic early</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How to Plan Your Route</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li>Check your wait time before selecting a route</li>
                    <li>Choose a route that's 20-30% shorter than your wait time to allow buffer time</li>
                    <li>Consider the weather - shorter routes may be better in poor conditions</li>
                    <li>Review the route preview to see POIs and points of interest</li>
                    <li>If your wait time changes, the app will suggest new routes automatically</li>
                    <li>Start your walk early to maximize your time</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">When to Start Heading Back</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li><strong>Halfway Alert:</strong> This is a gentle reminder - you can continue but be mindful</li>
                    <li><strong>Return Now Alert:</strong> This is urgent - start heading back immediately</li>
                    <li>The app calculates return time based on your distance from the clinic</li>
                    <li>Always allow extra time - it's better to be early than late</li>
                    <li>If you're unsure, err on the side of caution and return early</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Making the Most of Your Wait Time</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li>Combine walking with wellbeing - do breathing exercises during your walk</li>
                    <li>Use the time to pick up prescriptions at pharmacy POIs</li>
                    <li>Explore new areas around your clinic</li>
                    <li>Take photos of interesting places you discover</li>
                    <li>Use the gratitude journal feature to reflect during your walk</li>
                    <li>Scan QR markers to learn about your local area</li>
                  </ul>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Troubleshooting</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">My Route Isn't Loading</h3>
                  <p>Try these steps:</p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li>Check your internet connection - routes need internet to load initially</li>
                    <li>Ensure location permissions are granted in Settings</li>
                    <li>Try closing and reopening the app</li>
                    <li>Check if your clinic location is correct</li>
                    <li>Try selecting a different route</li>
                    <li>If issues persist, contact support</li>
                  </ol>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">The Map Isn't Showing</h3>
                  <p>Try these steps:</p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li>Grant location permissions when prompted</li>
                    <li>Check Settings → WaitWell → Location → Allow While Using App</li>
                    <li>Ensure GPS is enabled on your device</li>
                    <li>Try moving to an area with better GPS signal (outdoors, away from buildings)</li>
                    <li>Restart the app</li>
                    <li>Restart your device if the issue persists</li>
                  </ol>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Directions Aren't Updating</h3>
                  <p>This can happen if:</p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li><strong>GPS Accuracy:</strong> Poor GPS signal - try moving to an open area</li>
                    <li><strong>Standing Still:</strong> The app requires movement to advance waypoints - start walking</li>
                    <li><strong>Cached Route:</strong> If using a cached route, the app is more conservative about advancing</li>
                    <li><strong>GPS Jitter:</strong> The app filters out inaccurate GPS readings - this is normal</li>
                  </ul>
                  <p className="mt-4">
                    <strong>Solution:</strong> Keep walking consistently. The app requires 15-20 meters of actual movement along the route before advancing to the next waypoint. This prevents GPS jitter from causing incorrect updates.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">I Can't See My Wait Time</h3>
                  <p>Try these steps:</p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li>Ensure you've scanned the QR code at the clinic</li>
                    <li>Check if your clinic participates in WaitWell's wait time system</li>
                    <li>Try manually entering your clinic and clinician details</li>
                    <li>Check your internet connection</li>
                    <li>Wait a few moments for the wait time to load</li>
                    <li>If your clinic doesn't participate, you can still use routes manually</li>
                  </ol>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">QR Code Won't Scan</h3>
                  <p>Try these steps:</p>
                  <ol className="list-decimal pl-6 space-y-2 mt-2">
                    <li>Ensure camera permissions are granted</li>
                    <li>Check Settings → WaitWell → Camera → Allow</li>
                    <li>Improve lighting - QR codes scan better in good light</li>
                    <li>Hold your phone steady and ensure the QR code fills most of the viewfinder</li>
                    <li>Clean your camera lens</li>
                    <li>Try moving closer or further away from the QR code</li>
                    <li>If scanning fails, you can manually enter appointment details</li>
                  </ol>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Quick Reference</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Icon Glossary</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li><strong>⏰ Clock:</strong> Wait time / Time remaining</li>
                    <li><strong>🚶 Walking Figure:</strong> Walking routes / Steps</li>
                    <li><strong>❤️ Heart:</strong> Wellbeing features</li>
                    <li><strong>🏆 Trophy:</strong> Progress and achievements</li>
                    <li><strong>📍 Pin:</strong> Location / Waypoint</li>
                    <li><strong>📷 Camera:</strong> QR scanner</li>
                    <li><strong>✏️ Pencil:</strong> Edit appointment details</li>
                    <li><strong>↩️ Arrow:</strong> Return to clinic</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Status Indicators</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li><strong>Teal/Green:</strong> Active routes, start/end points, positive indicators</li>
                    <li><strong>Red/Brown:</strong> Pharmacies and POIs</li>
                    <li><strong>Gold/Brown:</strong> Destination waypoints</li>
                    <li><strong>Blue:</strong> Return routes, your location</li>
                    <li><strong>Pulsing Circle:</strong> Your current GPS location</li>
                    <li><strong>Solid Circle:</strong> Waypoint markers</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Notification Types</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li><strong>Halfway Alert:</strong> "Start heading back" - you've completed 50% of your route</li>
                    <li><strong>Return Now:</strong> "Time to return" - you've used 80% of your wait time</li>
                    <li><strong>Clinician Ready:</strong> "Your clinician is ready" - return immediately</li>
                    <li><strong>Wait Time Increased:</strong> Your wait time has extended - you have more time</li>
                    <li><strong>Wait Time Decreased:</strong> Your wait time has shortened - return sooner</li>
                    <li><strong>QR Marker Nearby:</strong> A QR marker is close - scan it for bonus content</li>
                  </ul>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Still Need Help?</h2>
              <p>
                If you can't find the answer you're looking for, please <a href="mailto:raihan.talukdar@nhs.net" className="text-teal-600 dark:text-teal-accent hover:underline">contact us</a> or check our <Link href="/faqs" className="text-teal-600 dark:text-teal-accent hover:underline">FAQs</Link> for more information.
              </p>
            </section>
          </div>
        </div>
      </div>
      <Footer />
    </>
  )
}
