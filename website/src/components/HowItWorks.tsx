'use client'

import { motion } from 'framer-motion'
import { useInView } from 'framer-motion'
import { useRef } from 'react'

const steps = [
  {
    number: '01',
    title: 'Check In',
    description: 'Arrive at your clinic and select your clinician from the app.',
    icon: (
      <svg className="w-10 h-10" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z" />
      </svg>
    ),
  },
  {
    number: '02',
    title: 'See Your Wait',
    description: 'View real-time delay information and get a personalised walking recommendation.',
    icon: (
      <svg className="w-10 h-10" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
    ),
  },
  {
    number: '03',
    title: 'Choose Your Walk',
    description: 'Select from routes tailored to your time. Explore parks, trails, and local landmarks.',
    icon: (
      <svg className="w-10 h-10" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z" />
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
      </svg>
    ),
  },
  {
    number: '04',
    title: 'Walk & Relax',
    description: 'Follow turn-by-turn directions. Discover points of interest and try breathing exercises.',
    icon: (
      <svg className="w-10 h-10" fill="currentColor" viewBox="0 0 24 24">
        {/* Stars in upper left - four-pointed */}
        <path d="M3.5 3.5l0.3 0l0.15 0.15l0.15-0.15l0-0.3l-0.15-0.15l-0.15 0.15l-0.3 0z" />
        <path d="M5.5 2.5l0.3 0l0.15 0.15l0.15-0.15l0-0.3l-0.15-0.15l-0.15 0.15l-0.3 0z" />
        
        {/* Sun in upper right with rays */}
        <circle cx="19.5" cy="4.5" r="1.8" fill="currentColor" />
        <path d="M19.5 2v0.8M19.5 7v0.8M22 4.5h0.8M17.2 4.5h-0.8M21.2 2.8l0.6 0.6M17.8 6.2l0.6 0.6M21.2 6.2l0.6-0.6M17.8 2.8l0.6-0.6" strokeWidth={1} strokeLinecap="round" />
        
        {/* Left tree - small */}
        <path d="M4.5 17.5v-3.5" strokeWidth={1.2} strokeLinecap="round" />
        <circle cx="4.5" cy="12" r="2" fill="currentColor" />
        
        {/* Walking person with backpack and leaf - facing right */}
        {/* Head */}
        <circle cx="12" cy="9" r="1.5" fill="currentColor" />
        {/* Body */}
        <path d="M12 10.5v3.5" strokeWidth={1.3} strokeLinecap="round" />
        {/* Torso */}
        <path d="M11.2 10.5h1.6" strokeWidth={1.3} strokeLinecap="round" />
        {/* Legs - walking stride */}
        <path d="M11 14l-0.8 2.5M13 14l0.8 2.5" strokeWidth={1.3} strokeLinecap="round" />
        {/* Arms */}
        <path d="M10.5 11.5l-0.8-1M13.5 11.5l0.8-1" strokeWidth={1.3} strokeLinecap="round" />
        {/* Backpack */}
        <rect x="10.8" y="10.5" width="2.4" height="2.8" rx="0.3" fill="currentColor" />
        <path d="M10.8 12h2.4" strokeWidth={0.6} />
        {/* Leaf in right hand */}
        <path d="M13.5 11.5l1.2-0.6" strokeWidth={1.2} strokeLinecap="round" />
        <path d="M14.3 10.6c0.2-0.3 0.5-0.4 0.8-0.2 0.3 0.2 0.3 0.6 0.1 0.9-0.2 0.3-0.5 0.4-0.8 0.2-0.3-0.2-0.3-0.6-0.1-0.9" fill="currentColor" />
        
        {/* Right trees - two trees, larger */}
        <path d="M16.5 17v-3.5" strokeWidth={1.2} strokeLinecap="round" />
        <circle cx="16.5" cy="11.5" r="2.5" fill="currentColor" />
        <path d="M18.5 16.5v-3" strokeWidth={1.2} strokeLinecap="round" />
        <circle cx="18.5" cy="11.5" r="2.2" fill="currentColor" />
        
        {/* Dashed path/ground line */}
        <path d="M2 19.5h20" strokeWidth={1.5} strokeDasharray="2 1.5" strokeLinecap="round" />
      </svg>
    ),
  },
  {
    number: '05',
    title: 'Get Notified',
    description: 'Receive smart alerts when it\'s time to return. Never miss your appointment.',
    icon: (
      <svg className="w-10 h-10" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9" />
      </svg>
    ),
  },
]

export default function HowItWorks() {
  const ref = useRef(null)
  const isInView = useInView(ref, { once: true, margin: '-100px' })

  return (
    <section id="how-it-works" className="relative py-16 sm:py-24 md:py-32 overflow-hidden">
      {/* Background gradient */}
      <div className="absolute inset-0">
        <div className="absolute inset-0 bg-gradient-to-b from-midnight via-deep-navy to-midnight dark:from-midnight dark:via-deep-navy dark:to-midnight bg-gradient-to-b from-white via-slate-50 to-white" />
        <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[800px] h-[800px] bg-teal-accent/5 dark:bg-teal-accent/5 bg-teal-50 rounded-full blur-3xl" />
      </div>

      <div className="relative max-w-7xl mx-auto px-4 sm:px-6" ref={ref}>
        {/* Section Header */}
        <motion.div
          initial={{ opacity: 0, y: 30 }}
          animate={isInView ? { opacity: 1, y: 0 } : {}}
          transition={{ duration: 0.6 }}
          className="text-center mb-12 sm:mb-16 md:mb-20"
        >
          <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full glass mb-4 sm:mb-6">
            <span className="text-teal-accent dark:text-teal-accent text-teal-600 text-xs sm:text-sm font-medium">How It Works</span>
          </div>
          <h2 className="text-3xl sm:text-4xl md:text-5xl font-bold mb-4 sm:mb-6 text-slate-800 dark:text-white px-2 sm:px-0">
            Simple as
            <span className="gradient-text"> 1, 2, Walk</span>
          </h2>
          <p className="dark:text-white/50 text-slate-800 text-base sm:text-lg max-w-2xl mx-auto px-2 sm:px-0">
            Getting started is easy. In just a few steps, you'll transform your waiting time 
            into an opportunity for wellness.
          </p>
        </motion.div>

        {/* Steps Timeline */}
        <div className="relative">
          {/* Connecting line */}
          <div className="absolute left-1/2 top-0 bottom-0 w-px bg-gradient-to-b from-teal-accent/50 via-teal-accent/20 to-transparent hidden lg:block" />

          <div className="space-y-12 lg:space-y-0">
            {steps.map((step, index) => (
              <motion.div
                key={step.number}
                initial={{ opacity: 0, x: index % 2 === 0 ? -50 : 50 }}
                animate={isInView ? { opacity: 1, x: 0 } : {}}
                transition={{ duration: 0.6, delay: index * 0.15 }}
                className={`relative lg:grid lg:grid-cols-2 lg:gap-12 items-center ${
                  index % 2 === 0 ? '' : 'lg:flex-row-reverse'
                }`}
              >
                {/* Content */}
                <div className={`${index % 2 === 0 ? 'lg:text-right lg:pr-16' : 'lg:pl-16 lg:order-2'}`}>
                  <div className={`flex items-center gap-3 sm:gap-4 mb-3 sm:mb-4 ${index % 2 === 0 ? 'lg:justify-end' : ''}`}>
                    <span className="text-3xl sm:text-4xl md:text-5xl font-bold text-teal-accent/20 dark:text-teal-accent/20 text-teal-100">{step.number}</span>
                    <h3 className="text-xl sm:text-2xl font-bold dark:text-white text-slate-800">{step.title}</h3>
                  </div>
                  <p className="dark:text-white/50 text-slate-800 text-base sm:text-lg leading-relaxed">
                    {step.description}
                  </p>
                </div>

                {/* Icon Node */}
                <div className={`hidden lg:flex ${index % 2 === 0 ? 'justify-start' : 'justify-end order-1'}`}>
                  <div className="relative">
                    {/* Glow */}
                    <div className="absolute inset-0 bg-teal-accent/20 rounded-2xl blur-xl" />
                    
                    {/* Icon container */}
                    <div className="relative w-24 h-24 rounded-2xl bg-gradient-to-br from-teal-accent/20 to-teal-accent/5 dark:from-teal-accent/20 dark:to-teal-accent/5 from-teal-100 to-teal-50 border border-teal-accent/30 dark:border-teal-accent/30 border-teal-200 flex items-center justify-center text-teal-accent dark:text-teal-accent text-teal-600">
                      {step.icon}
                    </div>

                    {/* Dot on timeline */}
                    <div className="absolute top-1/2 -translate-y-1/2 w-4 h-4 rounded-full bg-teal-accent dark:bg-teal-accent border-4 border-midnight dark:border-midnight border-slate-50"
                      style={{ 
                        left: index % 2 === 0 ? 'calc(100% + 40px)' : 'auto',
                        right: index % 2 !== 0 ? 'calc(100% + 40px)' : 'auto',
                      }}
                    />
                  </div>
                </div>

                {/* Mobile icon */}
                <div className="lg:hidden mt-4 sm:mt-6">
                  <div className="w-14 h-14 sm:w-16 sm:h-16 rounded-xl bg-gradient-to-br from-teal-accent/20 to-teal-accent/5 dark:from-teal-accent/20 dark:to-teal-accent/5 from-teal-100 to-teal-50 border border-teal-accent/30 dark:border-teal-accent/30 border-teal-200 flex items-center justify-center text-teal-accent dark:text-teal-accent text-teal-600">
                    {step.icon}
                  </div>
                </div>
              </motion.div>
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}
