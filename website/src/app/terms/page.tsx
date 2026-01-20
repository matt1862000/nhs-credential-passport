'use client'

import Link from 'next/link'
import Navbar from '@/components/Navbar'
import Footer from '@/components/Footer'

export default function PrivacyPolicy() {
  return (
    <>
      <Navbar />
      <div className="min-h-screen bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 py-12 sm:py-16">
          <Link href="/" className="inline-flex items-center gap-2 text-teal-600 dark:text-teal-accent hover:text-teal-700 dark:hover:text-teal-400 mb-8">
            ← Back to Home
          </Link>
          
          <h1 className="text-4xl sm:text-5xl font-bold dark:text-white text-slate-900 mb-4">Privacy Policy</h1>
          <p className="text-slate-600 dark:text-white/60 mb-8">Last updated: {new Date().toLocaleDateString('en-GB', { year: 'numeric', month: 'long', day: 'numeric' })}</p>

          <div className="prose prose-slate dark:prose-invert max-w-none space-y-6 text-slate-700 dark:text-white/80">
            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">1. Introduction</h2>
              <p>
                WaitWell ("we", "our", or "us") is committed to protecting your privacy. This Privacy Policy explains how we collect, use, disclose, and safeguard your information when you use our mobile application and related services.
              </p>
              <p>
                WaitWell is a health and wellness application designed to support NHS patients during clinic wait times. We are committed to maintaining the highest standards of data protection in accordance with UK data protection laws, including the UK GDPR and Data Protection Act 2018.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">2. Information We Collect</h2>
              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">2.1 Personal Information</h3>
              <p>We may collect the following types of personal information:</p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Location data (GPS coordinates) when you use the walking route features</li>
                <li>Health and fitness data (steps, distance walked) through HealthKit integration</li>
                <li>Appointment information (clinic location, clinician details) that you provide</li>
                <li>Device information (device type, operating system, app version)</li>
                <li>Usage data (features used, time spent in app)</li>
              </ul>

              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">2.2 Health Data</h3>
              <p>
                WaitWell integrates with Apple HealthKit to track your physical activity. All health data remains on your device and is never transmitted to our servers without your explicit consent. You can revoke HealthKit access at any time through your device settings.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">3. How We Use Your Information</h2>
              <p>We use the information we collect to:</p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Provide and improve our services, including route navigation and wellness features</li>
                <li>Personalize your experience within the app</li>
                <li>Ensure app functionality and troubleshoot technical issues</li>
                <li>Comply with legal obligations and protect our legal rights</li>
                <li>Send you important updates about the app (with your consent)</li>
              </ul>
              <p className="mt-4">
                <strong>We do not sell, rent, or share your personal information with third parties for marketing purposes.</strong>
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">4. Data Storage and Security</h2>
              <p>
                Your data is stored securely using industry-standard encryption. Location data and route information are cached locally on your device to enable offline functionality. We use Firebase for backend services, which complies with international data protection standards.
              </p>
              <p className="mt-4">
                We implement appropriate technical and organizational measures to protect your personal information against unauthorized access, alteration, disclosure, or destruction.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">5. Your Rights</h2>
              <p>Under UK data protection law, you have the right to:</p>
              <ul className="list-disc pl-6 space-y-2">
                <li><strong>Access:</strong> Request a copy of the personal data we hold about you</li>
                <li><strong>Rectification:</strong> Request correction of inaccurate data</li>
                <li><strong>Erasure:</strong> Request deletion of your personal data</li>
                <li><strong>Restriction:</strong> Request limitation of processing</li>
                <li><strong>Portability:</strong> Request transfer of your data to another service</li>
                <li><strong>Objection:</strong> Object to processing of your personal data</li>
              </ul>
              <p className="mt-4">
                To exercise these rights, please contact us using the information provided in Section 8.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">6. Data Retention</h2>
              <p>
                We retain your personal information only for as long as necessary to provide our services and comply with legal obligations. Location data is typically retained for the duration of your active use of route features. You can delete your data at any time by uninstalling the app or contacting us.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">7. Children's Privacy</h2>
              <p>
                WaitWell is not intended for children under the age of 13. We do not knowingly collect personal information from children. If you believe we have inadvertently collected information from a child, please contact us immediately.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">8. Contact Us</h2>
              <p>
                If you have questions about this Privacy Policy or wish to exercise your data protection rights, please contact us:
              </p>
              <p className="mt-4">
                <strong>Email:</strong> privacy@waitwell.app<br />
                <strong>Address:</strong> NHS Innovation, Sheffield, UK
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">9. Changes to This Policy</h2>
              <p>
                We may update this Privacy Policy from time to time. We will notify you of any material changes by posting the new policy on this page and updating the "Last updated" date. Your continued use of the app after such changes constitutes acceptance of the updated policy.
              </p>
            </section>
          </div>
        </div>
      </div>
      <Footer />
    </>
  )
}
