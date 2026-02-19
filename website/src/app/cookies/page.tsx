'use client'

import Link from 'next/link'
import Navbar from '../../components/Navbar'
import Footer from '../../components/Footer'

export default function CookiePolicy() {
  return (
    <>
      <Navbar />
      <div className="min-h-screen bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight pt-20 sm:pt-24">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 py-12 sm:py-16">
          <Link href="/" className="inline-flex items-center gap-2 text-teal-600 dark:text-teal-accent hover:text-teal-700 dark:hover:text-teal-400 mb-8">
            ← Back to Home
          </Link>
          
          <h1 className="text-4xl sm:text-5xl font-bold dark:text-white text-slate-900 mb-4">Cookie Policy</h1>
          <p className="text-slate-600 dark:text-white/60 mb-8">Last updated: {new Date().toLocaleDateString('en-GB', { year: 'numeric', month: 'long', day: 'numeric' })}</p>

          <div className="prose prose-slate dark:prose-invert max-w-none space-y-6 text-slate-700 dark:text-white/80">
            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">1. What Are Cookies?</h2>
              <p>
                Cookies are small text files that are placed on your device when you visit a website or use a mobile application. They are widely used to make websites and apps work more efficiently and to provide information to the owners of the site or app.
              </p>
              <p className="mt-4">
                This Cookie Policy explains how WaitWell uses cookies and similar technologies on our website and in our mobile application.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">2. How We Use Cookies</h2>
              <p>WaitWell uses cookies and similar technologies for the following purposes:</p>
              
              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">2.1 Essential Cookies</h3>
              <p>
                These cookies are necessary for the website and app to function properly. They enable core functionality such as security, network management, and accessibility. You cannot opt out of these cookies as they are essential for the service to work.
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Session management</li>
                <li>Security and authentication</li>
                <li>Load balancing</li>
              </ul>

              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">2.2 Analytics Cookies</h3>
              <p>
                These cookies help us understand how visitors interact with our website and app by collecting and reporting information anonymously. This helps us improve our services.
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Page views and navigation patterns</li>
                <li>Feature usage statistics</li>
                <li>Performance monitoring</li>
              </ul>

              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">2.3 Functional Cookies</h3>
              <p>
                These cookies enable enhanced functionality and personalization. They may be set by us or by third-party providers whose services we use.
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li>User preferences (theme, language settings)</li>
                <li>Remembering your settings</li>
                <li>Improving user experience</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">3. Third-Party Cookies</h2>
              <p>
                Some cookies are placed by third-party services that appear on our pages. We use the following third-party services:
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li><strong>Firebase:</strong> For backend services and analytics (Google)</li>
                <li><strong>Google Maps:</strong> For map and route services</li>
              </ul>
              <p className="mt-4">
                These third parties may use cookies to collect information about your online activities across different websites. We do not control these third-party cookies. Please refer to the privacy policies of these third parties for more information.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">4. Mobile App</h2>
              <p>
                Our mobile app may use similar technologies to cookies, such as:
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Local storage for caching route data and preferences</li>
                <li>Device identifiers for analytics and app functionality</li>
                <li>Location data (with your permission) for route navigation</li>
              </ul>
              <p className="mt-4">
                These technologies are used to provide app functionality and improve your experience. You can control location permissions through your device settings.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">5. Managing Cookies</h2>
              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">5.1 Website</h3>
              <p>
                Most web browsers allow you to control cookies through their settings. You can set your browser to refuse cookies or to alert you when cookies are being sent. However, if you disable cookies, some parts of our website may not function properly.
              </p>
              <p className="mt-4">
                To manage cookies in your browser:
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li><strong>Chrome:</strong> Settings → Privacy and security → Cookies and other site data</li>
                <li><strong>Firefox:</strong> Options → Privacy & Security → Cookies and Site Data</li>
                <li><strong>Safari:</strong> Preferences → Privacy → Cookies and website data</li>
                <li><strong>Edge:</strong> Settings → Cookies and site permissions</li>
              </ul>

              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">5.2 Mobile App</h3>
              <p>
                For the mobile app, you can manage permissions and data through your device settings:
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li><strong>iOS:</strong> Settings → WaitWell → Permissions and Data</li>
                <li>You can also delete and reinstall the app to clear stored data</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">6. Your Rights</h2>
              <p>
                Under UK data protection law, you have the right to:
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Be informed about the use of cookies</li>
                <li>Give or withdraw consent for non-essential cookies</li>
                <li>Access information about cookies used</li>
                <li>Request deletion of cookie data</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">7. Updates to This Policy</h2>
              <p>
                We may update this Cookie Policy from time to time to reflect changes in our practices or for other operational, legal, or regulatory reasons. We will notify you of any material changes by posting the updated policy on this page and updating the "Last updated" date.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">8. Contact Us</h2>
              <p>
                If you have questions about our use of cookies, please contact us:
              </p>
              <p className="mt-4">
                <strong>Email:</strong> privacy@waitwell.app<br />
                <strong>Address:</strong> NHS Innovation, Sheffield, UK
              </p>
            </section>
          </div>
        </div>
      </div>
      <Footer />
    </>
  )
}
