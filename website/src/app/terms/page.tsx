'use client'

import Link from 'next/link'
import Navbar from '../../components/Navbar'
import Footer from '../../components/Footer'

export default function TermsOfService() {
  return (
    <>
      <Navbar />
      <div className="min-h-screen bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight pt-20 sm:pt-24">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 py-12 sm:py-16">
          <Link href="/" className="inline-flex items-center gap-2 text-teal-600 dark:text-teal-accent hover:text-teal-700 dark:hover:text-teal-400 mb-8">
            ← Back to Home
          </Link>
          
          <h1 className="text-4xl sm:text-5xl font-bold dark:text-white text-slate-900 mb-4">Terms of Service</h1>
          <p className="text-slate-600 dark:text-white/60 mb-8">Last updated: {new Date().toLocaleDateString('en-GB', { year: 'numeric', month: 'long', day: 'numeric' })}</p>

          <div className="prose prose-slate dark:prose-invert max-w-none space-y-6 text-slate-700 dark:text-white/80">
            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">1. Acceptance of Terms</h2>
              <p>
                By downloading, installing, or using WaitWell ("the App"), you agree to be bound by these Terms of Service ("Terms"). If you do not agree to these Terms, please do not use the App.
              </p>
              <p className="mt-4">
                WaitWell is a health and wellness application designed to support NHS patients during clinic wait times. These Terms govern your use of the App and all related services.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">2. Description of Service</h2>
              <p>WaitWell provides:</p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Walking route suggestions based on clinic wait times</li>
                <li>Turn-by-turn navigation for walking routes</li>
                <li>Health and wellness features including breathing exercises</li>
                <li>Integration with Apple HealthKit for activity tracking</li>
                <li>Real-time wait time information for participating clinics</li>
              </ul>
              <p className="mt-4">
                We reserve the right to modify, suspend, or discontinue any aspect of the service at any time.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">3. User Responsibilities</h2>
              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">3.1 Appropriate Use</h3>
              <p>You agree to use the App only for lawful purposes and in accordance with these Terms. You agree not to:</p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Use the App in any way that violates applicable laws or regulations</li>
                <li>Attempt to gain unauthorised access to the App or its systems</li>
                <li>Interfere with or disrupt the App's functionality</li>
                <li>Use the App while driving or operating a vehicle</li>
                <li>Use the App in a manner that could harm yourself or others</li>
              </ul>

              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">3.2 Safety</h3>
              <p>
                <strong>Important:</strong> Always be aware of your surroundings when using the App, especially when walking. Do not use the App in situations where it may be unsafe or distracting. The App is designed for pedestrian use only and should not be used while driving.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">4. Health and Medical Disclaimer</h2>
              <p>
                <strong>WaitWell is not a medical device and does not provide medical advice, diagnosis, or treatment.</strong> The App is intended for general wellness and informational purposes only.
              </p>
              <p className="mt-4">
                The health and fitness features, including step counting and breathing exercises, are provided for general wellness purposes. They are not intended to replace professional medical advice, diagnosis, or treatment. Always seek the advice of your physician or other qualified health provider with any questions you may have regarding a medical condition.
              </p>
              <p className="mt-4">
                If you have any health concerns or medical conditions, please consult with a healthcare professional before using the App's activity features.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">5. Location Services</h2>
              <p>
                The App requires access to your device's location services to provide route navigation. By using the App, you consent to the collection and use of location data as described in our Privacy Policy. You can disable location services at any time through your device settings, though this may limit the App's functionality.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">6. Intellectual Property</h2>
              <p>
                The App and all content, features, and functionality are owned by WaitWell and its licensors and are protected by UK and international copyright, trademark, and other intellectual property laws.
              </p>
              <p className="mt-4">
                You may not copy, modify, distribute, sell, or lease any part of the App without our prior written consent.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">7. Limitation of Liability</h2>
              <p>
                To the maximum extent permitted by law, WaitWell and its affiliates shall not be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of profits or revenues, whether incurred directly or indirectly, or any loss of data, use, goodwill, or other intangible losses resulting from your use of the App.
              </p>
              <p className="mt-4">
                WaitWell does not guarantee the accuracy, completeness, or timeliness of route information, wait times, or other data provided through the App. Route suggestions are provided for informational purposes only.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">8. Indemnification</h2>
              <p>
                You agree to indemnify and hold harmless WaitWell, its officers, directors, employees, and agents from any claims, damages, losses, liabilities, and expenses (including legal fees) arising out of or relating to your use of the App or violation of these Terms.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">9. Termination</h2>
              <p>
                We may terminate or suspend your access to the App immediately, without prior notice, for any reason, including if you breach these Terms. Upon termination, your right to use the App will cease immediately.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">10. Governing Law</h2>
              <p>
                These Terms shall be governed by and construed in accordance with the laws of England and Wales. Any disputes arising from these Terms or your use of the App shall be subject to the exclusive jurisdiction of the courts of England and Wales.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">11. Changes to Terms</h2>
              <p>
                We reserve the right to modify these Terms at any time. We will notify you of any material changes by posting the updated Terms in the App or on our website. Your continued use of the App after such changes constitutes acceptance of the updated Terms.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">12. Contact Information</h2>
              <p>
                If you have any questions about these Terms, please contact us:
              </p>
              <p className="mt-4">
                <strong>Email:</strong> raihan.talukdar@nhs.net<br />
                <strong>Address:</strong> Sheffield Health Partnership, NHS Foundation Trust, Centre Court, Atlas Way, Sheffield, S4 7QQ
              </p>
            </section>
          </div>
        </div>
      </div>
      <Footer />
    </>
  )
}
