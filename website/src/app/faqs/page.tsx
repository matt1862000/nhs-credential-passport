'use client'

import Link from 'next/link'
import Navbar from '../../components/Navbar'
import Footer from '../../components/Footer'

export default function FAQs() {
  return (
    <>
      <Navbar />
      <div className="min-h-screen bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight pt-20 sm:pt-24">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 py-12 sm:py-16">
          <Link href="/" className="inline-flex items-center gap-2 text-teal-600 dark:text-teal-accent hover:text-teal-700 dark:hover:text-teal-400 mb-8">
            ← Back to Home
          </Link>
          
          <h1 className="text-4xl sm:text-5xl font-bold dark:text-white text-slate-900 mb-4">Frequently Asked Questions</h1>
          <p className="text-slate-600 dark:text-white/60 mb-8">Find answers to common questions about WaitWell</p>

          <div className="prose prose-slate dark:prose-invert max-w-none space-y-8 text-slate-700 dark:text-white/80">
            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">General Questions</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What is WaitWell?</h3>
                  <p>
                    WaitWell is a mobile application designed to transform your clinic wait time into an opportunity for wellness. Instead of sitting in the waiting room, WaitWell suggests walking routes based on your appointment's wait time, helping you stay active while you wait.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How does WaitWell work?</h3>
                  <p>
                    When you arrive at your clinic appointment, WaitWell:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li>Shows you the current wait time for your appointment</li>
                    <li>Suggests walking routes that fit within your available wait time</li>
                    <li>Provides turn-by-turn navigation to guide you along the route</li>
                    <li>Highlights points of interest (POIs) along the way, such as pharmacies, cafes, and parks</li>
                    <li>Tracks your steps and distance walked using HealthKit</li>
                    <li>Alerts you when it's time to return to the clinic</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Is WaitWell free to use?</h3>
                  <p>
                    Yes, WaitWell is completely free to use. It's designed to support NHS patients and is supported by the Topol Fellowship (NHS Digital Academy).
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What devices is WaitWell available on?</h3>
                  <p>
                    WaitWell is currently available for iOS devices (iPhone and iPad). The app requires iOS 26.0 or later and integrates with Apple HealthKit for activity tracking.
                  </p>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Using the App</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How accurate are the wait times?</h3>
                  <p>
                    Wait times are provided by participating clinics and updated in real-time. However, wait times can change, so we recommend checking the app periodically and allowing extra time to return to the clinic.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Can I use WaitWell offline?</h3>
                  <p>
                    Yes! WaitWell caches route information for offline use. Once you've loaded a route, you can use it even without an internet connection. However, you'll need internet access to:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li>Get initial route suggestions</li>
                    <li>View updated wait times</li>
                    <li>Load new routes</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What are the breathing exercises?</h3>
                  <p>
                    WaitWell includes breathing exercises (such as the 4-7-8 pattern) to help you relax and manage stress while waiting. These are optional wellness features designed to support your mental wellbeing during your appointment wait.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How do route suggestions work?</h3>
                  <p>
                    WaitWell automatically calculates which routes fit within your available wait time. Routes are filtered to be shorter than your wait time, and each shows estimated duration, distance, and step count. Routes include a return journey back to the clinic, and the app accounts for walking speed (average 1.4 m/s) and adds a safety buffer. If your wait time changes, route suggestions update automatically.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What are Points of Interest (POIs)?</h3>
                  <p>
                    POIs are highlighted locations along your route, such as pharmacies (useful for picking up prescriptions), cafes and shops, and parks and green spaces. POIs are automatically included in route suggestions and are marked with coloured circles on the map. You can see POI details by tapping on them in the route preview.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How do return alerts work?</h3>
                  <p>
                    WaitWell sends smart notifications to ensure you return on time:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li><strong>Halfway Alert:</strong> When you've completed 50% of your route - suggests starting to head back</li>
                    <li><strong>Return Now Alert:</strong> When you've used 80% of your wait time - time to return immediately</li>
                    <li><strong>Clinician Ready:</strong> Immediate notification if your clinician becomes available early</li>
                    <li><strong>Wait Time Increased:</strong> Notification if your wait time extends, giving you more time</li>
                  </ul>
                  <p className="mt-4">
                    All alerts include a return route to guide you back to the clinic.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What is the progress and gamification system?</h3>
                  <p>
                    WaitWell tracks your activity and rewards your wellness:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li><strong>Points:</strong> Earned for completing routes and scanning QR markers</li>
                    <li><strong>Steps:</strong> Tracked via HealthKit integration (optional)</li>
                    <li><strong>Badges:</strong> Unlocked for achievements like "First Steps", "Explorer", "Step Champion"</li>
                    <li><strong>Levels:</strong> Progress through levels as you accumulate points</li>
                    <li><strong>Digital Literacy:</strong> Track your progress with NHS App features and QR scanning</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What do the waypoint markers mean?</h3>
                  <p>
                    Waypoint markers on the map show key points along your route:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li><strong>Blue circle:</strong> Start/End point (your clinic location)</li>
                    <li><strong>Green circle:</strong> POI waypoint (unvisited)</li>
                    <li><strong>Orange circle:</strong> Your next waypoint (with a pulsing ring)</li>
                    <li><strong>Grey circle:</strong> Waypoint you have already passed</li>
                  </ul>
                  <p className="mt-4">
                    Labels show <strong>Start</strong>, the <strong>name of each place</strong> (e.g. pharmacy, café, park), and <strong>Return</strong> for heading back to the clinic.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What does the navigation banner show?</h3>
                  <p>
                    The top navigation banner displays your next turn instruction (e.g., "Turn right onto Park Lane"), distance to the turn, total distance walked, time remaining until you should return, and distance remaining on your route.
                  </p>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Privacy & Data</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What data does WaitWell collect?</h3>
                  <p>
                    WaitWell collects minimal data necessary for functionality:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li>Location data (GPS coordinates) when using route navigation</li>
                    <li>Health and fitness data (steps, distance) through HealthKit - this stays on your device</li>
                    <li>Appointment information you provide (clinician selection, appointment time) - stored only on your device</li>
                  </ul>
                  <p className="mt-4">
                    For more details, please see our <Link href="/privacy" className="text-teal-600 dark:text-teal-accent hover:underline">Privacy Policy</Link>.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Is my health data shared?</h3>
                  <p>
                    No. All health data from HealthKit remains on your device and is never transmitted to our servers without your explicit consent. You can revoke HealthKit access at any time through your device settings.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Can I delete my data?</h3>
                  <p>
                    Yes. You can delete your data at any time by uninstalling the app or contacting us. Location data is typically only retained for the duration of your active use of route features.
                  </p>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Health & Safety</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Is WaitWell a medical device?</h3>
                  <p>
                    <strong>No.</strong> WaitWell is not a medical device and does not provide medical advice, diagnosis, or treatment. The app is intended for general wellness and informational purposes only.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Should I use WaitWell if I have health conditions?</h3>
                  <p>
                    If you have any health concerns or medical conditions that might affect your ability to walk, please consult with a healthcare professional before using WaitWell's activity features. Always prioritize your health and safety.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Is it safe to walk while using the app?</h3>
                  <p>
                    <strong>Always be aware of your surroundings when using WaitWell.</strong> The app is designed for pedestrian use only and should not be used while driving or operating a vehicle. Pay attention to traffic, obstacles, and your environment while walking.
                  </p>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Understanding the Interface</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What do the icons mean?</h3>
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
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What do the colours on the map mean?</h3>
                  <ul className="list-disc pl-6 space-y-2">
                    <li><strong>Teal:</strong> Active outbound route line</li>
                    <li><strong>Blue:</strong> Return route, clinic (start/end) marker, and your current location</li>
                    <li><strong>Green:</strong> Unvisited waypoint markers</li>
                    <li><strong>Orange:</strong> Your next waypoint (highlighted)</li>
                    <li><strong>Grey:</strong> Visited waypoint markers</li>
                    <li><strong>Pulsing blue circle:</strong> Your current GPS position</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What types of notifications will I receive?</h3>
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
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Technical Support</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">My clinic isn't listed. Can I still use WaitWell?</h3>
                  <p>
                    Yes! You can skip selecting a clinician and still use WaitWell. Walk routes are generated from your current location, so you can discover and follow walking routes wherever you are. Real-time wait times and return alerts are only available when you choose a clinician from a participating clinic. Without a listed clinic, you won't get wait-time updates, but you can use the app for walks and wellbeing features.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">I'm having technical issues. Where can I get help?</h3>
                  <p>
                    For detailed troubleshooting guides, please visit our <Link href="/help" className="text-teal-600 dark:text-teal-accent hover:underline">Help Centre</Link>. For specific issues, you can also contact us at <a href="mailto:raihan.talukdar@nhs.net" className="text-teal-600 dark:text-teal-accent hover:underline">raihan.talukdar@nhs.net</a>.
                  </p>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">For Clinicians</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How can my clinic participate in WaitWell?</h3>
                  <p>
                    If you're a clinician or clinic administrator interested in integrating WaitWell at your facility, please contact us at <a href="mailto:raihan.talukdar@nhs.net" className="text-teal-600 dark:text-teal-accent hover:underline">raihan.talukdar@nhs.net</a>. We can help you set up real-time wait time integration and provide support for your patients.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What are the benefits for clinics?</h3>
                  <p>
                    WaitWell helps reduce waiting room congestion, supports patient wellness, and can improve patient satisfaction. Patients who use WaitWell stay active during their wait and return to the clinic on time.
                  </p>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Still Have Questions?</h2>
              <p>
                If you have questions that aren't answered here, please don't hesitate to <a href="mailto:raihan.talukdar@nhs.net" className="text-teal-600 dark:text-teal-accent hover:underline">contact us</a>. We're here to help!
              </p>
            </section>
          </div>
        </div>
      </div>
      <Footer />
    </>
  )
}
