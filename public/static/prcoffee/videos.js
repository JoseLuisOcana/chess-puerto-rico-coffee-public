/* chesspuertoricocoffee.com — homepage "🎥 Chess Videos" strip (2026-10-03).
 * Loaded ONLY on "/" ($chess_videos in the vhost, spliced into chess-branding.conf's '</head>' rule).
 * Data: /prcoffee/videos.json, written weekly by /usr/local/bin/chess-video-refresh.sh — the 4 newest
 * videos of lila's own library, thumbnails served from /prcoffee/video-thumbs/ (no third-party
 * requests). Cards link to our own /video/<id> pages. Styles: "Chess Videos strip" in branding.css.
 * Bottom order (2026-10-03): strip, then lila's link row (.lobby__about: Contact · About · Terms · Privacy ·
 * shop link), moved here from the end of main.lobby, then the sponsor bar + AGPL footer (untouched).
 * DOM is built with textContent only; any failure leaves the page exactly as lila rendered it — the
 * link row is only moved once the strip is actually on the page. */
(function () {
  'use strict';
  if (location.pathname !== '/') return;

  var ID = /^[A-Za-z0-9_-]{11}$/;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }

  // 2026-10-08: Spanish pages (<html lang="es-…">) get Spanish labels and dates
  var ES = /^es\b/i.test(document.documentElement.lang || '');

  function card(v) {
    var a = el('a', 'prc-vcard');
    a.href = '/video/' + v.id;
    var thumb = el('span', 'prc-vcard__thumb');
    var img = el('img');
    img.src = '/prcoffee/video-thumbs/' + v.id + '.jpg';
    img.alt = '';
    img.width = 320;
    img.height = 180;
    img.loading = 'lazy';
    img.decoding = 'async';
    thumb.appendChild(img);
    if (v.dateLabel) {
      var label = v.dateLabel;
      if (ES && v.date) {
        try { label = new Date(v.date).toLocaleDateString('es-PR', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }); } catch (e) { /* keep */ }
      }
      var date = el('time', 'prc-vcard__date', label);
      if (v.date) date.dateTime = v.date;
      thumb.appendChild(date);
    }
    a.appendChild(thumb);
    var body = el('span', 'prc-vcard__body');
    body.appendChild(el('span', 'prc-vcard__title', v.title));
    body.appendChild(el('span', 'prc-vcard__channel', v.channel));
    a.appendChild(body);
    return a;
  }

  function render(data) {
    var main = document.querySelector('#main-wrap > main.lobby');
    if (!main || document.getElementById('prc-videos')) return;
    var vids = (data && data.videos || []).filter(function (v) {
      return v && ID.test(v.id) && typeof v.title === 'string' && typeof v.channel === 'string';
    }).slice(0, 4);
    if (!vids.length) return;
    var section = el('section', 'prc-videos');
    section.id = 'prc-videos';
    section.setAttribute('aria-labelledby', 'prc-videos-title');
    var head = el('div', 'prc-videos__head');
    var h2 = el('h2', 'prc-videos__title', ES ? '🎥 Videos de ajedrez' : '🎥 Chess Videos');
    h2.id = 'prc-videos-title';
    head.appendChild(h2);
    var more = el('a', 'prc-videos__more', ES ? 'Todos los videos »' : 'All videos »');
    more.href = '/video';
    head.appendChild(more);
    section.appendChild(head);
    var grid = el('div', 'prc-videos__grid');
    vids.forEach(function (v) { grid.appendChild(card(v)); });
    section.appendChild(grid);
    main.insertAdjacentElement('afterend', section);
    var about = main.querySelector(':scope > .lobby__about');
    if (about) section.insertAdjacentElement('afterend', about);
  }

  function start() {
    fetch('/prcoffee/videos.json', { cache: 'no-cache', credentials: 'omit' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(render)
      .catch(function () {});
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
