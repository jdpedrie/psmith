// settings-b area behavior: profiles, plugins, MCP servers, embedder,
// Langfuse, speech. Shared behavior lives in app.js. Every page here works
// without this file; it keeps edits in place instead of round trips.
(function () {
	"use strict";

	var $ = function (sel, root) { return (root || document).querySelector(sel); };
	var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

	function changed(el) { el.dispatchEvent(new Event("input", { bubbles: true })); }

	// placeRows numbers the plugin rows in list as they now sit, ends the
	// arrows at each end and, when record is set, writes each row's
	// position into the form.
	function placeRows(list, record) {
		var rows = $$("[data-setb-row]", list);
		rows.forEach(function (row, i) {
			var num = $(".sb-num", row);
			if (num) num.textContent = String(i + 1);
			var upB = $('[data-setb-move="up"]', row), downB = $('[data-setb-move="down"]', row);
			if (upB) upB.disabled = i === 0;
			if (downB) downB.disabled = i === rows.length - 1;
			var pos = $('input[name^="ppos_"]', row);
			if (record && pos && pos.value !== String(i)) { pos.value = String(i); changed(pos); }
		});
	}

	// Send traces stays off-limits until there is a public key and a
	// secret, saved or typed, as on the apps; a switch already on can
	// always be turned off.
	function syncLangfuse(form) {
		var row = form && $("[data-lf-switch]", form);
		if (!row) return;
		var sw = $("[role=switch]", row), pk = $("#lfpk", form), sk = $("#lfsk", form);
		var keys = pk && pk.value.trim() !== "" && (row.getAttribute("data-secret-set") === "true" || (sk && sk.value !== ""));
		var locked = !keys && sw.getAttribute("aria-checked") !== "true";
		sw.disabled = locked;
		var subs = $$(".sb-sub", row);
		if (subs.length === 2) { subs[0].hidden = locked; subs[1].hidden = !locked; }
	}

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
		// The arrows move a row in place; the save bar commits the order.
		b = e.target.closest("[data-setb-move]");
		if (b) {
			e.preventDefault();
			var group = b.closest("[data-setb-row]");
			var up = b.getAttribute("data-setb-move") === "up";
			var other = up ? group.previousElementSibling : group.nextElementSibling;
			if (!other || !other.hasAttribute("data-setb-row")) return;
			group.parentElement.insertBefore(up ? group : other, up ? other : group);
			placeRows(group.parentElement, true);
			(b.disabled ? $('[data-setb-move="' + (up ? "down" : "up") + '"]', group) : b).focus();
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
		syncLangfuse(t.form);
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
			var moved = $$("[data-setb-row][data-index]", e.target);
			if (moved.length) {
				var list = moved[0].parentElement;
				moved.sort(function (a, b) { return a.getAttribute("data-index") - b.getAttribute("data-index"); })
					.forEach(function (row) { list.appendChild(row); });
				placeRows(list, false);
			}
			// app.js hides the bar in its own reset timeout, queued after
			// this one; the tests read the bar, so wait for it.
			setTimeout(function () { syncNeedsSaved(e.target); syncLangfuse(e.target); });
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
