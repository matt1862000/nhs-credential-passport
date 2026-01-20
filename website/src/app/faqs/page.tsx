'use client'

import Link from 'next/link'
import Navbar from '@/components/Navbar'
import Footer from '@/components/Footer'

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
                    WaitWell is currently available for iOS devices (iPhone and iPad). The app requires iOS 17.0 or later and integrates with Apple HealthKit for activity tracking.
                  </p>
                </div>
              </div>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Using the App</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">How do I get started?</h3>
                  <p>
                    After downloading WaitWell from the App Store, you'll need to:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li>Grant location permissions so the app can provide navigation</li>
                    <li>Allow HealthKit access if you want to track your steps and activity</li>
                    <li>Scan the QR code at your clinic or manually enter your appointment details</li>
                    <li>View your wait time and suggested walking routes</li>
                  </ul>
                </div>

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
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What if I get lost or need to return early?</h3>
                  <p>
                    WaitWell provides turn-by-turn navigation to help you stay on track. If you need to return to the clinic early, you can:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li>Use the "Return to Clinic" feature to get directions back</li>
                    <li>Follow the return route that's automatically calculated</li>
                    <li>The app will alert you when it's time to head back based on your wait time</li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">What are the breathing exercises?</h3>
                  <p>
                    WaitWell includes breathing exercises (such as the 4-7-8 pattern) to help you relax and manage stress while waiting. These are optional wellness features designed to support your mental wellbeing during your appointment wait.
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
                    <li>Appointment information you provide (clinic location, clinician details)</li>
                    <li>Device information for app functionality</li>
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
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Technical Support</h2>
              
              <div className="space-y-6">
                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">The app isn't working correctly. What should I do?</h3>
                  <p>
                    Try these troubleshooting steps:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li>Ensure you have granted location permissions</li>
                    <li>Check that you have an internet connection (for initial route loading)</li>
                    <li>Restart the app</li>
                    <li>Update to the latest version from the App Store</li>
                    <li>If issues persist, contact us at <a href="mailto:raihan.talukdar@nhs.net" className="text-teal-600 dark:text-teal-accent hover:underline">raihan.talukdar@nhs.net</a></li>
                  </ul>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Why aren't directions advancing correctly?</h3>
                  <p>
                    WaitWell uses GPS to track your progress along routes. If directions seem to be advancing too quickly or incorrectly, this may be due to:
                  </p>
                  <ul className="list-disc pl-6 space-y-2 mt-2">
                    <li>GPS accuracy issues (the app filters poor GPS readings)</li>
                    <li>Using a cached route from a different starting location</li>
                    <li>Standing still near a waypoint</li>
                  </ul>
                  <p className="mt-4">
                    The app requires consistent forward movement to advance waypoints, which helps prevent GPS jitter from causing incorrect direction updates.
                  </p>
                </div>

                <div>
                  <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">My clinic isn't listed. Can I still use WaitWell?</h3>
                  <p>
                    Yes! You can manually enter your clinic location and appointment details. However, real-time wait times are only available for participating clinics. You can still use WaitWell to find walking routes near any clinic location.
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
