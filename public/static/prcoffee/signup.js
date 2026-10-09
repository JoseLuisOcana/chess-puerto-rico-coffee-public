/* chesspuertoricocoffee.com — signup age confirmation (2026-10-03). Loaded only on /signup ($chess_signup_js).
 * The checkbox itself is put into lila's signup form by nginx (sub_filter + $chess_signup_age) with `required`,
 * so the browser refuses to submit the form until it is ticked — lila submits the form natively, which runs
 * that check first. This script only (1) adds the same box if a future lila version moves the sub_filter
 * anchor, and (2) replaces the browser's generic "Please check this box" with a clear message.
 * The box has no `name`, so it is never sent to lila: no server-side (Scala) change.
 * 2026-10-08: Spanish pages (<html lang="es-…">) get the Spanish message; the label carries both languages (CSS picks). */
(function () {
  'use strict';
  var form = document.getElementById('signup-form');
  if (!form) return;
  var ES = /^es\b/i.test(document.documentElement.lang || '');
  var MSG = ES ? 'Confirma que tienes 13 años o más, o que cuentas con el permiso de tus padres o tutores.'
             : 'Please confirm that you are 13 or older, or that you have a parent’s or guardian’s consent.';
  var box = document.getElementById('prc-age13');
  if (!box) {
    var agreement = form.querySelector('.agreement');
    if (!agreement) return; // unknown layout: change nothing
    var wrap = document.createElement('div');
    wrap.className = 'form-check form-group prc-age-check';
    // static markup (no user data), identical to what nginx injects
    wrap.innerHTML = '<div class="form-check__container"><span class="form-check__input">' +
      '<input id="prc-age13" type="checkbox" required><label class="form-check__label" for="prc-age13"></label>' +
      '</span><label class="form-label" for="prc-age13"><span class="prc-en">I am 13 or older (or have parental consent).</span>' +
      '<span class="prc-es">Tengo 13 años o más (o el permiso de mis padres o tutores).</span></label></div>';
    agreement.appendChild(wrap);
    box = document.getElementById('prc-age13');
  }
  box.required = true;
  var sync = function () { box.setCustomValidity(box.checked ? '' : MSG); };
  box.addEventListener('change', sync);
  sync();
})();
