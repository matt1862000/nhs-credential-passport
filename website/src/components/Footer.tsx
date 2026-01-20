'use client'

import Link from 'next/link'
import { motion } from 'framer-motion'

const footerLinks = {
  product: [
    { label: 'Features', href: '#features' },
    { label: 'How It Works', href: '#how-it-works' },
    { label: 'For Clinicians', href: '#for-clinicians' },
    { label: 'Download', href: '#download' },
  ],
  support: [
    { label: 'Help Centre', href: '/help' },
    { label: 'Contact Us', href: '/contact' },
    { label: 'FAQs', href: '/faqs' },
    { label: 'Feedback', href: '/feedback' },
  ],
  legal: [
    { label: 'Privacy Policy', href: '/privacy' },
    { label: 'Terms of Service', href: '/terms' },
    { label: 'Accessibility', href: '/accessibility' },
    { label: 'Cookie Policy', href: '/cookies' },
  ],
}

export default function Footer() {
  return (
    <footer className="relative bg-midnight dark:bg-midnight bg-slate-100 border-t border-white/5 dark:border-white/5 border-slate-300">
      <div className="max-w-7xl mx-auto px-6 py-16">
        <div className="grid md:grid-cols-2 lg:grid-cols-5 gap-12">
          {/* Brand */}
          <div className="lg:col-span-2">
            <Link href="/" className="flex items-center gap-3 mb-6">
              <div className="w-10 h-10 rounded-xl overflow-hidden">
                <img 
                  src="/WalkingWR-Logo.png" 
                  alt="WaitWell Logo" 
                  className="w-full h-full object-contain"
                />
              </div>
              <span className="text-xl font-bold dark:text-white text-slate-800">
                Wait<span className="text-teal-accent dark:text-teal-accent text-teal-600">Well</span>
              </span>
            </Link>
            
            <p className="dark:text-white/50 text-slate-800 mb-6 max-w-sm">
              The Walking Waiting Room - transforming clinic wait times into opportunities for wellness.
            </p>
          </div>

          {/* Links */}
          <div>
            <h4 className="font-semibold dark:text-white text-slate-800 mb-4">Product</h4>
            <ul className="space-y-3">
              {footerLinks.product.map((link) => (
                <li key={link.label}>
                  <Link href={link.href} className="dark:text-white/50 text-slate-800 hover:text-teal-accent dark:hover:text-teal-accent hover:text-teal-700 transition-colors">
                    {link.label}
                  </Link>
                </li>
              ))}
            </ul>
          </div>

          <div>
            <h4 className="font-semibold dark:text-white text-slate-800 mb-4">Support</h4>
            <ul className="space-y-3">
              {footerLinks.support.map((link) => (
                <li key={link.label}>
                  <Link href={link.href} className="dark:text-white/50 text-slate-800 hover:text-teal-accent dark:hover:text-teal-accent hover:text-teal-700 transition-colors">
                    {link.label}
                  </Link>
                </li>
              ))}
            </ul>
          </div>

          <div>
            <h4 className="font-semibold dark:text-white text-slate-800 mb-4">Legal</h4>
            <ul className="space-y-3">
              {footerLinks.legal.map((link) => (
                <li key={link.label}>
                  <Link href={link.href} className="dark:text-white/50 text-slate-800 hover:text-teal-accent dark:hover:text-teal-accent hover:text-teal-700 transition-colors">
                    {link.label}
                  </Link>
                </li>
              ))}
            </ul>
          </div>
        </div>

        {/* Bottom bar */}
        <div className="mt-16 pt-8 border-t border-white/5 flex flex-col md:flex-row items-center justify-between gap-4">
          <div className="dark:text-white/40 text-slate-700 text-sm">
            © {new Date().getFullYear()} WaitWell. All rights reserved.
          </div>
          
          <div className="dark:text-white/40 text-slate-700 text-sm">
            Supported by the Topol Fellowship
          </div>

          {/* Social Links */}
          <div className="flex items-center gap-4">
            <a href="https://x.com/SHSCFT" target="_blank" rel="noopener noreferrer" className="dark:text-white/40 text-slate-700 hover:text-teal-accent dark:hover:text-teal-accent hover:text-teal-700 transition-colors" aria-label="Twitter">
              <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/>
              </svg>
            </a>
            <a href="https://uk.linkedin.com/company/sheffieldpartnership" target="_blank" rel="noopener noreferrer" className="dark:text-white/40 text-slate-700 hover:text-teal-accent dark:hover:text-teal-accent hover:text-teal-700 transition-colors" aria-label="LinkedIn">
              <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                <path d="M20.447 20.452h-3.554v-5.569c0-1.328-.027-3.037-1.852-3.037-1.853 0-2.136 1.445-2.136 2.939v5.667H9.351V9h3.414v1.561h.046c.477-.9 1.637-1.85 3.37-1.85 3.601 0 4.267 2.37 4.267 5.455v6.286zM5.337 7.433c-1.144 0-2.063-.926-2.063-2.065 0-1.138.92-2.063 2.063-2.063 1.14 0 2.064.925 2.064 2.063 0 1.139-.925 2.065-2.064 2.065zm1.782 13.019H3.555V9h3.564v11.452zM22.225 0H1.771C.792 0 0 .774 0 1.729v20.542C0 23.227.792 24 1.771 24h20.451C23.2 24 24 23.227 24 22.271V1.729C24 .774 23.2 0 22.222 0h.003z"/>
              </svg>
            </a>
          </div>
        </div>
      </div>
    </footer>
  )
}
