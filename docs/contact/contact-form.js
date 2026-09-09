// contact-form.js — make the contact form actually reach us.
//
// The form's own action is `mailto:` with method="post" and a plain-text
// encoding. Browsers handle that badly and inconsistently: Chrome throws an
// interstitial, Safari often opens Mail with a mangled or empty body, and
// several mobile browsers do nothing at all — silently. Someone filing a
// privacy request would watch the page do nothing and reasonably believe the
// request was with us. It never left their machine, so our one-month clock
// never starts, and from their side we ignored them.
//
// So we build the mailto ourselves, with the subject and body filled in from
// the fields, and navigate to it. Then we reveal a line telling the reader
// what to do if their mail app did not open, because that is the one failure
// we cannot detect from here.
//
// Degrades safely: if this file fails to load, the form's original action
// still applies, and contact@sejdel.com is written in plain text three times
// on the page.

(function () {
  'use strict';

  var form = document.querySelector('form.cform');
  if (!form) return;

  var TO = 'contact@sejdel.com';

  function val(name) {
    var el = form.elements[name];
    return el && typeof el.value === 'string' ? el.value.trim() : '';
  }

  form.addEventListener('submit', function (e) {
    // Honeypot. A real person never sees this field, so anything in it is a
    // bot: swallow the submission without telling it why.
    if (val('Company')) {
      e.preventDefault();
      return;
    }

    e.preventDefault();

    var topic = val('Topic') || 'Message from sejdel.com';
    var body = [
      'Name: ' + val('Name'),
      'Email: ' + val('Email'),
      'Topic: ' + topic,
      '',
      val('Message')
    ].join('\r\n');

    var href = 'mailto:' + TO +
      '?subject=' + encodeURIComponent(topic) +
      '&body=' + encodeURIComponent(body);

    var fallback = document.getElementById('mailto-fallback');
    if (fallback) fallback.hidden = false;

    window.location.href = href;
  });
})();
