/* /prcoffee/signup-check.js - BUTTON 260 (2026-11-26, owner; Codex review item 08): a simple bot check on sign-up, no third party.
   On lila's sign-up page it adds a hidden "website" field (a honeypot: people never see or fill it) and keeps the cookie prc_su=1 (for
   /signup only) set while the page is open, from 3 seconds after it opened, as long as the honeypot is empty. nginx sends a POST /signup
   without that cookie back to this page (303 /signup?check=1), where a note says what to do. A person who sends the form within the
   first 3 seconds just waits for the rest of them (the form is sent automatically); a filled honeypot removes the cookie. */
(function () {
  var opened = Date.now(), WAIT = 3000;
  var ON = 'prc_su=1; Path=/signup; Max-Age=900; SameSite=Strict; Secure', OFF = 'prc_su=; Path=/signup; Max-Age=0; SameSite=Strict; Secure';
  function setup() {
    var f = document.getElementById('signup-form');
    if (!f || f.getAttribute('data-prc-check')) return;
    f.setAttribute('data-prc-check', '1');
    var hp = document.createElement('input');
    hp.type = 'text'; hp.name = 'website'; hp.tabIndex = -1; hp.autocomplete = 'off'; hp.setAttribute('aria-hidden', 'true');
    hp.style.cssText = 'position:absolute;left:-9999px;width:1px;height:1px;opacity:0';
    f.appendChild(hp);
    function mark() { document.cookie = hp.value === '' ? ON : OFF; }
    setTimeout(function () { mark(); setInterval(mark, 5 * 60 * 1000); }, Math.max(0, WAIT - (Date.now() - opened)));
    var pending = false;
    f.addEventListener('submit', function (e) {
      if (hp.value !== '') { document.cookie = OFF; return; }
      var left = WAIT - (Date.now() - opened);
      if (left > 0) {   // too fast: hold it (once) for the rest of the 3 seconds, then send it again the normal way
        e.preventDefault(); e.stopImmediatePropagation();
        if (pending) return;
        pending = true;
        var by = e.submitter || null;
        setTimeout(function () {
          pending = false; mark();
          if (f.requestSubmit) f.requestSubmit(by && by.form === f ? by : undefined); else HTMLFormElement.prototype.submit.call(f);
        }, left);
        return;
      }
      mark();   // fresh cookie right before this send
    }, true);
    if (/[?&]check=1(&|$)/.test(location.search)) {
      var n = document.createElement('p');
      n.setAttribute('role', 'alert');
      n.style.cssText = 'margin:0 0 1em;padding:.6em .8em;border:1px solid #c9a227;border-radius:4px;background:rgba(201,162,39,.12)';
      n.textContent = 'Your sign-up was not sent. Please fill in the form again and send it - this page needs JavaScript and a few seconds.';
      f.insertBefore(n, f.firstChild);
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', setup); else setup();
})();
