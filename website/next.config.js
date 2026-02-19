/** @type {import('next').NextConfig} */
const nextConfig = {
  // No output: 'export' — API routes (e.g. /api/ors) require a server. Static export excludes them.
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

