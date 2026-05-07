/**
 * Onboarding nudge bar — shows a contextual step indicator on pages that are
 * part of the new-user getting-started flow.
 *
 * Call NHSOnboardingNudge.show(config) once the page content is ready.
 *
 * config = {
 *   insertAfterId: string,   // id of element to insert the bar below
 *   step: number,            // this page's step number (1-5)
 *   total: number,           // total steps (default 5)
 *   message: string,         // plain text shown to user
 *   ctaLabel: string,        // optional next-step link text
 *   ctaHref: string,         // optional next-step link URL
 * }
 *
 * The bar is suppressed if the user has dismissed the main getting-started
 * checklist (nhs_gs_dismissed in localStorage).  The dismiss button on the
 * nudge only hides it for the current session (sessionStorage).
 */
(function () {
  var SESSION_HIDE_KEY = 'nhs_onb_nudge_hide';

  function dismissKey() {
    try {
      var uid = window.NHSAuth && NHSAuth.user && (NHSAuth.user.id || NHSAuth.user.email);
      return uid ? 'nhs_gs_dismissed_' + uid : 'nhs_gs_dismissed';
    } catch (e) {
      return 'nhs_gs_dismissed';
    }
  }

  function shouldShow() {
    try {
      if (localStorage.getItem(dismissKey())) return false;
      if (sessionStorage.getItem(SESSION_HIDE_KEY)) return false;
    } catch (e) {}
    return true;
  }

  function show(config) {
    if (!shouldShow()) return;
    var anchor = document.getElementById(config.insertAfterId);
    if (!anchor) return;

    var total = config.total || 5;
    var nudge = document.createElement('div');
    nudge.className = 'onb-nudge';
    nudge.setAttribute('role', 'note');
    nudge.setAttribute('aria-label', 'Getting started — step ' + config.step + ' of ' + total);

    var ctaHtml = config.ctaHref
      ? ' <a class="onb-nudge__cta" href="' + config.ctaHref + '">Next: ' + config.ctaLabel + ' &rsaquo;</a>'
      : '';

    nudge.innerHTML =
      '<span class="onb-nudge__step">Getting started &middot; Step ' + config.step + ' of ' + total + '</span>' +
      '<span class="onb-nudge__msg">' + config.message + ctaHtml + '</span>' +
      '<button type="button" class="onb-nudge__dismiss" aria-label="Hide this hint">&times;</button>';

    anchor.parentNode.insertBefore(nudge, anchor.nextSibling);

    nudge.querySelector('.onb-nudge__dismiss').addEventListener('click', function () {
      try { sessionStorage.setItem(SESSION_HIDE_KEY, '1'); } catch (e) {}
      nudge.remove();
    });
  }

  window.NHSOnboardingNudge = { show: show, shouldShow: shouldShow };
})();
