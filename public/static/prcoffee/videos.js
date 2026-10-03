/* chesspuertoricocoffee.com — homepage "🎥 Chess Videos" strip (2026-10-03).
 * Loaded ONLY on "/" ($chess_videos in the vhost, spliced into chess-branding.conf's '</head>' rule).
 * Data: /prcoffee/videos.json, written weekly by /usr/local/bin/chess-video-refresh.sh — the 4 newest
 * videos of lila's own library, thumbnails served from /prcoffee/video-thumbs/ (no third-party
 * requests). Cards link to our own /video/<id> pages. Styles: "Chess Videos strip" in branding.css.
 * DOM is built with textContent only; any failure leaves the page exactly as lila rendered it. */
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
      var date = el('time', 'prc-vcard__date', v.dateLabel);
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
    var h2 = el('h2', 'prc-videos__title', '🎥 Chess Videos');
    h2.id = 'prc-videos-title';
    head.appendChild(h2);
    var more = el('a', 'prc-videos__more', 'All videos »');
    more.href = '/video';
    head.appendChild(more);
    section.appendChild(head);
    var grid = el('div', 'prc-videos__grid');
    vids.forEach(function (v) { grid.appendChild(card(v)); });
    section.appendChild(grid);
    main.insertAdjacentElement('afterend', section);
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
