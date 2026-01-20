'use client'

import { motion } from 'framer-motion'
import { useState, useEffect } from 'react'

export default function PhoneMockup() {
  const [activeScreen, setActiveScreen] = useState(0)
  
  const screens = [
    { name: 'map', label: 'Walking Route' },
    { name: 'wait', label: 'Wait Time' },
    { name: 'breathing', label: 'Breathing' },
  ]

  useEffect(() => {
    const interval = setInterval(() => {
      setActiveScreen((prev) => (prev + 1) % screens.length)
    }, 4000)
    return () => clearInterval(interval)
  }, [])

  return (
    <div className="relative">
      {/* Glow effect behind phone */}
      <div className="absolute inset-0 scale-150">
        <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-64 h-64 bg-teal-accent/30 dark:bg-teal-accent/30 bg-teal-100 rounded-full blur-3xl" />
        <div className="absolute top-1/3 left-1/3 w-48 h-48 bg-coral-pink/20 dark:bg-coral-pink/20 bg-pink-100 rounded-full blur-3xl" />
      </div>

      {/* Phone Frame */}
      <motion.div 
        className="phone-mockup w-[280px] md:w-[320px] float-animation relative z-10"
        whileHover={{ scale: 1.02 }}
      >
        {/* Dynamic Island / Notch */}
        <div className="absolute top-6 left-1/2 -translate-x-1/2 w-24 h-6 bg-black dark:bg-black bg-slate-800 rounded-full z-20" />
        
        {/* Screen Content */}
        <div className="phone-screen aspect-[9/19.5] relative overflow-hidden bg-black dark:bg-black bg-white rounded-[2.5rem] border-4 border-slate-800 dark:border-slate-900">
          {/* Map Screen */}
          <motion.div
            initial={false}
            animate={{ 
              opacity: activeScreen === 0 ? 1 : 0,
              scale: activeScreen === 0 ? 1 : 0.9
            }}
            transition={{ duration: 0.5 }}
            className="absolute inset-0"
          >
            {/* Map Background */}
            <div className="absolute inset-0 bg-gradient-to-b from-deep-navy to-midnight dark:from-deep-navy dark:to-midnight bg-gradient-to-b from-blue-50 via-white to-slate-50 overflow-hidden">
              {/* Sheffield Map Background - Using static map image */}
              <div className="absolute inset-0 z-0">
                <img 
                  src="https://staticmap.openstreetmap.de/staticmap.php?center=53.3800,-1.4700&zoom=13&size=400x800&maptype=mapnik"
                  alt="Sheffield Map"
                  className="w-full h-full object-cover"
                  style={{ 
                    opacity: 1,
                    filter: 'brightness(1.3) contrast(1.3) saturate(1.2)',
                  }}
                  loading="eager"
                />
              </div>
              
              {/* Overlay for dark mode - minimal so map shows through */}
              <div className="absolute inset-0 bg-deep-navy/0 dark:bg-deep-navy/5 bg-transparent z-0" />
              
              {/* Simulated map with route */}
              <svg className="absolute inset-0 w-full h-full z-10" viewBox="0 0 100 200">
                {/* Walking route - darker and thicker in light mode for visibility - stops well before top card */}
                <motion.path
                  d="M 20 180 C 20 150, 50 140, 50 100 S 80 60, 50 40 S 30 50, 50 45"
                  fill="none"
                  className="stroke-teal-accent dark:stroke-teal-accent stroke-teal-700"
                  strokeWidth="5"
                  strokeLinecap="round"
                  initial={{ pathLength: 0 }}
                  animate={{ pathLength: activeScreen === 0 ? 1 : 0 }}
                  transition={{ duration: 2, ease: "easeInOut" }}
                />
                
                {/* POI markers - larger and more vibrant in light mode */}
                <circle cx="50" cy="100" r="7" className="fill-coral-pink dark:fill-coral-pink fill-red-600 animate-pulse" />
                <circle cx="50" cy="40" r="7" className="fill-soft-amber dark:fill-soft-amber fill-orange-600 animate-pulse" />
                <circle cx="20" cy="180" r="8" className="fill-teal-accent dark:fill-teal-accent fill-teal-700" />
              </svg>
              
              {/* Direction card */}
              <div className="absolute bottom-6 left-4 right-4">
                <div className="bg-white/10 dark:bg-white/10 bg-white shadow-2xl dark:backdrop-blur-xl rounded-2xl p-4 border-2 border-white/20 dark:border-white/20 border-slate-300">
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded-full bg-teal-accent/20 dark:bg-teal-accent/20 bg-teal-200 flex items-center justify-center">
                      <svg className="w-5 h-5 text-teal-accent dark:text-teal-accent text-teal-700" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M9 5l7 7-7 7" />
                      </svg>
                    </div>
                    <div>
                      <div className="text-sm font-bold text-white dark:text-white text-slate-950">Turn right</div>
                      <div className="text-xs font-bold text-white/70 dark:text-white/70 text-slate-950">onto Park Lane • 50m</div>
                    </div>
                  </div>
                </div>
              </div>
              
              {/* Time remaining */}
              <div className="absolute top-16 left-4 right-4">
                <div className="bg-white/10 dark:bg-white/10 bg-white shadow-2xl dark:backdrop-blur-xl rounded-xl p-3 flex items-center justify-between border-2 border-white/20 dark:border-white/20 border-slate-300">
                  <div className="flex items-center gap-2">
                    <svg className="w-5 h-5 text-teal-accent dark:text-teal-accent text-teal-700" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                    <span className="text-sm font-bold text-white dark:text-white text-slate-950">12 min left</span>
                  </div>
                  <div className="text-sm font-bold text-teal-accent dark:text-teal-accent text-teal-950">0.8 km</div>
                </div>
              </div>
            </div>
          </motion.div>

          {/* Wait Time Screen */}
          <motion.div
            initial={false}
            animate={{ 
              opacity: activeScreen === 1 ? 1 : 0,
              scale: activeScreen === 1 ? 1 : 0.9
            }}
            transition={{ duration: 0.5 }}
            className="absolute inset-0 bg-gradient-to-b from-deep-navy to-midnight dark:from-deep-navy dark:to-midnight bg-gradient-to-b from-blue-50 via-white to-slate-50 p-6 flex flex-col justify-center"
          >
            <div className="text-center">
              <div className="text-white/60 dark:text-white/60 text-slate-950 text-sm mb-2 font-bold">Current Wait Time</div>
              <div className="text-6xl font-bold text-teal-accent dark:text-teal-accent text-teal-800 mb-2">15</div>
              <div className="text-white/60 dark:text-white/60 text-slate-950 text-lg font-bold">minutes</div>
              
              {/* Clinician Card */}
              <div className="mt-8 bg-white/10 dark:bg-white/10 bg-white shadow-2xl dark:backdrop-blur-xl rounded-2xl p-4 border-2 border-white/20 dark:border-white/20 border-slate-300">
                <div className="flex items-center gap-3">
                  <div className="w-12 h-12 rounded-full bg-gradient-to-br from-nhs-blue to-nhs-dark-blue dark:from-nhs-blue dark:to-nhs-dark-blue from-blue-600 to-blue-700 flex items-center justify-center">
                    <span className="text-white font-bold">DW</span>
                  </div>
                  <div className="text-left">
                    <div className="font-bold text-white dark:text-white text-slate-950">Dr. Emma Wilson</div>
                    <div className="text-sm font-bold text-white/70 dark:text-white/70 text-slate-950">Psychiatry</div>
                  </div>
                </div>
              </div>
              
              {/* Route suggestion */}
              <div className="mt-4 p-3 rounded-xl bg-teal-accent/10 dark:bg-teal-accent/10 bg-teal-100 border-2 border-teal-accent/20 dark:border-teal-accent/20 border-teal-400">
                <div className="text-sm text-teal-accent dark:text-teal-accent text-teal-950 font-bold">Perfect time for a 10-min walk! 🚶</div>
              </div>
            </div>
          </motion.div>

          {/* Breathing Screen */}
          <motion.div
            initial={false}
            animate={{ 
              opacity: activeScreen === 2 ? 1 : 0,
              scale: activeScreen === 2 ? 1 : 0.9
            }}
            transition={{ duration: 0.5 }}
            className="absolute inset-0 bg-gradient-to-b from-deep-navy to-midnight dark:from-deep-navy dark:to-midnight bg-gradient-to-b from-blue-50 via-white to-slate-50 flex flex-col items-center justify-center"
          >
            <div className="text-white/60 dark:text-white/60 text-slate-950 text-sm mb-8 font-bold">Breathing Exercise</div>
            
            {/* Breathing circle */}
            <div className="relative">
              <motion.div
                animate={{ scale: [1, 1.3, 1] }}
                transition={{ duration: 4, repeat: Infinity, ease: "easeInOut" }}
                className="w-32 h-32 rounded-full bg-gradient-to-br from-teal-accent/30 to-teal-accent/10 dark:from-teal-accent/30 dark:to-teal-accent/10 from-teal-500 to-teal-400 flex items-center justify-center"
              >
                <motion.div
                  animate={{ scale: [1, 1.2, 1] }}
                  transition={{ duration: 4, repeat: Infinity, ease: "easeInOut" }}
                  className="w-20 h-20 rounded-full bg-teal-accent/40 dark:bg-teal-accent/40 bg-teal-600 flex items-center justify-center"
                >
                  <div className="w-10 h-10 rounded-full bg-teal-accent dark:bg-teal-accent bg-teal-800" />
                </motion.div>
              </motion.div>
              
              {/* Pulse rings */}
              <div className="absolute inset-0 flex items-center justify-center">
                <div className="pulse-ring w-40 h-40 border-teal-accent/20 dark:border-teal-accent/20 border-teal-500" style={{ animationDelay: '0s' }} />
                <div className="pulse-ring w-40 h-40 border-teal-accent/20 dark:border-teal-accent/20 border-teal-500" style={{ animationDelay: '1s' }} />
              </div>
            </div>
            
            <motion.div
              animate={{ opacity: [0.5, 1, 0.5] }}
              transition={{ duration: 4, repeat: Infinity }}
              className="mt-8 text-2xl font-bold text-white dark:text-white text-slate-950"
            >
              Breathe In...
            </motion.div>
            
            <div className="mt-4 text-white/50 dark:text-white/50 text-slate-950 text-sm font-bold">4 - 7 - 8 Pattern</div>
          </motion.div>
        </div>
      </motion.div>

      {/* Screen selector dots */}
      <div className="flex justify-center gap-2 mt-6">
        {screens.map((screen, i) => (
          <button
            key={screen.name}
            onClick={() => setActiveScreen(i)}
            className={`w-2 h-2 rounded-full transition-all ${
              activeScreen === i 
                ? 'bg-teal-accent dark:bg-teal-accent bg-teal-600 w-6' 
                : 'bg-white/20 dark:bg-white/20 bg-slate-300 hover:bg-white/40 dark:hover:bg-white/40 hover:bg-slate-400'
            }`}
            aria-label={`View ${screen.label} screen`}
          />
        ))}
      </div>
    </div>
  )
}
