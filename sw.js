/* 최소 서비스 워커: 설치 가능 조건 충족 + 오프라인일 때 마지막으로 본 화면. 새 배포는 항상 네트워크를 먼저 시도한다. */
var CACHE = 'gohae-shell-v1';
self.addEventListener('install', function (e) { self.skipWaiting(); });
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (ks) {
    return Promise.all(ks.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});
self.addEventListener('fetch', function (e) {
  var req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== location.origin) return;   // 서버(Supabase)·CDN 요청은 건드리지 않는다
  e.respondWith(fetch(req).then(function (res) {
    var copy = res.clone();
    if (res.ok) caches.open(CACHE).then(function (c) { c.put(req, copy); });
    return res;
  }).catch(function () { return caches.match(req).then(function (r) { return r || caches.match('./'); }); }));
});
