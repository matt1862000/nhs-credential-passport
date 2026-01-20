'use client'

import { motion } from 'framer-motion'
import { useInView } from 'framer-motion'
import { useRef, useState } from 'react'

const testimonials = [
  {
    quote: "I used to dread the long waits at my psychiatry appointments. Now I actually look forward to exploring the area. It's transformed my anxiety into something positive.",
    author: "Sarah M.",
    role: "Patient, Leeds",
    avatar: "SM",
    rating: 5,
  },
  {
    quote: "As a clinician, I've seen patients arrive calmer and more engaged after using the app. It's a simple change that's made a real difference to our consultations.",
    author: "Dr. James Thompson",
    role: "Consultant Psychiatrist",
    avatar: "JT",
    rating: 5,
  },
  {
    quote: "The breathing exercises helped me manage my pre-appointment nerves. I've even started using them at home. Such a thoughtful feature.",
    author: "Michael R.",
    role: "Patient, Bradford",
    avatar: "MR",
    rating: 5,
  },
  {
    quote: "My elderly mother was initially skeptical, but now she loves discovering new walking routes. It's added a wonderful sense of adventure to her appointments.",
    author: "Emma K.",
    role: "Carer",
    avatar: "EK",
    rating: 5,
  },
  {
    quote: "The real-time updates are incredibly accurate. I never worry about missing my slot anymore, and I've discovered so many lovely parks nearby.",
    author: "David L.",
    role: "Patient, Wakefield",
    avatar: "DL",
    rating: 5,
  },
  {
    quote: "Implementing this in our clinic was straightforward. The QR code system is genius - no training needed for reception staff. Highly recommend.",
    author: "Dr. Priya Patel",
    role: "GP Partner",
    avatar: "PP",
    rating: 5,
  },
]

export default function Testimonials() {
  const ref = useRef(null)
  const isInView = useInView(ref, { once: true, margin: '-100px' })
  const [activeIndex, setActiveIndex] = useState(0)

  return (
    <section id="testimonials" className="relative py-16 sm:py-24 md:py-32 overflow-hidden">
      {/* Background */}
      <div className="absolute inset-0 bg-midnight dark:bg-midnight bg-white" />

      <div className="relative max-w-7xl mx-auto px-4 sm:px-6" ref={ref}>
        {/* Section Header */}
        <motion.div
          initial={{ opacity: 0, y: 30 }}
          animate={isInView ? { opacity: 1, y: 0 } : {}}
          transition={{ duration: 0.6 }}
          className="text-center mb-12 sm:mb-16"
        >
          <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full glass mb-4 sm:mb-6">
            <span className="text-teal-accent dark:text-teal-accent text-teal-600 text-xs sm:text-sm font-medium">Testimonials</span>
          </div>
          <h2 className="text-3xl sm:text-4xl md:text-5xl font-bold mb-4 sm:mb-6 text-slate-800 dark:text-white px-2 sm:px-0">
            Loved by Patients
            <span className="gradient-text"> & Clinicians</span>
          </h2>
          <p className="dark:text-white/50 text-slate-800 text-base sm:text-lg max-w-2xl mx-auto px-2 sm:px-0">
            See what our community has to say about transforming their waiting room experience.
          </p>
        </motion.div>

        {/* Testimonials Grid */}
        <div className="grid md:grid-cols-2 lg:grid-cols-3 gap-6">
          {testimonials.map((testimonial, index) => (
            <motion.div
              key={testimonial.author}
              initial={{ opacity: 0, y: 30 }}
              animate={isInView ? { opacity: 1, y: 0 } : {}}
              transition={{ duration: 0.6, delay: index * 0.1 }}
              className="glass rounded-2xl p-6 sm:p-8 hover:bg-white/5 transition-colors group"
            >
              {/* Stars */}
              <div className="flex gap-1 mb-4 sm:mb-6">
                {[...Array(testimonial.rating)].map((_, i) => (
                  <svg key={i} className="w-4 h-4 sm:w-5 sm:h-5 text-soft-amber" fill="currentColor" viewBox="0 0 20 20">
                    <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z" />
                  </svg>
                ))}
              </div>

              {/* Quote */}
              <p className="dark:text-white/70 text-slate-900 text-sm sm:text-base leading-relaxed mb-6 sm:mb-8 dark:group-hover:text-white/90 group-hover:text-slate-950 transition-colors">
                "{testimonial.quote}"
              </p>

              {/* Author */}
              <div className="flex items-center gap-3 sm:gap-4">
                <div className="w-10 h-10 sm:w-12 sm:h-12 rounded-full bg-gradient-to-br from-teal-accent to-teal-accent/50 dark:from-teal-accent dark:to-teal-accent/50 from-teal-500 to-teal-400 flex items-center justify-center text-midnight dark:text-midnight text-white font-bold text-sm sm:text-base">
                  {testimonial.avatar}
                </div>
                <div>
                  <div className="font-semibold dark:text-white text-slate-800 text-sm sm:text-base">{testimonial.author}</div>
                  <div className="text-xs sm:text-sm dark:text-white/50 text-slate-800">{testimonial.role}</div>
                </div>
              </div>
            </motion.div>
          ))}
        </div>

        {/* Trust Badges */}
        <motion.div
          initial={{ opacity: 0, y: 30 }}
          animate={isInView ? { opacity: 1, y: 0 } : {}}
          transition={{ duration: 0.6, delay: 0.8 }}
          className="mt-12 sm:mt-16 md:mt-20 flex flex-wrap items-center justify-center gap-4 sm:gap-6 md:gap-8"
        >
          <div className="glass rounded-xl px-4 sm:px-6 py-3 sm:py-4 flex items-center gap-2 sm:gap-3">
            <div className="w-10 h-10 rounded-lg bg-nhs-blue flex items-center justify-center">
              <svg className="w-6 h-6 dark:text-white text-slate-800" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
              </svg>
            </div>
            <div>
              <div className="font-semibold dark:text-white text-slate-900">NHS Compliant</div>
              <div className="text-xs dark:text-white/50 text-slate-900">Data Security Standards</div>
            </div>
          </div>

          <div className="glass rounded-xl px-6 py-4 flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-green-600 flex items-center justify-center">
              <svg className="w-6 h-6 dark:text-white text-slate-800" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
            </div>
            <div>
              <div className="font-semibold dark:text-white text-slate-900">GDPR Compliant</div>
              <div className="text-xs dark:text-white/50 text-slate-900">Privacy First</div>
            </div>
          </div>

          <div className="glass rounded-xl px-6 py-4 flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-purple-600 flex items-center justify-center">
              <svg className="w-6 h-6 dark:text-white text-slate-800" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z" />
              </svg>
            </div>
            <div>
              <div className="font-semibold dark:text-white text-slate-900">WCAG 2.1 AA</div>
              <div className="text-xs dark:text-white/50 text-slate-900">Accessible to All</div>
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  )
}
