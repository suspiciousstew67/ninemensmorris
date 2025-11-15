// scripts/generate-sw.js
// Generates a production-ready service-worker.js using workbox-build
// Run with: `npm run build-sw`

const { generateSW } = require('workbox-build');
const path = require('path');

const distDir = path.resolve(__dirname, '..');

generateSW({
  globDirectory: distDir,
  globPatterns: [
    'index.html',
    '/*.html',
    '/*.js',
    '/*.css',
    '*.ico',
    '*.png',
    '*.svg'
  ],
  swDest: path.join(distDir, 'service-worker.js'),
  clientsClaim: true,
  skipWaiting: true,
  maximumFileSizeToCacheInBytes: 5 * 1024 * 1024, // 5MB
  navigateFallback: 'index.html',
  // Runtime caching for common external resources (best-effort; CORS may block caching)
  runtimeCaching: [
    {
      urlPattern: /^https:\/\/cdnjs\.cloudflare\.com\/.*/i,
      handler: 'StaleWhileRevalidate',
      options: {
        cacheName: 'cdn-cache',
        expiration: {
          maxEntries: 30,
          maxAgeSeconds: 30 * 24 * 60 * 60 // 30 days
        }
      }
    }
  ]
}).then(({ count, size, warnings }) => {
  warnings.forEach(w => console.warn(w));
  console.log(`Generated service-worker.js, which will precache ${count} files, totaling ${size} bytes.`);
}).catch(err => {
  console.error('Failed to generate service-worker.js:', err);
  process.exitCode = 1;
});
