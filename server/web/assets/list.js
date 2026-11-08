// The list area's behavior on top of app.js: row menus, rename and select
// keys, search-result keys, the offline countdown, the appearance switch,
// the draft's profile and model pickers, and setup's model count. Every
// piece is driven by data- attributes and works as plain HTML without it.
(function () {
	"use strict";

	var $ = function (sel, root) { return (root || document).querySelector(sel); };
	var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

	function typing(el) {
		if (!el) return false;
		var t = el.tagName;
		return t === "INPUT" || t === "TEXTAREA" || t === "SELECT" || el.isContentEditable;
	}

	// --- menus ----------------------------------------------------------------
	// One anchored menu at a time; a row menu opened from the keyboard puts
	// focus on its first item.
	document.addEventListener("toggle", function (e) {
		var d = e.target;
		if (!d.matches || !d.matches("details[data-menu]") || !d.open) return;
		$$("details[data-menu][open]").forEach(function (o) { if (o !== d) o.removeAttribute("open"); });
		var first = $('[role="menuitem"]', d);
		if (first && d.matches(".rmore")) first.focus({ preventScroll: true });
	}, true);

	// --- rename -----------------------------------------------------------------
	function focusRename() {
		var input = $("#rename");
		if (input) { input.focus(); input.select(); }
	}
	focusRename();
	document.body.addEventListener("htmx:afterSwap", focusRename);

	document.addEventListener("keydown", function (e) {
		if (e.key !== "Escape" || e.defaultPrevented) return;
		var form = e.target.closest && e.target.closest("form.rename");
		if (form) {
			e.preventDefault();
			var url = form.getAttribute("data-cancel");
			if (window.htmx && url) htmx.ajax("GET", url, { target: form, swap: "outerHTML" });
			else location.href = $("#list").getAttribute("data-list-href");
			return;
		}
		if (typing(document.activeElement)) return;
		var cancel = $("[data-sel-cancel]");
		if (cancel) { e.preventDefault(); cancel.click(); return; }
		var close = $("[data-close-panel]");
		if (close && !$("details[data-menu][open]")) { close.click(); }
	});

	// --- select many --------------------------------------------------------------
	function countSelected() {
		var label = $("[data-sel-count]");
		if (!label) return;
		var n = $$('#rows input[type=checkbox][name="id"]:checked').length;
		label.textContent = n + " selected";
	}
	document.addEventListener("change", function (e) {
		if (e.target.matches('#rows input[name="id"]')) countSelected();
		if (e.target.matches('[data-count-on] input[name="model_ids"]')) countOn(e.target.form);
	});
	document.addEventListener("click", function (e) {
		var all = e.target.closest("[data-select-all]");
		if (!all) return;
		e.preventDefault();
		$$('#rows input[name="id"]').forEach(function (c) { c.checked = true; });
		countSelected();
	});

	// --- search results ---------------------------------------------------------
	// After a title search the rows are the results: the arrows move through
	// them, Enter opens one, Esc goes back to the whole list.
	var search = $("#search");
	var list = $("#list");
	if (search && list) {
		var key = $("[data-search-key]");
		search.addEventListener("input", function () {
			if (key) key.textContent = (search.value.trim() || list.hasAttribute("data-search")) ? "Esc" : "/";
		});
		search.addEventListener("keydown", function (e) {
			if (!list.hasAttribute("data-search") || $("#command-results")) return;
			var rows = $$("#rows .row");
			var cur = rows.findIndex(function (r) { return r.classList.contains("kbd"); });
			if (e.key === "ArrowDown" || e.key === "ArrowUp") {
				if (!rows.length) return;
				e.preventDefault();
				var n = Math.max(0, Math.min(rows.length - 1, cur + (e.key === "ArrowDown" ? 1 : -1)));
				rows.forEach(function (r, i) { r.classList.toggle("kbd", i === n); });
				rows[n].scrollIntoView({ block: "nearest" });
			} else if (e.key === "Enter" && cur >= 0) {
				e.preventDefault();
				rows[cur].click();
			} else if (e.key === "Escape") {
				var u = new URL(location.href);
				u.searchParams.delete("q");
				u.searchParams.delete("arch");
				location.href = u.pathname + u.search;
			}
		});
	}

	// --- offline -----------------------------------------------------------------
	// sse.js retries the account stream after min(2^n, 128) × 0.5s; the banner
	// counts that down and Retry now reloads the page.
	var failures = 0, countdown = null;
	function eventsSource(e) {
		var elt = e.detail && e.detail.elt;
		return elt && elt.getAttribute && elt.getAttribute("sse-connect") === "/events";
	}
	document.body.addEventListener("htmx:sseError", function (e) {
		if (!eventsSource(e)) return;
		failures = Math.min(failures + 1, 8);
		var left = Math.max(1, Math.round(Math.min(Math.pow(2, failures - 1), 128) * 0.5));
		var out = $("[data-retry-in]");
		clearInterval(countdown);
		var tick = function () {
			if (out) out.textContent = left + "s";
			left = Math.max(1, left - 1);
		};
		tick();
		countdown = setInterval(tick, 1000);
	});
	document.body.addEventListener("htmx:sseOpen", function (e) {
		if (!eventsSource(e)) return;
		failures = 0;
		clearInterval(countdown);
	});
	document.addEventListener("click", function (e) {
		if (e.target.closest("[data-retry]")) location.reload();
	});

	// --- appearance ------------------------------------------------------------------
	document.addEventListener("click", function (e) {
		var b = e.target.closest('.seg [role="radio"]');
		if (!b) return;
		$$('[role="radio"]', b.parentNode).forEach(function (r) { r.setAttribute("aria-checked", String(r === b)); });
	});

	// --- draft -------------------------------------------------------------------------
	// Picking a profile or model updates the draft in place; without this the
	// buttons submit the composer as a GET and the page re-renders the same.
	var composer = $("form.draft-composer");
	if (composer) {
		var setModel = function (value, name, provider) {
			var field = $("[data-draft-model]", composer);
			if (field) field.value = value || "";
			$$("[data-model-name]").forEach(function (n) { n.textContent = name || "Choose model"; });
			$$("[data-model-provider]").forEach(function (n) { n.textContent = provider || ""; });
			$$("[data-pick-model]").forEach(function (b) { b.classList.toggle("on", b.getAttribute("data-pick-model") === value); });
		};
		var userPicked = false;
		document.addEventListener("click", function (e) {
			var card = e.target.closest("[data-pick-profile]");
			if (card) {
				e.preventDefault();
				$$("[data-pick-profile]").forEach(function (c) { c.setAttribute("aria-pressed", String(c === card)); });
				var pid = $("[data-draft-profile]", composer);
				if (!pid) {
					pid = document.createElement("input");
					pid.type = "hidden"; pid.name = "profile_id"; pid.setAttribute("data-draft-profile", "");
					composer.prepend(pid);
				}
				pid.value = card.getAttribute("data-pick-profile");
				var name = card.getAttribute("data-name");
				var sub = $("[data-draft-sub]");
				if (sub) {
					sub.innerHTML = '<span class="dot s7"></span><span data-draft-name></span>';
					sub.firstChild.classList.add(card.getAttribute("data-color"));
					sub.lastChild.textContent = name;
				}
				var ta = $("textarea", composer);
				if (ta) { ta.placeholder = "Message " + name; ta.disabled = false; ta.focus(); }
				var lbl = $('label[for="composer-text"]', composer);
				if (lbl) lbl.textContent = "Message " + name;
				if (!userPicked) {
					var m = card.getAttribute("data-model");
					var item = m ? $('[data-pick-model="' + m + '"]') : null;
					if (item) setModel(m, item.getAttribute("data-name"), item.getAttribute("data-provider"));
				}
				return;
			}
			var pick = e.target.closest("[data-pick-model]");
			if (pick) {
				e.preventDefault();
				userPicked = true;
				setModel(pick.getAttribute("data-pick-model"), pick.getAttribute("data-name"), pick.getAttribute("data-provider"));
				var d = pick.closest("details");
				if (d) d.removeAttribute("open");
			}
		});
	}

	// --- setup -------------------------------------------------------------------------
	function countOn(form) {
		var out = $("[data-on-count]", form);
		if (out) out.textContent = $$('input[name="model_ids"]:checked', form).length;
	}
})();
