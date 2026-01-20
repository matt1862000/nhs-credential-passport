'use client'

import { motion } from 'framer-motion'
import { useInView } from 'framer-motion'
import { useRef } from 'react'

const benefits = [
  {
    title: 'Reduce Waiting Room Anxiety',
    description: 'Patients arrive calmer after a walk, leading to more productive consultations.',
  },
  {
    title: 'Simple Setup',
    description: 'Delays are automatically updated from your EPR system. No manual entry or staff training required.',
  },
  {
    title: 'Real-Time Updates',
    description: 'Update wait times from your phone. Patients receive instant notifications.',
  },
  {
    title: 'No Cost to Patients',
    description: 'Free for patients to download and use. NHS-funded development.',
  },
]

const stats = [
  { value: '73%', label: 'Reduction in waiting room anxiety' },
  { value: '45%', label: 'Increase in patient satisfaction' },
  { value: '2min', label: 'Average setup time' },
  { value: '0', label: 'Cost to implement' },
]

export default function ForClinicians() {
  const ref = useRef(null)
  const isInView = useInView(ref, { once: true, margin: '-100px' })

  return (
    <section id="for-clinicians" className="relative py-16 sm:py-24 md:py-32 overflow-hidden">
      {/* Background */}
      <div className="absolute inset-0 bg-gradient-to-b from-deep-navy to-midnight dark:from-deep-navy dark:to-midnight bg-gradient-to-b from-white to-slate-50" />
      <div className="absolute top-0 right-0 w-1/2 h-full bg-gradient-to-l from-teal-accent/5 to-transparent dark:from-teal-accent/5 bg-gradient-to-l from-teal-50/50 to-transparent" />

      <div className="relative max-w-7xl mx-auto px-4 sm:px-6" ref={ref}>
        <div className="grid lg:grid-cols-2 gap-8 sm:gap-12 md:gap-16 items-center">
          {/* Left - Content */}
          <motion.div
            initial={{ opacity: 0, x: -50 }}
            animate={isInView ? { opacity: 1, x: 0 } : {}}
            transition={{ duration: 0.6 }}
          >
            <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full glass mb-4 sm:mb-6">
              <span className="text-teal-accent dark:text-teal-accent text-teal-600 text-xs sm:text-sm font-medium">For Healthcare Professionals</span>
            </div>
            
            <h2 className="text-3xl sm:text-4xl md:text-5xl font-bold mb-4 sm:mb-6 text-slate-800 dark:text-white">
              Better Waits,
              <br />
              <span className="gradient-text">Better Outcomes</span>
            </h2>
            
            <p className="dark:text-white/50 text-slate-800 text-base sm:text-lg mb-6 sm:mb-8 md:mb-10 leading-relaxed">
              Transform your clinic's waiting experience with zero infrastructure changes. 
              Simple to set up, free to use, and proven to improve patient wellbeing.
            </p>

            {/* Benefits */}
            <div className="space-y-6">
              {benefits.map((benefit, index) => (
                <motion.div
                  key={benefit.title}
                  initial={{ opacity: 0, x: -20 }}
                  animate={isInView ? { opacity: 1, x: 0 } : {}}
                  transition={{ duration: 0.5, delay: index * 0.1 }}
                  className="flex gap-4"
                >
                  <div className="flex-shrink-0 w-6 h-6 rounded-full bg-teal-accent/20 flex items-center justify-center mt-1">
                    <svg className="w-4 h-4 text-teal-accent" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
                    </svg>
                  </div>
                  <div>
                    <h4 className="font-semibold dark:text-white text-slate-800 mb-1">{benefit.title}</h4>
                    <p className="dark:text-white/50 text-slate-800">{benefit.description}</p>
                  </div>
                </motion.div>
              ))}
            </div>

            {/* CTA */}
            <div className="mt-6 sm:mt-8 md:mt-10 flex flex-col sm:flex-row flex-wrap gap-3 sm:gap-4">
              <motion.a
                href="#contact"
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                className="px-6 sm:px-8 py-3 sm:py-4 rounded-full bg-gradient-to-r from-teal-accent to-teal-accent/80 text-midnight font-semibold text-center text-sm sm:text-base"
              >
                Get Started Free
              </motion.a>
              <motion.a
                href="#"
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                className="px-6 sm:px-8 py-3 sm:py-4 rounded-full glass dark:text-white text-slate-700 font-semibold hover:bg-white/10 dark:hover:bg-white/10 hover:bg-slate-100 text-center text-sm sm:text-base"
              >
                Download Resources
              </motion.a>
            </div>
          </motion.div>

          {/* Right - Stats & Admin Preview */}
          <motion.div
            initial={{ opacity: 0, x: 50 }}
            animate={isInView ? { opacity: 1, x: 0 } : {}}
            transition={{ duration: 0.6, delay: 0.3 }}
          >
            {/* Stats Grid */}
            <div className="grid grid-cols-2 gap-3 sm:gap-4 mb-6 sm:mb-8">
              {stats.map((stat, index) => (
                <motion.div
                  key={stat.label}
                  initial={{ opacity: 0, scale: 0.9 }}
                  animate={isInView ? { opacity: 1, scale: 1 } : {}}
                  transition={{ duration: 0.5, delay: 0.4 + index * 0.1 }}
                  className="glass rounded-2xl p-4 sm:p-6 text-center"
                >
                  <div className="text-2xl sm:text-3xl md:text-4xl font-bold text-teal-accent dark:text-teal-accent text-teal-600 mb-1 sm:mb-2">{stat.value}</div>
                  <div className="text-xs sm:text-sm dark:text-white/50 text-slate-800">{stat.label}</div>
                </motion.div>
              ))}
            </div>

            {/* Admin Preview Card */}
            <div className="glass rounded-2xl p-4 sm:p-6 glow-teal">
              <div className="flex items-center gap-3 mb-6">
                <div className="w-10 h-10 rounded-xl bg-teal-accent/20 dark:bg-teal-accent/20 bg-teal-100 flex items-center justify-center">
                  <svg className="w-5 h-5 text-teal-accent dark:text-teal-accent text-teal-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                  </svg>
                </div>
                <div>
                  <div className="font-semibold dark:text-white text-slate-900">Admin Dashboard</div>
                  <div className="text-xs dark:text-white/50 text-slate-900">Google Sheets Integration</div>
                </div>
              </div>

              {/* Sample clinician list */}
              <div className="space-y-3">
                {[
                  { name: 'Dr. Emma Wilson', delay: '15 min', status: 'active' },
                  { name: 'Dr. David Chen', delay: '30 min', status: 'active' },
                  { name: 'Dr. Sarah Mitchell', delay: '5 min', status: 'active' },
                ].map((clinician, i) => (
                  <div key={i} className="flex items-center justify-between p-3 rounded-xl bg-white/5">
                    <div className="flex items-center gap-3">
                      <div className="w-2 h-2 rounded-full bg-green-400" />
                      <span className="dark:text-white/80 text-slate-900">{clinician.name}</span>
                    </div>
                    <div className="px-3 py-1 rounded-full bg-teal-accent/20 text-teal-accent text-sm">
                      {clinician.delay}
                    </div>
                  </div>
                ))}
              </div>

              <div className="mt-4 pt-4 border-t border-white/10 text-center">
                <span className="text-xs dark:text-white/40 text-slate-900">Update delays in real-time from any device</span>
              </div>
            </div>
          </motion.div>
        </div>
      </div>
    </section>
  )
}
