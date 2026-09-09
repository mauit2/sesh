// Sejdel cookie consent — the small card in the corner.
//
// sejdel.com sets no tracking cookies of its own; the card exists so the
// choice is on record before any third-party service the site loads gets
// to set one. The answer lives in localStorage (not a cookie — nothing to
// consent to for remembering the consent itself) and is exposed on
// window.SejdelConsent so anything added later can check it first:
//
//   SejdelConsent.granted()            → true only after "Accept"
//   SejdelConsent.open()               → reopen the card to change the answer
//   document.addEventListener('sejdel:consent', e => e.detail.accepted)
//
// Any <a class="sejdel-display-preferences"> or a link to #consent reopens
// it too — that is the "Consent preferences" link in the footer.
//
// Self-hosted, no dependencies, allowed by the pages' script-src 'self'.
(function () {
  'use strict';
  var KEY = 'sejdel.consent.v1';
  var saved = null;
  try { saved = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) {}

  window.SejdelConsent = {
    get: function () { return saved; },
    granted: function () { return !!(saved && saved.accepted); },
    open: function () { show(); },
    reset: function () { try { localStorage.removeItem(KEY); } catch (e) {} saved = null; show(); }
  };

  function decide(accepted) {
    saved = { accepted: accepted, at: new Date().toISOString() };
    try { localStorage.setItem(KEY, JSON.stringify(saved)); } catch (e) {}
    try { document.dispatchEvent(new CustomEvent('sejdel:consent', { detail: saved })); } catch (e) {}
    hide();
  }

  var root = null;
  function hide() {
    if (!root) return;
    root.classList.add('is-leaving');
    var r = root; root = null;
    setTimeout(function () { if (r.parentNode) r.parentNode.removeChild(r); }, 320);
  }

  function show() {
    if (root || !document.body) return;
    if (!document.getElementById('sejdel-consent-css')) {
      var css = document.createElement('style');
      css.id = 'sejdel-consent-css';
      css.textContent =
        '.sjc{position:fixed;left:20px;bottom:20px;z-index:2147483000;max-width:372px;width:calc(100% - 40px);' +
        'box-sizing:border-box;padding:20px 20px 18px;border-radius:20px;color:#f3e9d8;' +
        'background:linear-gradient(160deg,rgba(29,22,16,.98),rgba(20,15,11,.98));' +
        'border:1px solid rgba(243,233,216,.12);' +
        'box-shadow:0 30px 60px -20px rgba(0,0,0,.7),0 0 0 1px rgba(232,132,60,.08),inset 0 1px 0 rgba(243,233,216,.06);' +
        'font-family:"Hanken Grotesk",system-ui,sans-serif;font-size:14.5px;line-height:1.55;' +
        'transform:translateY(16px);opacity:0;animation:sjcUp .55s cubic-bezier(.2,.7,.2,1) .35s forwards;}' +
        '.sjc.is-leaving{animation:sjcDown .3s ease-in forwards;}' +
        '@keyframes sjcUp{to{transform:none;opacity:1}}' +
        '@keyframes sjcDown{to{transform:translateY(12px);opacity:0}}' +
        '.sjc .k{display:flex;align-items:center;gap:9px;margin:0 0 8px;font-family:ui-monospace,"SF Mono",Menlo,monospace;' +
        'font-size:10.5px;font-weight:700;letter-spacing:.3em;text-transform:uppercase;color:#b3895a;}' +
        '.sjc .k i{width:7px;height:7px;border-radius:50%;background:#e8843c;box-shadow:0 0 0 3px rgba(232,132,60,.18);}' +
        '.sjc h2{margin:0 0 6px;font-family:"Fraunces",Georgia,serif;font-weight:800;font-size:19px;letter-spacing:-.02em;line-height:1.15;color:#f3e9d8;}' +
        '.sjc h2 em{font-style:italic;color:#e8843c;}' +
        '.sjc p{margin:0 0 14px;color:#cdbfa8;}' +
        '.sjc p a{color:#e8843c;text-decoration:none;border-bottom:1px solid rgba(232,132,60,.4);}' +
        '.sjc p a:hover{border-bottom-color:#e8843c;}' +
        '.sjc .b{display:flex;gap:8px;}' +
        '.sjc button{flex:1;appearance:none;cursor:pointer;border-radius:999px;padding:11px 14px;' +
        'font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:11px;font-weight:800;letter-spacing:.18em;text-transform:uppercase;' +
        'transition:transform .15s ease,background-color .15s ease,border-color .15s ease,color .15s ease;}' +
        '.sjc button:active{transform:scale(.97);}' +
        '.sjc button:focus-visible{outline:2px solid #e8843c;outline-offset:3px;}' +
        '.sjc .no{background:transparent;color:#cdbfa8;border:1px solid rgba(243,233,216,.18);}' +
        '.sjc .no:hover{border-color:rgba(243,233,216,.4);color:#f3e9d8;}' +
        '.sjc .yes{background:#e8843c;color:#140f0b;border:1px solid #e8843c;}' +
        '.sjc .yes:hover{background:#f09550;border-color:#f09550;transform:translateY(-1px);}' +
        '@media (max-width:480px){.sjc{left:12px;right:12px;bottom:12px;width:auto;max-width:none;border-radius:18px;}}' +
        '@media (prefers-reduced-motion:reduce){.sjc,.sjc.is-leaving{animation:none;transform:none;opacity:1;}}';
      document.head.appendChild(css);
    }

    root = document.createElement('aside');
    root.className = 'sjc';
    root.setAttribute('role', 'dialog');
    root.setAttribute('aria-label', 'Cookie consent');
    // Reopened from the footer: say what the current answer is.
    var current = saved
      ? '<p>Right now you have <strong style="color:#f3e9d8">' + (saved.accepted ? 'accepted' : 'declined') +
        '</strong> cookies from the services this site loads. Change it here whenever you like. ' +
        '<a href="/cookies/">Cookie policy</a></p>'
      : '<p>sejdel.com sets no tracking cookies of its own. A couple of services the site loads may set theirs, ' +
        'and that part is your call. <a href="/cookies/">Cookie policy</a></p>';
    root.innerHTML =
      '<p class="k"><i aria-hidden="true"></i>Cookies</p>' +
      '<h2>' + (saved ? 'Your <em>choice.</em>' : 'One quick <em>thing.</em>') + '</h2>' +
      current +
      '<div class="b"><button type="button" class="no">Decline</button><button type="button" class="yes">Accept</button></div>';
    root.querySelector('.no').addEventListener('click', function () { decide(false); });
    root.querySelector('.yes').addEventListener('click', function () { decide(true); });
    document.body.appendChild(root);
  }

  // The footer link, and #consent in the address bar (the cookie policy
  // page has no scripts of its own, so it sends people here).
  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a.sejdel-display-preferences, a[href="#consent"]') : null;
    if (!a) return;
    e.preventDefault();
    show();
  });

  function boot() {
    if (location.hash === '#consent') { show(); return; }
    if (!saved) show();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
