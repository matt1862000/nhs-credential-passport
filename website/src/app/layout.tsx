import type { Metadata } from 'next'
import './globals.css'
import { ThemeProvider } from '../contexts/ThemeContext'

export const metadata: Metadata = {
  title: 'WaitWell | The Walking Waiting Room',
  description: 'Transform your clinic wait time into wellness time. Walk, breathe, and stay healthy while waiting for your appointment.',
  keywords: ['NHS', 'waiting room', 'walking', 'health', 'wellness', 'clinic', 'appointment'],
  authors: [{ name: 'NHS Innovation' }],
  openGraph: {
    title: 'WaitWell | The Walking Waiting Room',
    description: 'Transform your clinic wait time into wellness time.',
    type: 'website',
  },
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>
        <ThemeProvider>
          {/* Skip to main content for accessibility */}
          <a href="#main-content" className="skip-link">
            Skip to main content
          </a>
          {children}
        </ThemeProvider>
      </body>
    </html>
  )
}
