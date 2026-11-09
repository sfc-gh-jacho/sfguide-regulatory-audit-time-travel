(function () {
  "use strict";

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // ── SQL blocks: split sql/reg_audit_time_travel.sql on "-- [step:<id>]" markers ──
  function splitSteps(sql) {
    var steps = {};
    var parts = sql.split(/^-- \[step:([a-z_-]+)\]\s*$/m);
    for (var i = 1; i < parts.length; i += 2) steps[parts[i]] = parts[i + 1].trim();
    return steps;
  }

  function renderCode(el, code) {
    el.innerHTML =
      '<div class="code-bar"><span class="code-lang">SQL</span>' +
      '<button class="copy-btn" type="button">Copy</button></div>' +
      '<pre class="language-sql"><code class="language-sql"></code></pre>';
    var codeEl = el.querySelector("code");
    codeEl.textContent = code;
    if (window.Prism) Prism.highlightElement(codeEl);
    el.querySelector(".copy-btn").addEventListener("click", function () {
      var btn = this;
      copyText(code).then(function () {
        btn.textContent = "Copied!";
        btn.classList.add("copied");
        setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1800);
      });
    });
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
    return Promise.resolve();
  }

  var loadErr = '<div class="code-loading">Could not load content. If you opened this file directly, serve the folder over HTTP (e.g. <code>python3 -m http.server</code>).</div>';

  fetch("sql/reg_audit_time_travel.sql")
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
    .then(function (sql) {
      var steps = splitSteps(sql);
      document.querySelectorAll(".code-wrap[data-step]").forEach(function (el) {
        var code = steps[el.getAttribute("data-step")];
        if (code) renderCode(el, code);
      });
    })
    .catch(function () {
      document.querySelectorAll(".code-wrap[data-step]").forEach(function (el) { el.innerHTML = loadErr; });
    });

  // ── Result tables from data/sample_results.json ──
  function usd(v) {
    if (v === null || v === undefined) return '<span class="null">—</span>';
    return "$" + Number(v).toLocaleString(undefined, { maximumFractionDigits: 0 });
  }
  function usdM(v) { return "$" + (v / 1e6).toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + "M"; }
  function delta(v, fmt, invert) {
    if (!v) return '<span class="num">0</span>';
    var up = v > 0;
    var cls = (invert ? !up : up) ? "delta-up" : "delta-down";
    return '<span class="' + cls + '">' + (up ? "+" : "−") + fmt(Math.abs(v)) + "</span>";
  }
  function wrap(head, body) {
    return '<div class="table-scroll"><table class="results-table"><thead><tr>' + head +
           "</tr></thead><tbody>" + body + "</tbody></table></div>";
  }
  function th(list) { return list.map(function (c) { return "<th>" + esc(c) + "</th>"; }).join(""); }
  function chg(t) { return '<span class="chg chg-' + t.toLowerCase() + '">' + esc(t) + "</span>"; }

  var render = {
    report: function (d) {
      var body = d.report.map(function (r) {
        var dr = r.ratio_now - r.ratio_filed;
        return "<tr" + (r.rwa_change ? ' class="flag"' : "") + '><td class="col-name">' + esc(r.legal_entity) + "</td>" +
          '<td class="num before">' + usdM(r.rwa_filed) + '</td><td class="num">' + usdM(r.rwa_now) + "</td>" +
          '<td class="num">' + delta(r.rwa_change, usdM) + "</td>" +
          '<td class="num before">' + r.ratio_filed.toFixed(2) + '%</td><td class="num">' + r.ratio_now.toFixed(2) + "%</td>" +
          '<td class="num">' + delta(Math.round(dr * 100) / 100, function (x) { return x.toFixed(2) + " pts"; }, true) + "</td></tr>";
      }).join("");
      return wrap(th(["Legal entity", "RWA as filed", "RWA now", "Change", "Tier 1 ratio as filed", "Ratio now", "Change"]), body);
    },
    versions: function (d) {
      var body = d.versions.map(function (v) {
        return "<tr><td>" + esc(v.version) + '</td><td class="num">' + v.positions.toLocaleString() +
               '</td><td class="num">' + usd(v.total_notional) + "</td></tr>";
      }).join("");
      return wrap(th(["Version", "Positions", "Total notional"]), body);
    },
    stream: function (d) {
      var body = d.stream.map(function (s) {
        return '<tr><td class="num">' + s.position_id + '</td><td class="num">' + usd(s.notional_usd) +
               '</td><td class="col-name">' + esc(s.action) + '</td><td class="col-name">' + (s.is_update ? "TRUE" : "FALSE") + "</td></tr>";
      }).join("");
      return wrap(th(["POSITION_ID", "NOTIONAL_USD", "METADATA$ACTION", "METADATA$ISUPDATE"]), body);
    },
    audit_log: function (d) {
      var body = d.audit_log.map(function (a) {
        return '<tr><td class="num">' + a.position_id + "</td><td>" + chg(a.change_type) + '</td><td class="col-name">' +
               esc(a.legal_entity) + '</td><td class="num before">' + usd(a.old_notional) + '</td><td class="num">' + usd(a.new_notional) + "</td></tr>";
      }).join("");
      return wrap(th(["Position", "Change", "Legal entity", "Old notional", "New notional"]), body);
    },
    who: function (d) {
      var body = d.who.map(function (w) {
        return '<tr><td class="num">' + esc(w.time) + '</td><td class="col-name">' + esc(w.user) + '</td><td class="col-name">' +
               esc(w.role) + "</td><td>" + chg(w.type) + '</td><td class="val">' + esc(w.statement) + "</td></tr>";
      }).join("");
      return wrap(th(["Time", "User", "Role", "Type", "Statement"]), body);
    },
    undrop: function (d) {
      var u = d.undrop;
      return wrap(th(["Moment", "Positions visible"]),
        '<tr><td>Before DROP TABLE</td><td class="num">' + u.positions_before_drop.toLocaleString() + "</td></tr>" +
        '<tr class="flag"><td>After DROP TABLE</td><td class="bad">Table does not exist</td></tr>' +
        '<tr><td>After UNDROP TABLE</td><td class="num full">' + u.positions_after_undrop.toLocaleString() + "</td></tr>" +
        '<tr><td>As-filed Time Travel query after UNDROP</td><td class="num full">' + u.positions_as_filed_after_undrop.toLocaleString() + "</td></tr>");
    }
  };

  fetch("data/sample_results.json")
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (d) {
      document.querySelectorAll(".results[data-results]").forEach(function (el) {
        var fn = render[el.getAttribute("data-results")];
        if (fn) el.innerHTML = fn(d);
      });
    })
    .catch(function () {
      document.querySelectorAll(".results[data-results]").forEach(function (el) { el.innerHTML = loadErr; });
    });

  // ── Mobile Nav ──
  var btn = document.querySelector(".nav-hamburger");
  var links = document.querySelector(".nav-links");
  btn.addEventListener("click", function () {
    var open = links.classList.toggle("open");
    btn.classList.toggle("open", open);
    btn.setAttribute("aria-expanded", String(open));
  });
  links.querySelectorAll("a").forEach(function (a) {
    a.addEventListener("click", function () {
      links.classList.remove("open");
      btn.classList.remove("open");
      btn.setAttribute("aria-expanded", "false");
    });
  });

  // ── Nav Scroll Shadow ──
  var nav = document.getElementById("navbar");
  window.addEventListener("scroll", function () {
    nav.classList.toggle("scrolled", window.scrollY > 10);
  }, { passive: true });

  // ── Reveal on Scroll ──
  if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches && "IntersectionObserver" in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("visible"); observer.unobserve(e.target); }
      });
    }, { threshold: 0.08, rootMargin: "0px 0px -40px 0px" });
    document.querySelectorAll(".reveal").forEach(function (el) { observer.observe(el); });
  } else {
    document.querySelectorAll(".reveal").forEach(function (el) { el.classList.add("visible"); });
  }
})();
