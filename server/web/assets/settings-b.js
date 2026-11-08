// settings-b area behavior: profiles, plugins, MCP servers, embedder,
// Langfuse, speech. Shared behavior lives in app.js. Every page here works
// without this file; it keeps edits in place instead of round trips.
(function () {
	"use strict";

	var $ = function (sel, root) { return (root || document).querySelector(sel); };
	var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

	function changed(el) { el.dispatchEvent(new Event("input", { bubbles: true })); }

	document.addEventListener("click", function (e) {
		var b = e.target.closest("[data-setb-clear]");
		if (b) {
			var input = document.getElementById(b.getAttribute("data-setb-clear"));
			if (input) { input.value = ""; changed(input); input.focus(); }
			b.hidden = true;
			return;
		}
		// Configure opens the plugin's settings under its row.
		b = e.target.closest("[data-setb-disclose]");
		if (b) {
			e.preventDefault();
			var open = b.getAttribute("aria-expanded") !== "true";
			b.setAttribute("aria-expanded", String(open));
			var panel = document.getElementById(b.getAttribute("aria-controls"));
			if (panel) panel.hidden = !open;
			return;
		}
		// Remove marks the row; the save bar commits it with everything else.
		b = e.target.closest("[data-setb-remove]");
		if (b) {
			e.preventDefault();
			var row = b.closest("[data-setb-row]");
			var mark = b.form && b.form.querySelector('input[name="' + b.getAttribute("data-setb-remove") + '"]');
			if (!row || !mark) return;
			var removed = mark.value !== "true";
			mark.value = removed ? "true" : "";
			row.toggleAttribute("data-removed", removed);
			b.setAttribute("aria-pressed", String(removed));
			changed(mark);
			return;
		}
		b = e.target.closest("[data-setb-reveal]");
		if (b) {
			var field = document.getElementById(b.getAttribute("data-setb-reveal"));
			if (!field) return;
			var show = field.type === "password";
			field.type = show ? "text" : "password";
			b.textContent = show ? "Hide" : "Show";
			return;
		}
		// Replace swaps a stored secret's mask for an input.
		b = e.target.closest("[data-setb-replace]");
		if (b) {
			e.preventDefault();
			var holder = b.closest("[data-setb-secret]");
			var key = document.getElementById(b.getAttribute("data-setb-replace"));
			if (!holder || !key) return;
			$$(".sb-val, .btn", holder).forEach(function (el) { el.hidden = true; });
			key.hidden = false;
			key.focus();
			return;
		}
		b = e.target.closest("[data-needs-saved][aria-disabled=true]");
		if (b) e.preventDefault();
	});

	document.addEventListener("change", function (e) {
		if (e.target.matches("[data-setb-autosubmit]") && e.target.files && e.target.files.length) {
			e.target.form.requestSubmit();
		}
	});

	document.addEventListener("input", function (e) {
		var t = e.target;
		if (t.matches("[data-setb-output]")) {
			var out = document.getElementById(t.getAttribute("data-setb-output"));
			if (out) out.textContent = Number(t.value).toFixed(1) + "×";
		}
		if (t.matches("[data-count]")) {
			var c = document.getElementById(t.getAttribute("data-count"));
			var n = Array.from(t.value).length;
			if (c) c.textContent = n === 1 ? "1 character" : n + " characters";
		}
		if (t.id && t.hasAttribute("data-orig")) {
			var dirty = t.value !== t.getAttribute("data-orig");
			t.classList.toggle("sb-dirty", dirty);
			$$('[data-changed-for="' + t.id + '"]').forEach(function (h) { h.hidden = !dirty; });
		}
		syncNeedsSaved(t.form);
	});
	document.addEventListener("change", function (e) { syncNeedsSaved(e.target.form); });
	document.addEventListener("reset", function (e) {
		setTimeout(function () {
			$$("[data-orig]", e.target).forEach(function (el) {
				el.classList.remove("sb-dirty");
				if (el.id) $$('[data-changed-for="' + el.id + '"]').forEach(function (h) { h.hidden = true; });
			});
			// Hidden inputs keep script-set values through a reset.
			$$("[data-setb-row][data-removed]", e.target).forEach(function (r) { r.removeAttribute("data-removed"); });
			$$('input[name^="premoved_"]', e.target).forEach(function (m) { m.value = ""; });
			syncNeedsSaved(e.target);
		});
	}, true);

	// A test runs against what is saved, so it waits while the form is dirty.
	function syncNeedsSaved(form) {
		if (!form) return;
		var bar = $("[data-savebar]", form);
		if (!bar) return;
		var dirty = !bar.hidden;
		$$("[data-needs-saved]", form).forEach(function (b) {
			if (dirty) b.setAttribute("aria-disabled", "true"); else b.removeAttribute("aria-disabled");
		});
		$$("[data-needs-saved-note]", form).forEach(function (n) { n.hidden = !dirty; });
	}

	// Cmd/Ctrl+S submits a create form's bar, which is always showing.
	document.addEventListener("keydown", function (e) {
		if ((e.metaKey || e.ctrlKey) && e.key === "s") {
			var bar = $("[data-setb-submitbar]");
			if (bar && !$("[data-savebar]:not([hidden])")) {
				e.preventDefault();
				bar.closest("form").requestSubmit();
			}
		}
	});
})();
