/*
 * step-controller.js
 *
 * Drives step-by-step reveal of SVG groups on each slide that has
 * .diagram[data-steps]. Hooks reveal.js fragment events. No animation
 * is performed here — CSS handles fades; SMIL inside SVG handles motion.
 *
 * Each animated SVG contains:
 *   <g class="step" data-step="1">...</g>
 *   <g class="step" data-step="2">...</g>
 *   ...
 *
 * On slide entry we set step 1 active. Each fragment-shown event
 * activates the next step. Each fragment-hidden reverses.
 *
 * Reduced-motion mode short-circuits: all steps are forced on at slide entry.
 */

(function () {
  function setStep(svg, n) {
    var steps = svg.querySelectorAll('.step');
    steps.forEach(function (s) {
      var k = parseInt(s.getAttribute('data-step') || '0', 10);
      if (k <= n) s.classList.add('on');
      else s.classList.remove('on');
    });
    // Re-trigger SMIL <animateMotion>/<animate> elements whose begin attribute
    // references a step class change. We bump 'beginElement' on any element
    // tagged data-trigger-on-step matching n.
    svg.querySelectorAll('[data-trigger-on-step="' + n + '"]').forEach(function (el) {
      if (typeof el.beginElement === 'function') {
        try { el.beginElement(); } catch (e) { /* ignore */ }
      }
    });
  }

  function maxStep(svg) {
    var m = 0;
    svg.querySelectorAll('.step').forEach(function (s) {
      var k = parseInt(s.getAttribute('data-step') || '0', 10);
      if (k > m) m = k;
    });
    return m;
  }

  function currentStepOnSlide(slide) {
    // Count visible fragments + 1 (slide-entry counts as step 1).
    var visible = slide.querySelectorAll('.fragment.visible').length;
    return 1 + visible;
  }

  function syncSlide(slide) {
    var svg = slide.querySelector('svg.diagram[data-steps]');
    if (!svg) return;
    var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) {
      setStep(svg, maxStep(svg));
      return;
    }
    setStep(svg, currentStepOnSlide(slide));
  }

  function init(Reveal) {
    Reveal.on('ready', function () { syncSlide(Reveal.getCurrentSlide()); });
    Reveal.on('slidechanged', function (e) { syncSlide(e.currentSlide); });
    Reveal.on('fragmentshown', function (e) { syncSlide(Reveal.getCurrentSlide()); });
    Reveal.on('fragmenthidden', function (e) { syncSlide(Reveal.getCurrentSlide()); });
  }

  if (typeof window !== 'undefined') {
    window.StepController = { init: init };
  }
})();
