'use client'

import { useState } from 'react'
import { motion } from 'framer-motion'
import PhoneMockup from './PhoneMockup'
import VideoModal from './VideoModal'

const PROMO_VIDEO_ID = 'sALctWCQQic' // YouTube Shorts promo

export default function Hero() {
  const [isVideoOpen, setIsVideoOpen] = useState(false)

  return (
    <section className="relative min-h-screen overflow-hidden animated-gradient">
      {/* Background Effects */}
      <div className="absolute inset-0">
        {/* Gradient orbs */}
        <div className="absolute top-1/4 left-1/4 w-96 h-96 bg-teal-accent/20 dark:bg-teal-accent/20 bg-teal-100 rounded-full blur-3xl" />
        <div className="absolute bottom-1/4 right-1/4 w-96 h-96 bg-coral-pink/10 dark:bg-coral-pink/10 bg-pink-100 rounded-full blur-3xl" />
        
        {/* Grid pattern */}
        <div className="absolute inset-0 bg-[linear-gradient(rgba(78,205,196,0.03)_1px,transparent_1px),linear-gradient(90deg,rgba(78,205,196,0.03)_1px,transparent_1px)] dark:bg-[linear-gradient(rgba(78,205,196,0.03)_1px,transparent_1px),linear-gradient(90deg,rgba(78,205,196,0.03)_1px,transparent_1px)] bg-[linear-gradient(rgba(15,23,42,0.05)_1px,transparent_1px),linear-gradient(90deg,rgba(15,23,42,0.05)_1px,transparent_1px)] bg-[size:64px_64px]" />
      </div>

      <div className="relative max-w-7xl mx-auto px-4 sm:px-6 pt-20 sm:pt-24 md:pt-32 pb-12 sm:pb-16 md:pb-20">
        <div className="grid lg:grid-cols-2 gap-8 sm:gap-12 items-center min-h-[60vh] sm:min-h-[70vh] lg:min-h-[80vh]">
          {/* Left Content */}
          <motion.div
            initial={{ opacity: 0, x: -50 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ duration: 0.8 }}
            className="text-center lg:text-left"
          >
            {/* Main Headline */}
            <h1 className="text-3xl sm:text-4xl md:text-5xl lg:text-6xl xl:text-7xl font-bold leading-tight mb-4 sm:mb-6">
              <span className="gradient-text-hero">Transform</span>
              <br />
              <span className="dark:text-white text-slate-900">Your Wait Into</span>
              <br />
              <span className="text-teal-accent dark:text-teal-accent text-teal-700 dark:glow-text">Wellness</span>
            </h1>

            <p className="text-base sm:text-lg md:text-xl dark:text-white/60 text-slate-900 max-w-lg mx-auto lg:mx-0 mb-6 sm:mb-8 md:mb-10 leading-relaxed px-2 sm:px-0">
              Walk while you wait. Get real-time clinic updates, explore nature trails, 
              and arrive back just in time for your appointment.
            </p>

            {/* CTA Buttons */}
            <div className="flex flex-col sm:flex-row gap-3 sm:gap-4 justify-center lg:justify-start mb-6 sm:mb-0">
              <motion.a
                href="#download"
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                className="group relative px-6 sm:px-8 py-3 sm:py-4 rounded-full bg-gradient-to-r from-teal-accent to-teal-accent/80 dark:from-teal-accent dark:to-teal-accent/80 from-teal-500 to-teal-600 text-white dark:text-midnight font-semibold text-base sm:text-lg overflow-hidden"
              >
                <span className="relative z-10 flex items-center justify-center gap-2">
                  <svg className="w-5 h-5 sm:w-6 sm:h-6" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.81-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/>
                  </svg>
                  Download for iOS
                </span>
                <div className="absolute inset-0 bg-white/20 translate-y-full group-hover:translate-y-0 transition-transform duration-300" />
              </motion.a>
              
              <motion.button
                onClick={() => setIsVideoOpen(true)}
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                className="px-6 sm:px-8 py-3 sm:py-4 rounded-full glass dark:text-white text-slate-700 font-semibold text-base sm:text-lg hover:bg-white/10 dark:hover:bg-white/10 hover:bg-slate-100 transition-colors flex items-center justify-center gap-2 group"
              >
                <svg className="w-5 h-5 sm:w-6 sm:h-6 group-hover:scale-110 transition-transform" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                Watch Promo
              </motion.button>
            </div>

            {/* Stats */}
            <motion.div
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: 0.6 }}
              className="flex flex-wrap gap-4 sm:gap-6 md:gap-8 mt-8 sm:mt-10 md:mt-12 justify-center lg:justify-start"
            >
              <div className="text-center lg:text-left">
                <div className="text-2xl sm:text-3xl font-bold text-teal-accent dark:text-teal-accent text-teal-700 stat-number">5,000+</div>
                <div className="dark:text-white/50 text-slate-800 text-xs sm:text-sm">Active Users</div>
              </div>
              <div className="hidden sm:block w-px bg-white/10 dark:bg-white/10 bg-slate-200" />
              <div className="text-center lg:text-left">
                <div className="text-2xl sm:text-3xl font-bold text-teal-accent dark:text-teal-accent text-teal-700 stat-number">50,000+</div>
                <div className="dark:text-white/50 text-slate-800 text-xs sm:text-sm">Walks Completed</div>
              </div>
              <div className="hidden sm:block w-px bg-white/10 dark:bg-white/10 bg-slate-200" />
              <div className="text-center lg:text-left">
                <div className="text-2xl sm:text-3xl font-bold text-teal-accent dark:text-teal-accent text-teal-700 stat-number">4.9★</div>
                <div className="dark:text-white/50 text-slate-800 text-xs sm:text-sm">App Rating</div>
              </div>
            </motion.div>
          </motion.div>

          {/* Right - Phone Mockup */}
          <motion.div
            initial={{ opacity: 0, x: 50, y: 20 }}
            animate={{ opacity: 1, x: 0, y: 0 }}
            transition={{ duration: 0.8, delay: 0.3 }}
            className="relative flex justify-center lg:justify-end mt-8 lg:mt-0"
          >
            <PhoneMockup />
          </motion.div>
        </div>
      </div>

      {/* Scroll indicator */}
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 1.5 }}
        className="absolute bottom-8 left-1/2 -translate-x-1/2"
      >
        <div className="flex flex-col items-center gap-2 dark:text-white/40 text-slate-600">
          <span className="text-sm">Scroll to explore</span>
          <motion.div
            animate={{ y: [0, 8, 0] }}
            transition={{ repeat: Infinity, duration: 1.5 }}
          >
            <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 14l-7 7m0 0l-7-7m7 7V3" />
            </svg>
          </motion.div>
        </div>
      </motion.div>

      {/* Video Modal - in-website promo */}
      <VideoModal
        isOpen={isVideoOpen}
        onClose={() => setIsVideoOpen(false)}
        videoId={PROMO_VIDEO_ID}
      />
    </section>
  )
}
