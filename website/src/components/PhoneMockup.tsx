'use client'

import { motion } from 'framer-motion'
import { useState, useEffect } from 'react'

export default function PhoneMockup() {
  const [activeScreen, setActiveScreen] = useState(0)
  const [routePhase, setRoutePhase] = useState<'outbound' | 'return'>('outbound')
  const [timeRemaining, setTimeRemaining] = useState(12) // Start with 12 minutes
  const [distance, setDistance] = useState(0) // Start with 0 km
  const [routeStartTime, setRouteStartTime] = useState<number | null>(null)
  
  const screens = [
    { name: 'map', label: 'Walking Route' },
    { name: 'wait', label: 'Wait Time' },
    { name: 'breathing', label: 'Breathing' },
  ]

  // Extended time for map screen to show both outbound and return routes
  useEffect(() => {
    const interval = setInterval(() => {
      setActiveScreen((prev) => (prev + 1) % screens.length)
      setRoutePhase('outbound') // Reset route phase when switching screens
      setTimeRemaining(12) // Reset time when switching screens
      setDistance(0) // Reset distance when switching screens
      setRouteStartTime(null)
    }, 8000) // Increased from 4000 to 8000 to allow time for both routes
    return () => clearInterval(interval)
  }, [])

  // Handle route phase transitions for map screen
  useEffect(() => {
    if (activeScreen === 0) {
      setRoutePhase('outbound')
      setTimeRemaining(12)
      setDistance(0)
      setRouteStartTime(Date.now())
      // After outbound route completes (2s), wait a bit, then start return route
      const returnTimer = setTimeout(() => {
        setRoutePhase('return')
        setTimeRemaining(4) // Set to 4 min when return route starts
        setDistance(0.4) // Set to 0.4km when return route starts (halfway point)
        setRouteStartTime(Date.now() - 2000) // Adjust start time to account for outbound phase
      }, 2500) // Start return route 0.5s after outbound completes
      return () => clearTimeout(returnTimer)
    }
  }, [activeScreen])

  // Update time remaining and distance dynamically based on route progress
  useEffect(() => {
    if (activeScreen !== 0 || routeStartTime === null) return

    const updateInterval = setInterval(() => {
      const elapsed = (Date.now() - routeStartTime) / 1000 // elapsed time in seconds
      
      if (routePhase === 'outbound') {
        // Outbound: 12 min → 4 min over 2 seconds
        const progress = Math.min(elapsed / 2, 1) // 0 to 1 over 2 seconds
        const newTime = 12 - (progress * 8) // 12 → 4
        setTimeRemaining(Math.max(Math.round(newTime), 4))
        
        // Distance: 0 km → 0.4 km over 2 seconds
        const newDistance = progress * 0.4 // 0 → 0.4
        setDistance(Math.min(newDistance, 0.4))
      } else if (routePhase === 'return') {
        // Return: 4 min → 0 min over 2 seconds
        const returnElapsed = elapsed - 2.5 // Start counting from when return begins
        const progress = Math.min(Math.max(returnElapsed / 2, 0), 1) // 0 to 1 over 2 seconds
        const newTime = 4 - (progress * 4) // 4 → 0
        setTimeRemaining(Math.max(Math.round(newTime), 0))
        
        // Distance: 0.4 km → 0.8 km over 2 seconds
        const newDistance = 0.4 + (progress * 0.4) // 0.4 → 0.8
        setDistance(Math.min(newDistance, 0.8))
      }
    }, 100) // Update every 100ms for smooth countdown

    return () => clearInterval(updateInterval)
  }, [activeScreen, routePhase, routeStartTime])

  return (
    <div className="relative">
      {/* Glow effect behind phone */}
      <div className="absolute inset-0 scale-150">
        <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-64 h-64 bg-teal-100 dark:bg-teal-accent/30 rounded-full blur-3xl" />
        <div className="absolute top-1/3 left-1/3 w-48 h-48 bg-pink-100 dark:bg-coral-pink/20 rounded-full blur-3xl" />
      </div>

      {/* Phone Frame */}
      <motion.div 
        className="phone-mockup w-[280px] md:w-[320px] float-animation relative z-10"
        whileHover={{ scale: 1.02 }}
      >
        {/* Dynamic Island / Notch */}
        <div className="absolute top-4 left-1/2 -translate-x-1/2 w-28 h-7 bg-slate-800 dark:bg-black rounded-full z-20" />
        
        {/* Screen Content */}
        <div className="phone-screen aspect-[9/19.5] relative overflow-hidden bg-white dark:bg-black rounded-[2.5rem] border-4 border-slate-800 dark:border-slate-900">
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
            <div className="absolute inset-0 bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight overflow-hidden">
              {/* Map Background - Using static map image */}
              <div className="absolute inset-0 z-0 overflow-hidden">
                <img 
                  src="https://staticmap.openstreetmap.de/staticmap.php?center=53.3800,-1.4700&zoom=13&size=400x800&maptype=mapnik"
                  alt="Map"
                  className="w-full h-full object-cover"
                  style={{ 
                    opacity: 1,
                    filter: 'brightness(1.3) contrast(1.3) saturate(1.2)',
                    objectPosition: 'center top',
                  }}
                  loading="eager"
                />
                {/* Solid overlay to completely hide map attribution text at top left */}
                <div className="absolute top-0 left-0 w-24 h-14 bg-blue-50 dark:bg-deep-navy z-20" />
                {/* Gradient overlay below for smooth transition */}
                <div className="absolute top-14 left-0 right-0 h-10 bg-gradient-to-b from-blue-50 to-transparent dark:from-deep-navy dark:to-transparent z-10" />
              </div>
              
              {/* Overlay for dark mode - minimal so map shows through */}
              <div className="absolute inset-0 bg-transparent dark:bg-deep-navy/5 z-0" />
              
              {/* Simulated map with route */}
              <svg className="absolute inset-0 w-full h-full z-10" viewBox="0 0 100 200">
                {/* Outbound route - Start/End to Dentist - disappears when return route begins */}
                <motion.path
                  d="M 20 160 C 20 150, 50 140, 50 100 S 80 60, 50 40"
                  fill="none"
                  className="stroke-teal-600 dark:stroke-teal-accent"
                  strokeWidth="6"
                  strokeLinecap="round"
                  initial={{ pathLength: 0, opacity: 1 }}
                  animate={{ 
                    pathLength: (activeScreen === 0 && routePhase === 'outbound') ? 1 : 0,
                    opacity: (activeScreen === 0 && routePhase === 'outbound') ? 1 : 0
                  }}
                  transition={{ 
                    pathLength: { duration: 2, ease: "easeInOut", repeat: 0 },
                    opacity: { duration: 0.3, delay: routePhase === 'return' ? 0 : 0 }
                  }}
                />
                
                {/* Return route - Dentist directly to End (bypassing Pharmacy) */}
                <motion.path
                  d="M 50 40 C 40 60, 25 100, 20 160"
                  fill="none"
                  className="stroke-blue-600 dark:stroke-blue-400"
                  strokeWidth="6"
                  strokeLinecap="round"
                  strokeDasharray="5,3"
                  initial={{ pathLength: 0 }}
                  animate={{ 
                    pathLength: (activeScreen === 0 && routePhase === 'return') ? 1 : 0
                  }}
                  transition={{ duration: 2, ease: "easeInOut", repeat: 0, delay: routePhase === 'return' ? 0 : 0 }}
                />
                
                {/* POI markers - larger and more vibrant in light mode */}
                {/* White background circle to cover any map markers underneath */}
                <circle cx="50" cy="100" r="10" className="fill-white dark:fill-deep-navy" />
                <circle cx="50" cy="100" r="8" className="fill-red-600 dark:fill-coral-pink animate-pulse" />
                {/* White background circle to cover any map markers underneath */}
                <circle cx="50" cy="40" r="10" className="fill-white dark:fill-deep-navy" />
                <circle cx="50" cy="40" r="8" className="fill-orange-600 dark:fill-soft-amber animate-pulse" />
                {/* White background circle to cover any map markers underneath */}
                <circle cx="20" cy="160" r="11" className="fill-white dark:fill-deep-navy" />
                <circle cx="20" cy="160" r="9" className="fill-teal-600 dark:fill-teal-accent" />
                
                {/* Waypoint labels - appear as route reaches each point, positioned to the side */}
                {/* Start label - to the right of start point (outbound phase) */}
                <motion.text
                  x="30"
                  y="160"
                  className="fill-slate-900 dark:fill-white text-[7px] font-bold drop-shadow-[0_1px_2px_rgba(0,0,0,0.3)] dark:drop-shadow-none"
                  textAnchor="start"
                  initial={{ opacity: 0 }}
                  animate={{ 
                    opacity: (activeScreen === 0 && routePhase === 'outbound') ? 1 : 0 
                  }}
                  transition={{ 
                    duration: 0.3, 
                    delay: (activeScreen === 0 && routePhase === 'outbound') ? 0 : 0,
                    ease: "easeOut"
                  }}
                >
                  Start
                </motion.text>
                
                {/* Pharmacy label - to the right of middle waypoint (outbound only) */}
                <motion.text
                  x="60"
                  y="100"
                  className="fill-slate-900 dark:fill-white text-[7px] font-bold drop-shadow-[0_1px_2px_rgba(0,0,0,0.3)] dark:drop-shadow-none"
                  textAnchor="start"
                  initial={{ opacity: 0 }}
                  animate={{ 
                    opacity: (activeScreen === 0 && routePhase === 'outbound') ? 1 : 0 
                  }}
                  transition={{ 
                    duration: 0.3, 
                    delay: (activeScreen === 0 && routePhase === 'outbound') ? 1 : 0,
                    ease: "easeOut"
                  }}
                >
                  Pharmacy
                </motion.text>
                
                {/* Dentist label - to the right of end waypoint (outbound only) */}
                <motion.text
                  x="60"
                  y="40"
                  className="fill-slate-900 dark:fill-white text-[7px] font-bold drop-shadow-[0_1px_2px_rgba(0,0,0,0.3)] dark:drop-shadow-none"
                  textAnchor="start"
                  initial={{ opacity: 0 }}
                  animate={{ 
                    opacity: (activeScreen === 0 && routePhase === 'outbound') ? 1 : 0 
                  }}
                  transition={{ 
                    duration: 0.3, 
                    delay: (activeScreen === 0 && routePhase === 'outbound') ? 2 : 0,
                    ease: "easeOut"
                  }}
                >
                  Dentist
                </motion.text>
                
                {/* End label - appears when return route approaches destination */}
                <motion.text
                  x="30"
                  y="160"
                  className="fill-slate-900 dark:fill-white text-[7px] font-bold drop-shadow-[0_1px_2px_rgba(0,0,0,0.3)] dark:drop-shadow-none"
                  textAnchor="start"
                  initial={{ opacity: 0 }}
                  animate={{ 
                    opacity: (activeScreen === 0 && routePhase === 'return') ? 1 : 0 
                  }}
                  transition={{ 
                    duration: 0.3, 
                    delay: (activeScreen === 0 && routePhase === 'return') ? 1.5 : 0,
                    ease: "easeOut"
                  }}
                >
                  End
                </motion.text>
              </svg>
              
              {/* Direction card - higher z-index to ensure it's above route line */}
              <div className="absolute bottom-6 left-4 right-4 z-20">
                <div className="bg-white/95 dark:bg-white/10 backdrop-blur-sm dark:backdrop-blur-xl rounded-2xl p-4 border-2 border-slate-400 dark:border-white/20 shadow-2xl">
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded-full bg-teal-200 dark:bg-teal-accent/20 flex items-center justify-center">
                      <svg className="w-5 h-5 text-teal-700 dark:text-teal-accent" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M9 5l7 7-7 7" />
                      </svg>
                    </div>
                    <div>
                      <div className="text-sm font-bold text-slate-900 dark:text-white">Turn right</div>
                      <div className="text-xs font-bold text-slate-700 dark:text-white/70">onto Park Lane • 50m</div>
                    </div>
                  </div>
                </div>
              </div>
              
              {/* Time remaining */}
              <div className="absolute top-16 left-4 right-4">
                <div className="bg-white/95 dark:bg-white/10 backdrop-blur-sm dark:backdrop-blur-xl rounded-xl p-3 flex items-center justify-between border-2 border-slate-400 dark:border-white/20 shadow-2xl">
                  <div className="flex items-center gap-2">
                    <svg className="w-5 h-5 text-teal-700 dark:text-teal-accent" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                    <span className="text-sm font-bold text-slate-900 dark:text-white">
                      {timeRemaining} min left
                    </span>
                  </div>
                  <div className="text-sm font-bold text-teal-700 dark:text-teal-accent">
                    {distance.toFixed(1)} km
                  </div>
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
            className="absolute inset-0 bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight p-5 flex flex-col justify-center"
          >
            <div className="text-center">
              <div className="text-slate-600 dark:text-white/60 text-base mb-2 font-bold tracking-wide">Current Wait Time</div>
              <div className="text-7xl font-bold text-teal-600 dark:text-teal-accent mb-1">15</div>
              <div className="text-slate-600 dark:text-white/60 text-xl font-bold">minutes</div>
              
              {/* Clinician Card - larger */}
              <div className="mt-6 bg-white dark:bg-white/10 backdrop-blur-sm dark:backdrop-blur-xl shadow-xl rounded-2xl p-5 border-2 border-slate-200 dark:border-white/20">
                <div className="flex items-center gap-4">
                  <div className="w-14 h-14 rounded-full bg-gradient-to-br from-blue-500 to-blue-700 dark:from-nhs-blue dark:to-nhs-dark-blue flex items-center justify-center flex-shrink-0">
                    <span className="text-white font-bold text-lg">EW</span>
                  </div>
                  <div className="text-left">
                    <div className="font-bold text-lg text-slate-900 dark:text-white">Dr. Emma Wilson</div>
                    <div className="text-base font-semibold text-slate-500 dark:text-white/70">Psychiatry</div>
                  </div>
                </div>
              </div>
              
              {/* Route suggestion - larger */}
              <div className="mt-4 p-4 rounded-2xl bg-teal-50 dark:bg-teal-accent/10 border-2 border-teal-300 dark:border-teal-accent/20">
                <div className="text-base text-teal-700 dark:text-teal-accent font-bold">Perfect time for a 10-min walk! 🚶</div>
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
            className="absolute inset-0 bg-gradient-to-b from-blue-50 via-white to-slate-50 dark:from-deep-navy dark:to-midnight flex flex-col items-center justify-center"
          >
            <div className="text-slate-600 dark:text-white/60 text-base font-bold tracking-wide absolute top-12">Breathing Exercise</div>
            
            {/* Breathing circle - larger */}
            <div className="relative w-36 h-36 flex items-center justify-center">
              {/* Pulse rings - centered on the breathing circle */}
              <div className="absolute inset-0 flex items-center justify-center">
                <div className="pulse-ring w-48 h-48 border-teal-400 dark:border-teal-accent/20 rounded-full" style={{ animationDelay: '0s' }} />
                <div className="pulse-ring w-48 h-48 border-teal-400 dark:border-teal-accent/20 rounded-full" style={{ animationDelay: '1s' }} />
              </div>
              
              <motion.div
                animate={{ scale: [1, 1.3, 1] }}
                transition={{ duration: 4, repeat: Infinity, ease: "easeInOut" }}
                className="w-36 h-36 rounded-full bg-gradient-to-br from-teal-400 to-teal-300 dark:from-teal-accent/30 dark:to-teal-accent/10 flex items-center justify-center shadow-lg relative z-10"
              >
                <motion.div
                  animate={{ scale: [1, 1.2, 1] }}
                  transition={{ duration: 4, repeat: Infinity, ease: "easeInOut" }}
                  className="w-24 h-24 rounded-full bg-teal-500 dark:bg-teal-accent/40 flex items-center justify-center"
                >
                  <div className="w-14 h-14 rounded-full bg-teal-600 dark:bg-teal-accent" />
                </motion.div>
              </motion.div>
            </div>
            
            <motion.div
              animate={{ opacity: [0.5, 1, 0.5] }}
              transition={{ duration: 4, repeat: Infinity }}
              className="absolute bottom-24 text-3xl font-bold text-slate-900 dark:text-white"
            >
              Breathe In...
            </motion.div>
            
            <div className="absolute bottom-12 text-slate-600 dark:text-white/50 text-base font-bold">4 - 7 - 8 Pattern</div>
          </motion.div>
        </div>
      </motion.div>

      {/* Screen selector dots - larger */}
      <div className="flex justify-center gap-3 mt-6">
        {screens.map((screen, i) => (
          <button
            key={screen.name}
            onClick={() => setActiveScreen(i)}
            className={`h-3 rounded-full transition-all duration-300 ${
              activeScreen === i 
                ? 'bg-teal-600 dark:bg-teal-accent w-8' 
                : 'bg-slate-300 dark:bg-white/20 w-3 hover:bg-slate-400 dark:hover:bg-white/40'
            }`}
            aria-label={`View ${screen.label} screen`}
          />
        ))}
      </div>
    </div>
  )
}
