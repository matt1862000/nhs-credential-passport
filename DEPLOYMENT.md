# Website Deployment Guide

Your WalkingWR website is ready to deploy! Here are the steps to get it live.

## Option 1: Vercel (Recommended - Easiest for Next.js)

Vercel is the best platform for Next.js apps and offers a free tier.

### Steps:

1. **Commit and push your changes to GitHub:**
   ```bash
   git add .
   git commit -m "Update website with latest changes"
   git push
   ```

2. **Deploy on Vercel:**
   - Go to [vercel.com](https://vercel.com)
   - Sign up/login with your GitHub account
   - Click "Add New Project"
   - Import your WalkingWR repository
   - **Important**: Set the "Root Directory" to `website`
   - Click "Deploy"
   - Vercel will automatically:
     - Detect Next.js
     - Build your site
     - Deploy it
     - Give you a URL like `walkingwr.vercel.app`

3. **Custom Domain (Optional):**
   - In Vercel dashboard, go to Settings → Domains
   - Add your custom domain (e.g., `walkingwr.com`)

## Option 2: Netlify

Netlify also works great with Next.js.

### Steps:

1. **Commit and push to GitHub** (same as above)

2. **Deploy on Netlify:**
   - Go to [netlify.com](https://netlify.com)
   - Sign up/login with GitHub
   - Click "Add new site" → "Import an existing project"
   - Select your WalkingWR repository
   - **Build settings:**
     - Base directory: `website`
     - Build command: `npm run build`
     - Publish directory: `website/.next`
   - Click "Deploy site"

## Option 3: GitHub Pages (Requires Static Export)

GitHub Pages requires a static export. You'll need to modify the Next.js config.

### Steps:

1. **Update next.config.js** to add:
   ```js
   output: 'export',
   ```

2. **Build and deploy:**
   ```bash
   cd website
   npm run build
   # The output will be in website/out
   ```

3. **Use GitHub Actions** or manually push the `out` folder to `gh-pages` branch

## Quick Deploy Commands

If you want to commit and push everything now:

```bash
# From the WalkingWR root directory
git add .
git commit -m "Update website: improve UX, fix light mode, and prepare for deployment"
git push
```

Then follow the Vercel or Netlify steps above.

## Recommended: Vercel

Vercel is recommended because:
- ✅ Built by the Next.js team
- ✅ Zero configuration needed
- ✅ Automatic deployments on git push
- ✅ Free SSL certificates
- ✅ Global CDN
- ✅ Preview deployments for PRs
- ✅ Free tier is generous

Your site will be live in under 5 minutes!
