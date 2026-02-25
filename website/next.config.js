/** @type {import('next').NextConfig} */
const nextConfig = {
  // No output: 'export' for normal/Vercel builds (API routes need server). GitHub Actions sets this for static export.
  ...(process.env.GITHUB_ACTIONS === 'true' && { output: 'export' }),
  images: {
    unoptimized: true,
    remotePatterns: [
      {
        protocol: 'https',
        hostname: 'raw.githubusercontent.com',
      },
      {
        protocol: 'https',
        hostname: 'staticmap.openstreetmap.de',
      },
    ],
  },
}

module.exports = nextConfig

