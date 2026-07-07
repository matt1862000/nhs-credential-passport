/**
 * DocPass service worker — cache static shell; never cache /api (sessions, wallet, HR data).
 */
var CACHE_VERSION = 'docpass-pwa-v1';
var SHELL_CACHE = CACHE_VERSION + '-shell';
var ASSET_CACHE = CACHE_VERSION + '-assets';

var PRECACHE_URLS = [
  '/static/shared/app.css',
  '/static/shared/auth.js',
  '/static/shared/nav-account.js',
  '/static/shared/pwa.js',
  '/static/shared/icons/icon-192.png',
  '/static/offline.html',
];

function isApiRequest(url) {
  return url.pathname.indexOf('/api/') === 0;
}

function isStaticAsset(url) {
  var p = url.pathname;
  return p.indexOf('/static/') === 0 && /\.(css|js|png|svg|woff2?)$/i.test(p);
}

function isNavigation(request) {
  return request.mode === 'navigate' ||
    (request.method === 'GET' && request.headers.get('accept') && request.headers.get('accept').indexOf('text/html') !== -1);
}

self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(SHELL_CACHE).then(function (cache) {
      return cache.addAll(PRECACHE_URLS);
    }).then(function () {
      return self.skipWaiting();
    })
  );
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys.filter(function (k) {
          return k.indexOf('docpass-pwa-') === 0 && k !== SHELL_CACHE && k !== ASSET_CACHE;
        }).map(function (k) { return caches.delete(k); })
      );
    }).then(function () {
      return self.clients.claim();
    })
  );
});

self.addEventListener('fetch', function (event) {
  var req = event.request;
  if (req.method !== 'GET') return;

  var url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (isApiRequest(url)) {
    event.respondWith(fetch(req));
    return;
  }

  if (isNavigation(req)) {
    event.respondWith(
      fetch(req).catch(function () {
        return caches.match('/static/offline.html');
      })
    );
    return;
  }

  if (isStaticAsset(url)) {
    event.respondWith(
      caches.open(ASSET_CACHE).then(function (cache) {
        return cache.match(req).then(function (cached) {
          var networkFetch = fetch(req).then(function (res) {
            if (res && res.status === 200) {
              cache.put(req, res.clone());
            }
            return res;
          });
          return cached || networkFetch;
        });
      })
    );
  }
});
