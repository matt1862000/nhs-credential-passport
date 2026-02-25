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
                Cookies are small text files that websites can place on your device. This policy explains what we use on the WaitWell website and app.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">2. Our Website</h2>
              <p>
                <strong>We do not use cookies on this website.</strong> We do not set any cookies for analytics, advertising, or session management.
              </p>
              <p className="mt-4">
                The only thing we store in your browser is your <strong>theme preference</strong> (light, dark, or system) in local storage, so the site remembers how you like it. That is not a cookie; it stays on your device and we do not receive it. You can clear it at any time via your browser’s site data or storage settings.
              </p>
              <p className="mt-4">
                If we introduce cookies in future (for example to improve the site or add features), we will update this policy and, where required by law, ask for your consent before using non-essential cookies.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">3. Mobile App</h2>
              <p>
                The WaitWell mobile app does not use cookies. It may use local storage on your device for things like cached route data and your preferences. That data stays on your device. For details about what the app collects and how we use it, see our <Link href="/privacy" className="text-teal-600 dark:text-teal-accent hover:underline">Privacy Policy</Link>.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">4. Your Rights and Contact</h2>
              <p>
                Under UK data protection law you have the right to be informed about cookies and similar technologies, and to manage or object to their use. Because we do not use cookies on the website, there are no cookie preferences to manage here. If that changes, we will explain how to manage them on this page.
              </p>
              <p className="mt-4">
                If you have questions about this policy or our use of cookies and similar technologies, contact us at <strong>raihan.talukdar@nhs.net</strong> or Sheffield Health Partnership, NHS Foundation Trust, Centre Court, Atlas Way, Sheffield, S4 7QQ. We may update this Cookie Policy from time to time; the "Last updated" date at the top will reflect any changes.
              </p>
            </section>
          </div>
        </div>
      </div>
      <Footer />
    </>
  )
}
