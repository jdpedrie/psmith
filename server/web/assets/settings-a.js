// settings-a area behavior: General, Appearance, Usage, providers and models,
// users. Shared behavior lives in app.js. Every form here posts without this
// file; it adds live counts, in-place chip editing and instant appearance.
(function () {
	"use strict";

	var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

	function cookie(name) {
		var m = document.cookie.match(new RegExp("(?:^|; )" + name + "=([^;]*)"));
		return m ? decodeURIComponent(m[1]) : "";
	}

	// --- save bar ------------------------------------------------------------
	// app.js counts text fields; radios and checkboxes count here too, and a
	// changed field wears the accent ring. Runs after app.js, so its label wins.
	$$(".seta [data-savebar]").forEach(function (bar) {
		var form = bar.closest("form");
		if (!form) return;
		var snapshot = function () {
			return $$("input, select, textarea", form).filter(function (el) { return el.name && el.type !== "file"; })
				.map(function (el) { return { el: el, v: el.type === "checkbox" || el.type === "radio" ? el.checked : el.value }; });
		};
		var initial = snapshot();
		var count = function () {
			var groups = {}, n = 0;
			initial.forEach(function (s) {
				var now = s.el.type === "checkbox" || s.el.type === "radio" ? s.el.checked : s.el.value;
				var changed = now !== s.v && s.el.isConnected;
				if (s.el.type === "radio") {
					if (changed) groups[s.el.name] = true;
					return;
				}
				if (s.el.name === "stop") return;
				if (s.el.type !== "hidden" && s.el.type !== "checkbox") s.el.classList.toggle("is-changed", changed);
				if (changed) n++;
			});
			n += Object.keys(groups).length;
			var stopsNow = $$('input[name="stop"]', form).map(function (i) { return i.value; }).join("\n");
			var stopsThen = initial.filter(function (s) { return s.el.name === "stop"; }).map(function (s) { return s.v; }).join("\n");
			if (stopsNow !== stopsThen) n++;
			n = Math.max(n, parseInt(bar.getAttribute("data-initial") || "0", 10));
			bar.hidden = n === 0;
			var label = bar.querySelector("[data-dirty-count]");
			if (label) label.textContent = n === 1 ? "1 unsaved change" : n + " unsaved changes";
		};
		form.addEventListener("input", count);
		form.addEventListener("change", count);
		form.addEventListener("seta:changed", count);
		form.addEventListener("reset", function () { setTimeout(count, 1); });
	});

	// --- reset a field to not set --------------------------------------------
	document.addEventListener("click", function (e) {
		var b = e.target.closest("[data-reset]");
		if (b) {
			var form = b.closest("form"), name = b.getAttribute("data-reset");
			$$('[name="' + name + '"]', form).forEach(function (el) {
				if (el.type === "radio") el.checked = el.value === "";
				else el.value = "";
			});
			form.dispatchEvent(new Event("change", { bubbles: true }));
			return;
		}
		b = e.target.closest("[data-stop-remove]");
		if (b) {
			var f = b.closest("form");
			b.closest(".stopchip").remove();
			f.dispatchEvent(new Event("seta:changed"));
			return;
		}
		// A radio group of buttons shows the choice at once; the post follows.
		b = e.target.closest("[data-radios] [role=radio]");
		if (b) {
			$$("[role=radio]", b.closest("[data-radios]")).forEach(function (r) { r.setAttribute("aria-checked", String(r === b)); });
		}
	});

	// --- stop sequences --------------------------------------------------------
	document.addEventListener("keydown", function (e) {
		var input = e.target.closest && e.target.closest("[data-stop-add]");
		if (input && e.key === "Enter") {
			e.preventDefault();
			var v = input.value;
			if (!v) return;
			var chip = document.createElement("span");
			chip.className = "stopchip";
			chip.appendChild(document.createTextNode(v));
			var hidden = document.createElement("input");
			hidden.type = "hidden"; hidden.name = "stop"; hidden.value = v;
			chip.appendChild(hidden);
			var x = document.createElement("button");
			x.type = "button"; x.setAttribute("data-stop-remove", ""); x.setAttribute("aria-label", "Remove stop sequence " + v);
			x.innerHTML = '<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><path d="M2 2l6 6M8 2l-6 6"></path></svg>';
			chip.appendChild(x);
			input.parentNode.insertBefore(chip, input);
			input.value = "";
			input.closest("form").dispatchEvent(new Event("seta:changed"));
			return;
		}
		// Cmd/Ctrl+Return submits a page whose primary button shows ⌘↵.
		if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
			var form = e.target.closest && e.target.closest(".seta form, form.seta");
			if (!form) form = document.querySelector("form.seta, .seta form");
			if (form && /⌘↵/.test(form.textContent)) { e.preventDefault(); form.requestSubmit(); }
		}
	});

	// --- fields that show with a choice ----------------------------------------
	function syncWhen() {
		$$("[data-when]").forEach(function (box) {
			var kv = box.getAttribute("data-when").split("=");
			var form = box.closest("form");
			var on = form && form.querySelector('input[name="' + kv[0] + '"]:checked');
			box.hidden = !(on && on.value === kv[1]);
		});
	}
	document.addEventListener("change", function (e) {
		syncWhen();
		var el = e.target;
		// Custom… waits for its number before saving.
		var toggle = el.getAttribute && el.getAttribute("data-custom-toggle");
		if (toggle) {
			var box = document.querySelector(toggle);
			if (box) box.hidden = el.value !== "custom";
			if (el.value === "custom") { var n = box && box.querySelector("input"); if (n) n.focus(); return; }
		}
		var form = el.closest && el.closest("form[data-autosubmit]");
		if (form && el.name !== "custom") form.requestSubmit();
	});

	// --- text size: the readout and fill follow the thumb ------------------------
	$$("[data-text-size]").forEach(function (r) {
		r.addEventListener("input", function () {
			var box = r.closest(".tsize");
			box.style.setProperty("--pct", ((r.value - 80) * 100 / 80) + "%");
			var out = box.querySelector("output");
			if (out) out.textContent = r.value + "%";
		});
	});

	// --- discover: how many new models are picked ---------------------------------
	$$("form[data-select-count]").forEach(function (form) {
		var label = form.querySelector("[data-sel-label]");
		if (!label) return;
		var total = label.getAttribute("data-total");
		form.addEventListener("change", function () {
			var n = $$('input[name="model_ids"]:checked', form).length;
			label.textContent = n + " of " + total + " new " + (total === "1" ? "model" : "models") + " selected";
		});
	});
})();
