// tm-control-mcp site: mood toggle, checkpoint trace, copy buttons, JSON tint,
// latest-version.txt readout. No dependencies; everything degrades without JS.
(function () {
  "use strict";
  var root = document.documentElement;
  var announcer = document.querySelector("[data-announce]");
  function announce(msg) {
    if (!announcer) return;
    announcer.textContent = "";
    setTimeout(function () { announcer.textContent = msg; }, 30);
  }

  /* ---- Mood (Day / Night theme) ---- */
  var moodBtn = document.querySelector("[data-mood-toggle]");
  function syncMood() {
    var m = root.getAttribute("data-mood") === "day" ? "day" : "night";
    if (!moodBtn) return;
    moodBtn.querySelector("[data-mood-name]").textContent = m === "day" ? "Day" : "Night";
    moodBtn.setAttribute("aria-pressed", m === "day" ? "true" : "false");
    moodBtn.setAttribute("aria-label", "Mood: " + (m === "day" ? "Day" : "Night") + ". Switch to " + (m === "day" ? "Night" : "Day"));
  }
  if (moodBtn) {
    moodBtn.hidden = false;
    moodBtn.addEventListener("click", function () {
      var next = root.getAttribute("data-mood") === "day" ? "night" : "day";
      root.setAttribute("data-mood", next);
      try { localStorage.setItem("tmcm-mood", next); } catch (e) {}
      syncMood();
    });
    syncMood();
  }

  /* ---- JSON tint (display only; text content unchanged) ---- */
  var TOKEN = /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?)|\b(true|false|null)\b|([{}\[\],:])/g;
  function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  Array.prototype.forEach.call(document.querySelectorAll("[data-json]"), function (el) {
    var src = el.textContent, out = "", last = 0, m;
    TOKEN.lastIndex = 0;
    while ((m = TOKEN.exec(src))) {
      out += esc(src.slice(last, m.index));
      if (m[1]) out += m[2] ? '<span class="j-key">' + esc(m[1]) + '</span><span class="j-pun">' + m[2] + "</span>"
                            : '<span class="j-str">' + esc(m[1]) + "</span>";
      else if (m[3]) out += '<span class="j-num">' + m[3] + "</span>";
      else if (m[4]) out += '<span class="j-lit">' + m[4] + "</span>";
      else out += '<span class="j-pun">' + esc(m[5]) + "</span>" + (m[5] === "," ? "<wbr>" : "");
      last = TOKEN.lastIndex;
    }
    el.innerHTML = out + esc(src.slice(last));
  });

  /* ---- Copy buttons ---- */
  var COPY_ICON = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="12" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3" fill="none" stroke="currentColor" stroke-width="2"/></svg>';
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    return new Promise(function (resolve, reject) {
      var ta = document.createElement("textarea");
      ta.value = text; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
      document.body.appendChild(ta); ta.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
      ok ? resolve() : reject(new Error("copy failed"));
    });
  }
  function addCopy(container, getText, label) {
    var b = document.createElement("button");
    b.type = "button"; b.className = "copy";
    b.innerHTML = COPY_ICON + "<span>Copy</span>";
    b.setAttribute("aria-label", "Copy " + label);
    b.addEventListener("click", function () {
      copyText(getText()).then(function () {
        b.classList.add("is-done"); b.lastChild.textContent = "Copied";
        announce("Copied " + label + " to clipboard");
        setTimeout(function () { b.classList.remove("is-done"); b.lastChild.textContent = "Copy"; }, 1600);
      }, function () {
        b.lastChild.textContent = "Select text";
        announce("Copy failed. Select the text manually.");
        setTimeout(function () { b.lastChild.textContent = "Copy"; }, 2000);
      });
    });
    container.appendChild(b);
  }
  Array.prototype.forEach.call(document.querySelectorAll(".code--copy"), function (box) {
    var pre = box.querySelector("pre");
    var label = box.querySelector(".code__label");
    addCopy(box, function () { return pre.textContent; }, label ? label.textContent.trim() : "command");
  });
  Array.prototype.forEach.call(document.querySelectorAll(".wire__cmd"), function (pre) {
    pre.style.paddingRight = "92px";
    var holder = document.createElement("div");
    holder.className = "copy-wrap";
    pre.parentNode.insertBefore(holder, pre);
    holder.appendChild(pre);
    addCopy(holder, function () { return pre.textContent; }, "command");
  });

  /* ---- Checkpoint trace (ARIA tabs) ---- */
  var trace = document.querySelector("[data-trace]");
  if (trace) {
    var steps = Array.prototype.slice.call(trace.querySelectorAll(".step"));
    var tablist = trace.querySelector("[data-trace-tabs]");
    var track = trace.querySelector("[data-trace-track]");
    var nav = trace.querySelector("[data-trace-nav]");
    var line = trace.querySelector(".trace__line");
    var car = trace.querySelector("[data-trace-car]");
    var count = trace.querySelector("[data-trace-count]");
    var prev = trace.querySelector("[data-trace-prev]");
    var next = trace.querySelector("[data-trace-next]");
    var gates = [];
    var current = 0;

    steps.forEach(function (step, i) {
      var gate = step.getAttribute("data-gate");
      var id = "step-" + i;
      step.id = id;
      step.setAttribute("role", "tabpanel");
      step.setAttribute("aria-labelledby", "gate-" + i);
      var b = document.createElement("button");
      b.type = "button"; b.id = "gate-" + i;
      b.className = "gate" + (i === 0 || i === steps.length - 1 ? " gate--end" : "");
      b.setAttribute("role", "tab");
      b.setAttribute("aria-controls", id);
      b.setAttribute("aria-label", gate + ": " + step.getAttribute("data-label"));
      b.innerHTML = '<span class="gate__post" aria-hidden="true"></span><span aria-hidden="true">' + gate + "</span>";
      b.addEventListener("click", function () { select(i, false); });
      b.addEventListener("keydown", function (e) {
        var k = e.key, to = null;
        if (k === "ArrowRight" || k === "ArrowDown") to = (i + 1) % steps.length;
        else if (k === "ArrowLeft" || k === "ArrowUp") to = (i - 1 + steps.length) % steps.length;
        else if (k === "Home") to = 0;
        else if (k === "End") to = steps.length - 1;
        if (to !== null) { e.preventDefault(); select(to, true); }
      });
      tablist.appendChild(b);
      gates.push(b);
    });

    function layout() {
      var first = gates[0].querySelector(".gate__post");
      var last = gates[gates.length - 1].querySelector(".gate__post");
      var sel = gates[current].querySelector(".gate__post");
      var base = track.getBoundingClientRect();
      function cx(el) { var r = el.getBoundingClientRect(); return r.left + r.width / 2 - base.left; }
      var r0 = first.getBoundingClientRect();
      var y = r0.top + r0.height / 2 - base.top - 2;
      line.style.left = cx(first) + "px";
      line.style.width = (cx(last) - cx(first)) + "px";
      line.style.right = "auto";
      line.style.top = y + "px";
      car.style.left = cx(first) + "px";
      car.style.top = y + "px";
      car.style.width = Math.max(0, cx(sel) - cx(first)) + "px";
    }

    function select(i, focus) {
      current = i;
      steps.forEach(function (s, j) { s.hidden = j !== i; });
      gates.forEach(function (g, j) {
        var on = j === i;
        g.setAttribute("aria-selected", on ? "true" : "false");
        g.tabIndex = on ? 0 : -1;
        g.classList.toggle("is-passed", j < i);
      });
      var gate = steps[i].getAttribute("data-gate");
      var cp = gate.indexOf("CP") === 0 ? gate.replace("CP", "CP ") + " / " + (steps.length - 2) : gate;
      count.textContent = cp;
      prev.disabled = i === 0;
      next.disabled = i === steps.length - 1;
      if (focus) gates[i].focus();
      layout();
    }

    prev.addEventListener("click", function () { if (current > 0) select(current - 1, false); });
    next.addEventListener("click", function () { if (current < steps.length - 1) select(current + 1, false); });
    track.hidden = false;
    nav.hidden = false;
    select(0, false);
    window.addEventListener("resize", layout);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(layout);
  }

  /* ---- Latest version from ./latest-version.txt (same deployment) ---- */
  var STABLE = /^v?(\d+\.\d+\.\d+)$/;
  var fileOut = document.querySelector("[data-latest-file]");
  function noVersion(reason) {
    if (fileOut) { fileOut.textContent = reason; fileOut.classList.add("is-missing"); }
  }
  if (window.fetch && location.protocol !== "file:") {
    fetch("latest-version.txt", { cache: "no-cache" }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.text();
    }).then(function (text) {
      var m = STABLE.exec(text.trim());
      if (!m) throw new Error("unrecognised");
      var v = m[1];
      Array.prototype.forEach.call(document.querySelectorAll("[data-version-chip]"), function (chip) {
        chip.innerHTML = "<span>Latest release</span> <code>v" + v + "</code>";
        chip.setAttribute("aria-label", "Latest release v" + v + " on GitHub");
      });
      Array.prototype.forEach.call(document.querySelectorAll("[data-latest-version]"), function (el) { el.textContent = v; });
      if (fileOut) { fileOut.textContent = text.trim(); fileOut.classList.remove("is-missing"); }
    }).catch(function () { noVersion("unavailable here; see Releases"); });
  } else {
    noVersion("served with the deployed site");
  }
})();
