// inspector area behavior: the Settings tab's inherit labels, the model
// picker's filter and arrow keys, the compression cards' keys and stream,
// and the inspector as a page on narrow screens. Every control works without
// this file; it only makes them quicker. Shared behavior lives in app.js.
(function () {
	"use strict";

	var $ = function (sel, root) { return (root || document).querySelector(sel); };
	var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

	// --- Settings tab: a row says whether it is set here, and what it inherits.
	function syncRow(row) {
		var input = $(".set-in", row);
		if (!input) return;
		var sub = $(".set-lbl > span", row);
		var set = input.value !== "";
		var changed = input.tagName === "SELECT" ? !input.options[input.selectedIndex].defaultSelected : input.value !== input.defaultValue;
		row.classList.toggle("set", set);
		input.classList.toggle("dirty", changed);
		if (!sub) return;
		if (!set) { sub.textContent = row.getAttribute("data-from") || ""; return; }
		var inh = row.getAttribute("data-inherits");
		sub.textContent = "Set here" + (changed ? ", unsaved" : "") + (inh ? ". Inherits " + inh : "");
	}
	document.addEventListener("input", function (e) {
		var row = e.target.closest && e.target.closest("[data-set-row]");
		if (row) syncRow(row);
	});
	document.addEventListener("change", function (e) {
		var row = e.target.closest && e.target.closest("[data-set-row]");
		if (row) syncRow(row);
		if (e.target.matches && e.target.matches("select[data-fit]")) fit(e.target);
	});
	document.addEventListener("reset", function (e) {
		setTimeout(function () { $$("[data-set-row]", e.target).forEach(syncRow); });
	});
	document.addEventListener("click", function (e) {
		var b = e.target.closest("[data-reset]");
		if (b) {
			var input = document.getElementById(b.getAttribute("data-reset"));
			if (input) {
				input.value = "";
				input.dispatchEvent(new Event("input", { bubbles: true }));
				input.dispatchEvent(new Event("change", { bubbles: true }));
			}
			return;
		}
		b = e.target.closest("[data-unclamp]");
		if (b) {
			var text = b.parentElement.querySelector("[data-clamp]");
			if (text) text.removeAttribute("data-clamp");
			b.hidden = true;
		}
	});

	// --- Compression: whether the context fits the chosen model's window.
	function commas(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ","); }
	function abbrev(n) {
		if (n >= 1e6) return (n % 1e6 ? (n / 1e6).toFixed(1) : n / 1e6) + "M";
		if (n >= 1e3) return Math.floor(n / 1e3) + "k";
		return String(n);
	}
	function fit(sel) {
		var form = sel.closest("[data-tokens]");
		var label = form && $("[data-fit-label]", form);
		var opt = sel.options[sel.selectedIndex];
		if (!label || !opt) return;
		var tokens = parseInt(form.getAttribute("data-tokens"), 10) || 0;
		var win = parseInt(opt.getAttribute("data-window"), 10) || 0;
		var ok = win === 0 || tokens <= win;
		label.classList.toggle("bad", !ok);
		label.lastElementChild.textContent = win === 0 ? "Window unknown" : ok ? "Fits its " + abbrev(win) + " window" : commas(tokens) + " of a " + commas(win) + " window";
	}

	// The summary stream says where to go when it ends: the conversation,
	// which then shows the review or the failure.
	document.body.addEventListener("htmx:sseMessage", function (e) {
		var el = e.target.closest && e.target.closest("[data-compact-stream]");
		if (el && e.detail && e.detail.type === "done" && e.detail.data) location.href = e.detail.data;
	});

	// --- keys for the cards in the composer's place and the contexts rename.
	document.addEventListener("keydown", function (e) {
		if (e.defaultPrevented || e.isComposing) return;
		var mod = e.metaKey || e.ctrlKey;
		if (mod && e.key === "Enter") {
			var f = e.target.closest && e.target.closest("form[data-cmd-enter]") || $("#composer-slot form[data-cmd-enter]");
			if (f) { e.preventDefault(); f.requestSubmit(); }
			return;
		}
		if (mod && e.key === "s") {
			var b = $("[data-cmd-s]");
			if (b) { e.preventDefault(); b.closest("form").requestSubmit(); }
			return;
		}
		if (e.key === "Escape") {
			var stop = $("#composer-slot [data-esc]");
			if (stop) { e.preventDefault(); stop.click(); return; }
			var away = e.target.closest && e.target.closest("[data-esc-href]") || $("#composer-slot [data-esc-href]");
			if (away) { e.preventDefault(); location.href = away.getAttribute("data-esc-href"); }
		}
	});

	// --- model picker: filter as you type, arrows move, Enter picks.
	var filter = $("[data-pick-filter]");
	if (filter) {
		var rows = function () { return $$(".pick-body .pick-row").filter(function (r) { return !r.hidden && !r.disabled; }); };
		filter.addEventListener("input", function () {
			var q = filter.value.trim().toLowerCase();
			$$(".pick-group").forEach(function (g) {
				var any = false;
				$$(".pick-row", g).forEach(function (r) {
					var hit = q === "" || (r.getAttribute("data-pick-name") || "").toLowerCase().indexOf(q) >= 0 || g.getAttribute("aria-label").toLowerCase().indexOf(q) >= 0;
					r.hidden = !hit;
					any = any || hit;
				});
				g.hidden = !any;
			});
		});
		var move = function (from, step) {
			var all = rows(), i = all.indexOf(from);
			var next = all[Math.max(0, Math.min(all.length - 1, i + step))];
			if (next) next.focus();
		};
		filter.addEventListener("keydown", function (e) {
			if (e.key === "ArrowDown") { e.preventDefault(); move(null, 1); }
			if (e.key === "Escape") {
				e.preventDefault();
				if (filter.value !== "") {
					filter.value = "";
					filter.dispatchEvent(new Event("input", { bubbles: true }));
				} else {
					location.href = "/c/" + $("#main").getAttribute("data-conv");
				}
			}
			if (e.key === "Enter") {
				e.preventDefault();
				var first = rows().filter(function (r) { return r.getAttribute("data-pick-name"); })[0];
				if (first) first.click();
			}
		});
		$(".pick-body").addEventListener("keydown", function (e) {
			var r = e.target.closest(".pick-row");
			if (!r) return;
			if (e.key === "ArrowDown") { e.preventDefault(); move(r, 1); }
			if (e.key === "ArrowUp") {
				e.preventDefault();
				if (rows().indexOf(r) === 0) filter.focus(); else move(r, -1);
			}
			if (e.key === "Escape") { e.preventDefault(); location.href = "/c/" + $("#main").getAttribute("data-conv"); }
		});
	}

	// --- below 1180px the inspector is a page of its own.
	window.addEventListener("click", function (e) {
		var b = e.target.closest && e.target.closest("[data-toggle-inspector]");
		if (!b || window.innerWidth >= 1180) return;
		var main = $("#main");
		if (!main) return;
		e.preventDefault();
		e.stopPropagation();
		location.href = "/c/" + main.getAttribute("data-conv") + "?tab=context";
	}, true);
})();
