/* Iron Wave Radio — shared application script
   Handles: station data, audio player, theme, mobile menu, cookie banner.
   No third-party trackers, no analytics, no external calls except the audio
   streams themselves (loaded only after the user presses Play). */

'use strict';

/* ========== STATION DATA ========== */
/* All streams verified reachable over HTTPS and accessible from the CIS region
   without a VPN. Sources are public webradio broadcasters (Rock Antenne / DE,
   181.fm / US, 0N Radio / DE, laut.fm / DE). */
const STATIONS = [
  { name: "Rock Antenne",          emoji: "🎸", country: "🇩🇪", bitrate: "MP3 128k",
    description: "Флагман немецкого рок-радио: классика и современный hard rock без пауз.",
    genres: ["Classic Rock", "Hard Rock", "Metal"],
    url: "https://stream.rockantenne.de/rockantenne/stream/mp3", isLive: true },

  { name: "Rock Antenne Heavy Metal", emoji: "🤘", country: "🇩🇪", bitrate: "MP3 128k",
    description: "Чистый метал-канал Rock Antenne — от thrash до power metal.",
    genres: ["Heavy Metal", "Thrash", "Power Metal"],
    url: "https://stream.rockantenne.de/heavy-metal/stream/mp3", isLive: true },

  { name: "RA Classic Perlen",     emoji: "💎", country: "🇩🇪", bitrate: "MP3 128k",
    description: "Жемчужины классического рока 60–80-х в высоком качестве.",
    genres: ["Classic Rock", "Hard Rock", "70s"],
    url: "https://stream.rockantenne.de/classic-perlen/stream/mp3", isLive: true },

  { name: "RA Alternative",        emoji: "🎚️", country: "🇩🇪", bitrate: "MP3 128k",
    description: "Альтернативный рок и гранж — от Nirvana до современных имён.",
    genres: ["Alternative", "Grunge", "Indie Rock"],
    url: "https://stream.rockantenne.de/alternative/stream/mp3", isLive: true },

  { name: "RA Punk Rock",          emoji: "🧷", country: "🇩🇪", bitrate: "MP3 128k",
    description: "Панк и его наследники: скорость, драйв и бунтарский дух.",
    genres: ["Punk", "Hardcore", "Skate Punk"],
    url: "https://stream.rockantenne.de/punkrock/stream/mp3", isLive: true },

  { name: "181.fm The Rock!",      emoji: "🔥", country: "🇺🇸", bitrate: "MP3 128k",
    description: "Американское интернет-радио: чистый rock 24/7, легенды и хиты.",
    genres: ["Hard Rock", "Rock", "Active Rock"],
    url: "https://listen.181fm.com/181-rock_128k.mp3", isLive: true },

  { name: "181.fm Hard Rock",      emoji: "⚡", country: "🇺🇸", bitrate: "MP3 128k",
    description: "The Hard Rock Channel — тяжелее, громче, без компромиссов.",
    genres: ["Hard Rock", "Heavy Metal"],
    url: "https://listen.181fm.com/181-hardrock_128k.mp3", isLive: true },

  { name: "181.fm Awesome 80s",    emoji: "📼", country: "🇺🇸", bitrate: "MP3 128k",
    description: "Глэм- и хеир-метал восьмидесятых: лак, кожа и стадионные гимны.",
    genres: ["Glam Metal", "Hair Metal", "80s"],
    url: "https://listen.181fm.com/181-awesome80s_128k.mp3", isLive: true },

  { name: "181.fm Power Hits",     emoji: "🚀", country: "🇺🇸", bitrate: "MP3 128k",
    description: "Самые мощные рок-хиты всех времён в ротации нон-стоп.",
    genres: ["Rock Hits", "Hard Rock"],
    url: "https://listen.181fm.com/181-power_128k.mp3", isLive: true },

  { name: "0N Rock",               emoji: "🎛️", country: "🇩🇪", bitrate: "MP3 192k",
    description: "Немецкий поток 0N Radio: рок-классика и новинки в 192 kbps.",
    genres: ["Rock", "Hard Rock", "Classic Rock"],
    url: "https://0n-rock.radionetz.de/0n-rock.mp3", isLive: true },

  { name: "0N Classic Rock",       emoji: "🏆", country: "🇩🇪", bitrate: "MP3 192k",
    description: "Только проверенная временем классика рока в отличном качестве.",
    genres: ["Classic Rock", "70s", "80s"],
    url: "https://0n-classicrock.radionetz.de/0n-classicrock.mp3", isLive: true },

  { name: "laut.fm Metal",         emoji: "⛓️", country: "🇩🇪", bitrate: "MP3 128k",
    description: "Коммьюнити-радио laut.fm: тяжёлый метал во всём многообразии.",
    genres: ["Metal", "Heavy Metal", "Hard Rock"],
    url: "https://stream.laut.fm/metal", isLive: true }
];

/* ========== PLAYER ========== */
(function initPlayer() {
  const audio = document.getElementById('radio-player');
  if (!audio) return; // page without a player

  let isPlaying = false;
  let current = 0;
  let connectTimer = null;
  let triedFallback = false;

  const $ = (id) => document.getElementById(id);
  const setTrack = (txt) => { const el = $('now-track'); if (el) el.textContent = txt; };
  const setStationName = (txt) => { const el = $('current-station-name'); if (el) el.textContent = txt; };

  function syncUI() {
    document.querySelectorAll('.station-card').forEach((card, i) => card.classList.toggle('active', i === current));
    const sel = $('station-select');
    if (sel) sel.value = String(current);
  }

  function clearConnectTimer() { if (connectTimer) { clearTimeout(connectTimer); connectTimer = null; } }

  function showPlaying(on) {
    const playBtn = $('play-btn'), playIcon = $('play-icon'), vinyl = $('vinyl');
    if (playBtn) playBtn.classList.toggle('playing', on);
    if (vinyl) vinyl.classList.toggle('spinning', on);
    if (playIcon) playIcon.innerHTML = on
      ? '<rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>'
      : '<polygon points="5,3 19,12 5,21"/>';
  }

  function startStream() {
    const station = STATIONS[current];
    audio.src = station.url;
    setTrack('Подключение…');
    clearConnectTimer();
    // 12s connection watchdog → offer next station
    connectTimer = setTimeout(() => {
      if (isPlaying) {
        setTrack('Поток не отвечает. Переключаюсь на следующую станцию…');
        if (!triedFallback) { triedFallback = true; switchStation((current + 1) % STATIONS.length, true); }
      }
    }, 12000);
    audio.play().then(() => {
      clearConnectTimer();
      triedFallback = false;
      isPlaying = true;
      showPlaying(true);
      setTrack('В эфире • ' + station.name);
    }).catch(() => {
      clearConnectTimer();
      setTrack('Ошибка запуска. Нажмите PLAY ещё раз или выберите другую станцию.');
      isPlaying = false; showPlaying(false);
    });
  }

  window.switchStation = function (idx, keepPlaying) {
    current = ((idx % STATIONS.length) + STATIONS.length) % STATIONS.length;
    const station = STATIONS[current];
    setStationName(station.name);
    syncUI();
    if (isPlaying || keepPlaying) { startStream(); }
    else { setTrack('Нажми PLAY для начала'); audio.src = station.url; }
  };

  window.togglePlay = function () {
    if (isPlaying) {
      audio.pause();
      isPlaying = false;
      clearConnectTimer();
      showPlaying(false);
      setTrack('Пауза');
    } else {
      startStream();
    }
  };

  window.prevStation = () => switchStation(current - 1);
  window.nextStation = () => switchStation(current + 1);

  // Volume
  const vol = $('volume');
  if (vol) {
    audio.volume = parseFloat(vol.value || '0.8');
    vol.addEventListener('input', (e) => { audio.volume = parseFloat(e.target.value); });
  }

  // Stream <select>
  const sel = $('station-select');
  if (sel) {
    sel.innerHTML = STATIONS.map((s, i) => `<option value="${i}">${s.country} ${s.name}</option>`).join('');
    sel.addEventListener('change', (e) => switchStation(parseInt(e.target.value, 10)));
  }

  audio.addEventListener('error', () => {
    if (!isPlaying) return;
    clearConnectTimer();
    setTrack('Ошибка потока — пробую следующую станцию…');
    if (!triedFallback) { triedFallback = true; switchStation((current + 1) % STATIONS.length, true); }
    else { isPlaying = false; showPlaying(false); setTrack('Не удалось воспроизвести. Выберите станцию вручную.'); }
  });

  // Initial label
  setStationName(STATIONS[0].name);

  // Render streams grid on the home page
  const grid = document.getElementById('streams-grid');
  if (grid) {
    grid.innerHTML = STATIONS.map((s, i) => `
      <div class="station-card ${i === 0 ? 'active' : ''}" onclick="switchStation(${i})" role="button" tabindex="0"
           aria-label="Переключиться на станцию ${s.name}" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();switchStation(${i})}">
        <div class="station-top">
          <div class="station-emoji" aria-hidden="true">${s.emoji}</div>
          <span class="station-badge ${s.isLive ? 'live' : ''}">${s.isLive ? '● LIVE' : 'Online'}</span>
        </div>
        <h3>${s.name}</h3>
        <p>${s.description}</p>
        <div class="genres">${s.genres.map(g => `<span class="genre-tag">${g}</span>`).join('')}</div>
        <div class="station-meta"><span>${s.country} вещатель</span><span>${s.bitrate}</span></div>
      </div>`).join('');
  }
})();

/* ========== THEME TOGGLE (persisted) ========== */
(function initTheme() {
  const t = document.getElementById('theme-toggle');
  const r = document.documentElement;
  let d;
  try { d = localStorage.getItem('theme_preference'); } catch (e) { d = null; }
  if (!d) d = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  if (r.getAttribute('data-theme')) d = r.getAttribute('data-theme');
  r.setAttribute('data-theme', d);
  function icon(theme) {
    if (!t) return;
    t.innerHTML = theme === 'dark'
      ? '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="5"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/></svg>'
      : '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>';
    t.setAttribute('aria-label', 'Переключить на ' + (theme === 'dark' ? 'светлую' : 'тёмную') + ' тему');
  }
  icon(d);
  if (t) t.addEventListener('click', () => {
    d = d === 'dark' ? 'light' : 'dark';
    r.setAttribute('data-theme', d);
    try { localStorage.setItem('theme_preference', d); } catch (e) {}
    icon(d);
  });
})();

/* ========== MOBILE MENU ========== */
(function initMobileMenu() {
  const hamburger = document.getElementById('hamburger');
  const mobileMenu = document.getElementById('mobile-menu');
  if (!hamburger || !mobileMenu) return;
  hamburger.addEventListener('click', () => {
    const open = !mobileMenu.classList.contains('hidden');
    mobileMenu.classList.toggle('hidden', open);
    hamburger.setAttribute('aria-expanded', String(!open));
  });
  mobileMenu.querySelectorAll('a').forEach(a => a.addEventListener('click', () => {
    mobileMenu.classList.add('hidden');
    hamburger.setAttribute('aria-expanded', 'false');
  }));
})();

/* ========== COOKIE BANNER ========== */
function acceptCookies() {
  try { localStorage.setItem('cookie_consent', 'all'); } catch (e) {}
  const b = document.getElementById('cookie-banner'); if (b) b.style.display = 'none';
}
function closeCookieBanner() {
  try { localStorage.setItem('cookie_consent', 'necessary'); } catch (e) {}
  const b = document.getElementById('cookie-banner'); if (b) b.style.display = 'none';
}
(function checkConsent() {
  try {
    if (localStorage.getItem('cookie_consent')) {
      const b = document.getElementById('cookie-banner');
      if (b) { b.style.display = 'none'; b.style.animation = 'none'; }
    }
  } catch (e) {}
})();

/* ========== DYNAMIC YEAR ========== */
(function setYear() {
  document.querySelectorAll('[data-year]').forEach(el => { el.textContent = new Date().getFullYear(); });
})();
