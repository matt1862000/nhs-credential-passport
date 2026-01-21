'use client'

import { useState, useEffect } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import Link from 'next/link'
import { useTheme } from '@/contexts/ThemeContext'

export default function Navbar() {
  const [isScrolled, setIsScrolled] = useState(false)
  const [isMobileMenuOpen, setIsMobileMenuOpen] = useState(false)
  const { theme, toggleTheme } = useTheme()

  useEffect(() => {
    const handleScroll = () => {
      setIsScrolled(window.scrollY > 50)
    }
    window.addEventListener('scroll', handleScroll)
    return () => window.removeEventListener('scroll', handleScroll)
  }, [])

  // Prevent body scroll when mobile menu is open
  useEffect(() => {
    if (isMobileMenuOpen) {
      document.body.style.overflow = 'hidden'
    } else {
      document.body.style.overflow = 'unset'
    }
    return () => {
      document.body.style.overflow = 'unset'
    }
  }, [isMobileMenuOpen])

  const navLinks = [
    { href: '/#features', label: 'Features' },
    { href: '/#how-it-works', label: 'How It Works' },
    { href: '/#for-clinicians', label: 'For Clinicians' },
    { href: '/#testimonials', label: 'Testimonials' },
  ]

  return (
    <motion.nav
      initial={{ y: -100 }}
      animate={{ y: 0 }}
      className={`fixed top-0 left-0 right-0 z-50 transition-all duration-300 ${
        isScrolled ? 'glass-dark py-3 sm:py-4' : 'py-4 sm:py-6'
      }`}
    >
      <div className="max-w-7xl mx-auto px-4 sm:px-6 flex items-center justify-between">
        {/* Logo */}
        <Link href="/" className="flex items-center gap-3 group">
          <div className="relative">
            <div className="w-10 h-10 rounded-xl overflow-hidden group-hover:scale-110 transition-transform">
              <img 
                src="/WalkingWR-Logo.png" 
                alt="WaitWell Logo" 
                className="w-full h-full object-contain"
              />
            </div>
            <div className="absolute inset-0 rounded-xl bg-teal-accent/20 blur-xl group-hover:blur-2xl transition-all -z-10" />
          </div>
          <span className="text-lg sm:text-xl font-bold dark:text-white text-slate-800">
            Wait<span className="text-teal-accent dark:text-teal-accent text-teal-600">Well</span>
          </span>
        </Link>

        {/* Desktop Navigation */}
        <div className="hidden md:flex items-center gap-8">
          {navLinks.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              className="text-white/70 dark:text-white/70 text-slate-600 hover:text-white dark:hover:text-white hover:text-slate-900 transition-colors relative group"
            >
              {link.label}
              <span className="absolute -bottom-1 left-0 w-0 h-0.5 bg-teal-accent group-hover:w-full transition-all duration-300" />
            </Link>
          ))}
        </div>

        {/* CTA Button & Theme Toggle */}
        <div className="hidden md:flex items-center gap-4">
          {/* Theme Toggle */}
          <button
            onClick={toggleTheme}
            className="p-2.5 rounded-full glass text-white/70 dark:text-white/70 text-slate-600 hover:text-white dark:hover:text-white hover:text-slate-900 hover:bg-white/10 dark:hover:bg-white/10 transition-all"
            aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
          >
            {theme === 'dark' ? (
              <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" />
              </svg>
            ) : (
              <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />
              </svg>
            )}
          </button>
          
          <Link
            href="/#download"
            className="px-6 py-2.5 rounded-full bg-gradient-to-r from-teal-accent to-teal-accent/80 text-midnight font-semibold hover:shadow-lg hover:shadow-teal-accent/30 transition-all hover:scale-105"
          >
            Download App
          </Link>
        </div>

        {/* Mobile Menu Button */}
        <button
          onClick={() => setIsMobileMenuOpen(!isMobileMenuOpen)}
          className="md:hidden p-2 text-slate-900 dark:text-white"
          aria-label="Toggle menu"
        >
          <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            {isMobileMenuOpen ? (
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            ) : (
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M4 12h16M4 18h16" />
            )}
          </svg>
        </button>
      </div>

      {/* Mobile Menu Overlay */}
      <AnimatePresence>
        {isMobileMenuOpen && (
          <>
            {/* Backdrop */}
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              onClick={() => setIsMobileMenuOpen(false)}
              className="fixed inset-0 bg-black/70 backdrop-blur-md z-40 md:hidden"
            />
            
            {/* Menu Panel */}
          <motion.div
              initial={{ opacity: 0, y: -20 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -20 }}
              transition={{ duration: 0.2 }}
              className="fixed top-0 left-0 right-0 bg-midnight/95 dark:bg-midnight/95 bg-white/95 backdrop-blur-xl z-50 md:hidden shadow-2xl border-b border-white/10 dark:border-white/10 border-slate-200"
            >
              <div className="max-w-7xl mx-auto px-4 sm:px-6 py-4">
                {/* Header with close button */}
                <div className="flex items-center justify-between mb-6">
                  <Link href="/" className="flex items-center gap-3" onClick={() => setIsMobileMenuOpen(false)}>
                    <div className="w-10 h-10 rounded-xl overflow-hidden">
                      <img 
                        src="/WalkingWR-Logo.png" 
                        alt="WaitWell Logo" 
                        className="w-full h-full object-contain"
                      />
                    </div>
                    <span className="text-lg font-bold text-slate-900 dark:text-white">
                      Wait<span className="text-teal-600 dark:text-teal-accent">Well</span>
                    </span>
                  </Link>
                  <button
                    onClick={() => setIsMobileMenuOpen(false)}
                    className="p-2 text-slate-900 dark:text-white hover:bg-slate-100 dark:hover:bg-white/10 rounded-lg transition-colors"
                    aria-label="Close menu"
                  >
                    <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>

                {/* Navigation Links */}
                <div className="flex flex-col gap-1 mb-6">
              {navLinks.map((link) => (
                <Link
                  key={link.href}
                  href={link.href}
                  onClick={() => setIsMobileMenuOpen(false)}
                      className="text-slate-900 dark:text-white hover:text-teal-700 dark:hover:text-teal-accent transition-colors py-3 px-4 rounded-lg hover:bg-slate-100 dark:hover:bg-white/10 text-base font-semibold"
                >
                  {link.label}
                </Link>
              ))}
                </div>

                {/* Actions */}
                <div className="pt-4 border-t border-white/20 dark:border-white/20 border-slate-300 space-y-3">
                <button
                    onClick={() => {
                      toggleTheme()
                      setIsMobileMenuOpen(false)
                    }}
                    className="w-full flex items-center justify-center gap-2 px-6 py-3 rounded-full bg-slate-100 dark:bg-white/10 text-slate-900 dark:text-white font-semibold hover:bg-slate-200 dark:hover:bg-white/20 transition-colors"
                  aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
                >
                  {theme === 'dark' ? (
                    <>
                      <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" />
                      </svg>
                      Light Mode
                    </>
                  ) : (
                    <>
                      <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />
                      </svg>
                      Dark Mode
                    </>
                  )}
                </button>
                <Link
                    href="/#download"
                    onClick={() => setIsMobileMenuOpen(false)}
                    className="block w-full text-center px-6 py-3 rounded-full bg-gradient-to-r from-teal-accent to-teal-accent/80 text-white dark:text-white dark:text-midnight font-semibold hover:shadow-lg hover:shadow-teal-accent/30 transition-all"
                >
                  Download App
                </Link>
              </div>
            </div>
          </motion.div>
          </>
        )}
      </AnimatePresence>
    </motion.nav>
  )
}
