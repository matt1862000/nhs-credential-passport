'use client'

import {
  Navbar,
  Hero,
  Features,
  HowItWorks,
  ForClinicians,
  Testimonials,
  Download,
  Footer,
} from '@/components'

export default function Home() {
  return (
    <main id="main-content" className="relative">
      <Navbar />
      <Hero />
      <Features />
      <HowItWorks />
      <ForClinicians />
      <Testimonials />
      <Download />
      <Footer />
    </main>
  )
}
