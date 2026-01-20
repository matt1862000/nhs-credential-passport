# WalkingWR Website

A modern, impressive marketing website for the WalkingWR iOS app.

## Tech Stack

- **Next.js 14** - React framework with App Router
- **TypeScript** - Type safety
- **Tailwind CSS** - Styling
- **Framer Motion** - Animations

## Features

- ✨ Stunning dark theme with glassmorphism effects
- 🎨 Smooth scroll animations
- 📱 Interactive phone mockup with live app preview
- 🚀 Fast performance with Next.js
- ♿ NHS accessibility compliant (WCAG 2.1 AA)
- 📱 Fully responsive design

## Getting Started

### Prerequisites

- Node.js 18+ 
- npm or yarn

### Installation

```bash
cd website
npm install
```

### Development

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) in your browser.

### Build for Production

```bash
npm run build
npm start
```

## Deployment

This site is designed to be deployed on **Vercel**:

1. Push to GitHub
2. Import to Vercel
3. Deploy automatically

## Structure

```
website/
├── src/
│   ├── app/
│   │   ├── globals.css      # Global styles
│   │   ├── layout.tsx       # Root layout
│   │   └── page.tsx         # Home page
│   └── components/
│       ├── Navbar.tsx       # Navigation
│       ├── Hero.tsx         # Hero section
│       ├── PhoneMockup.tsx  # Interactive phone
│       ├── Features.tsx     # Features grid
│       ├── HowItWorks.tsx   # Step-by-step guide
│       ├── ForClinicians.tsx# Clinician section
│       ├── Testimonials.tsx # Reviews
│       ├── Download.tsx     # CTA section
│       └── Footer.tsx       # Footer
├── tailwind.config.ts       # Tailwind config
└── package.json
```

## Customisation

### Colors

Edit `tailwind.config.ts` to change the color palette:

```typescript
colors: {
  'teal-accent': '#4ECDC4',
  'coral-pink': '#FF6B6B',
  // ...
}
```

### Content

Edit individual component files in `src/components/` to update:
- Testimonials
- Features
- Statistics
- Copy text

## License

© NHS Innovation - All rights reserved.
