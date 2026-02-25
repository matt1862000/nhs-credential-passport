'use client'

import Link from 'next/link'
import Navbar from '../../components/Navbar'
import Footer from '../../components/Footer'

export default function Accessibility() {
  return (
    <>
      <Navbar />
      <div className="min-h-screen bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight pt-20 sm:pt-24">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 py-12 sm:py-16">
          <Link href="/" className="inline-flex items-center gap-2 text-teal-600 dark:text-teal-accent hover:text-teal-700 dark:hover:text-teal-400 mb-8">
            ← Back to Home
          </Link>
          
          <h1 className="text-4xl sm:text-5xl font-bold dark:text-white text-slate-900 mb-4">Accessibility Statement</h1>
          <p className="text-slate-600 dark:text-white/60 mb-8">Last updated: {new Date().toLocaleDateString('en-GB', { year: 'numeric', month: 'long', day: 'numeric' })}</p>

          <div className="prose prose-slate dark:prose-invert max-w-none space-y-6 text-slate-700 dark:text-white/80">
            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Our Commitment</h2>
              <p>
                WaitWell is committed to ensuring digital accessibility for people with disabilities. We are continually improving the user experience for everyone and applying the relevant accessibility standards to achieve these goals.
              </p>
              <p className="mt-4">
                This accessibility statement applies to the WaitWell mobile application and website. We aim to conform to the Web Content Accessibility Guidelines (WCAG) 2.1 Level AA standards where applicable.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Accessibility Features</h2>
              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Mobile App</h3>
              <p>The WaitWell iOS app includes the following accessibility features:</p>
              <ul className="list-disc pl-6 space-y-2">
                <li><strong>Dark Mode:</strong> The app supports dark mode to reduce glare and support users who prefer or need a dark theme</li>
                <li><strong>High Contrast:</strong> Support for iOS accessibility settings including increased contrast and reduced transparency</li>
                <li><strong>Colour Blindness:</strong> Colour choices designed to be distinguishable for users with colour vision deficiencies</li>
                <li><strong>Large Touch Targets:</strong> Interactive elements are sized appropriately for easy tapping</li>
              </ul>

              <h3 className="text-xl font-semibold dark:text-white text-slate-900 mt-6 mb-3">Website</h3>
              <p>Our website includes:</p>
              <ul className="list-disc pl-6 space-y-2">
                <li><strong>Dark Mode:</strong> Light, dark, and system theme options so you can choose a comfortable appearance</li>
                <li>Semantic HTML structure for screen reader compatibility</li>
                <li>Keyboard navigation support</li>
                <li>Alt text for images</li>
                <li>Sufficient colour contrast ratios</li>
                <li>Responsive design that works on various screen sizes</li>
                <li>Skip to main content link for keyboard users</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Known Limitations</h2>
              <p>
                While we strive to ensure accessibility, we are aware that some parts of the app may not be fully accessible. We are working to address these issues:
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li>VoiceOver and Dynamic Type are not currently supported in the app; we are working to improve screen reader and text-scaling support</li>
                <li>Some map visualizations may be challenging for users with visual impairments - we provide text-based alternatives where possible</li>
                <li>Route navigation relies on visual cues - we are working to enhance audio and haptic feedback</li>
                <li>Some third-party content may not meet accessibility standards</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Feedback and Reporting Issues</h2>
              <p>
                We welcome feedback on the accessibility of WaitWell. If you encounter accessibility barriers, please contact us:
              </p>
              <ul className="list-disc pl-6 space-y-2 mt-4">
                <li><strong>Email:</strong> raihan.talukdar@nhs.net</li>
              </ul>
              <p className="mt-4">
                When contacting us, please include:
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Description of the accessibility issue</li>
                <li>The page or feature where you encountered the issue</li>
                <li>Your device and operating system version</li>
                <li>Any assistive technology you are using</li>
              </ul>
              <p className="mt-4">
                We aim to respond to accessibility feedback within 5 business days.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Ongoing Improvements</h2>
              <p>
                We are committed to continuously improving the accessibility of WaitWell. Our development process includes:
              </p>
              <ul className="list-disc pl-6 space-y-2">
                <li>Regular accessibility audits and testing</li>
                <li>User testing with people with disabilities</li>
                <li>Training for our development team on accessibility best practices</li>
                <li>Following WCAG guidelines in our design and development process</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Third-Party Content</h2>
              <p>
                WaitWell may include third-party content or links to external websites. We are not responsible for the accessibility of third-party content. If you encounter accessibility issues with third-party content, please contact the provider directly.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Enforcement Procedure</h2>
              <p>
                The Equality and Human Rights Commission (EHRC) is responsible for enforcing the Public Sector Bodies (Websites and Mobile Applications) (No. 2) Accessibility Regulations 2018 (the 'accessibility regulations'). If you are not happy with how we respond to your complaint, contact the <a href="https://www.equalityadvisoryservice.com/" className="text-teal-600 dark:text-teal-accent hover:underline" target="_blank" rel="noopener noreferrer">Equality Advisory and Support Service (EASS)</a>.
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-semibold dark:text-white text-slate-900 mt-8 mb-4">Contact Us</h2>
              <p>
                For questions or concerns about accessibility, please contact us:
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
