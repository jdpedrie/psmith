// Progressive enhancement for the web client. Every page works without this
// file; it adds keyboard shortcuts, copy buttons,
// disclosure toggles, composer behavior, drafts kept in this browser, the
// explicit-save bar and the connection indicator. Server-rendered markup
// carries the hooks as data- attributes, so behavior follows the HTML.
(function () {
	"use strict";

	var $ = function (sel, root) { return (root || document).querySelector(sel); };
	var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

	function typing(el) {
		if (!el) return false;
		var t = el.tagName;
		return t === "INPUT" || t === "TEXTAREA" || t === "SELECT" || el.isContentEditable;
	}

	function store(k, v) {
		try {
			if (v === undefined) return localStorage.getItem(k);
			if (v === null || v === "") localStorage.removeItem(k); else localStorage.setItem(k, v);
		} catch (e) { return null; }
	}

	function setCookie(name, value) {
		document.cookie = name + "=" + encodeURIComponent(value) + ";path=/;max-age=31536000;samesite=lax";
	}

	// --- copy ---------------------------------------------------------------
	function copyText(text, btn) {
		if (!navigator.clipboard) return;
		navigator.clipboard.writeText(text).then(function () {
			if (!btn) return;
			btn.setAttribute("data-copied", "");
			setTimeout(function () { btn.removeAttribute("data-copied"); }, 1200);
		});
	}

	document.addEventListener("click", function (e) {
		var b = e.target.closest("[data-copy-code]");
		if (b) {
			var pre = b.closest(".codeblock").querySelector("pre");
			copyText(pre ? pre.innerText : "", b);
			return;
		}
		b = e.target.closest("[data-copy]");
		if (b) {
			var holder = b.closest("[data-text]");
			copyText(b.getAttribute("data-copy") || (holder ? holder.getAttribute("data-text") : ""), b);
			return;
		}
		// Disclosure: a button with aria-expanded toggles the element it
		// names with aria-controls, or the next [data-disclosed] sibling.
		b = e.target.closest("[data-disclose]");
		if (b) {
			var open = b.getAttribute("aria-expanded") !== "true";
			b.setAttribute("aria-expanded", String(open));
			var id = b.getAttribute("aria-controls");
			var panel = id ? document.getElementById(id) : null;
			if (panel) panel.hidden = !open;
			return;
		}
		b = e.target.closest("[data-toggle-inspector]");
		if (b) {
			var shown = b.getAttribute("aria-pressed") === "true";
			setCookie("psmith_inspector", shown ? "0" : "1");
			var insp = $("#inspector");
			if (insp) { insp.hidden = shown; b.setAttribute("aria-pressed", String(!shown)); }
			else location.reload();
			return;
		}
		b = e.target.closest("[data-switch]");
		if (b && b.getAttribute("role") === "switch") {
			var on = b.getAttribute("aria-checked") !== "true";
			b.setAttribute("aria-checked", String(on));
			var field = b.parentElement.querySelector('input[type=hidden][name="' + b.getAttribute("data-switch") + '"]');
			if (field) { field.value = String(on); field.dispatchEvent(new Event("input", { bubbles: true })); }
			return;
		}
		b = e.target.closest("[data-appearance]");
		if (b) {
			var kind = b.getAttribute("data-appearance"), val = b.getAttribute("value");
			document.documentElement.setAttribute(kind === "theme" ? "data-theme" : "data-mode", val);
		}
		// Anchored menus close on any click outside them.
		$$("[data-menu][open]").forEach(function (d) { if (!d.contains(e.target)) d.removeAttribute("open"); });
	});

	// --- keyboard -----------------------------------------------------------
	function rows() { return $$("#rows a.row"); }

	function moveConversation(step) {
		var all = rows();
		if (!all.length) return;
		var cur = all.findIndex(function (r) { return r.hasAttribute("aria-current"); });
		var next = all[Math.max(0, Math.min(all.length - 1, cur < 0 ? 0 : cur + step))];
		if (next) next.click();
	}

	// Opens your last message's editor in place, through its own Edit
	// control. False when there's no message of yours to edit.
	function editLastMessage() {
		var mine = $$("#messages .turn-user[id]");
		var last = mine[mine.length - 1];
		var edit = last && $('a[aria-label="Edit message"]', last);
		if (!edit) return false;
		edit.click();
		return true;
	}

	document.addEventListener("keydown", function (e) {
		if (e.defaultPrevented || e.isComposing) return;
		// Cmd/Ctrl+S saves a page with a save bar.
		if ((e.metaKey || e.ctrlKey) && e.key === "s") {
			var bar = $("[data-savebar]:not([hidden])");
			if (bar) { e.preventDefault(); bar.closest("form").requestSubmit(); }
			return;
		}
		if (e.key === "Escape") {
			// The composer keeps focus after a send, and its hint promises Esc
			// stops the reply, so Esc there stops too; other fields keep Esc.
			// A reply is live as soon as its row is on the page; the composer's
			// data-live lags it by the send request's completion.
			var stop = $("#messages .reply.live") || $("#composer[data-live]") ? $("#composer [data-stop]") : null;
			var active = document.activeElement;
			if (stop && (!typing(active) || active.id === "composer-text")) { e.preventDefault(); stop.click(); return; }
			$$("[data-menu][open]").forEach(function (d) { d.removeAttribute("open"); });
			return;
		}
		// Up in an empty composer edits your last message, as it does in the
		// apps: the composer is where your hands are when you spot the typo.
		var held = document.activeElement;
		if (e.key === "ArrowUp" && held && held.id === "composer-text" && !held.value &&
			!e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
			if (editLastMessage()) e.preventDefault();
			return;
		}
		if (e.metaKey || e.ctrlKey || e.altKey || typing(document.activeElement)) return;
		switch (e.key) {
			case "/": e.preventDefault(); var s = $("#search"); if (s) { s.focus(); s.select(); } break;
			case "j": moveConversation(1); break;
			case "k": moveConversation(-1); break;
			case "ArrowUp": {
				if (editLastMessage()) e.preventDefault();
				break;
			}
			default: {
				var target = $('[data-key="' + e.key.toLowerCase() + '"]');
				if (target && e.key.length === 1) { e.preventDefault(); target.click(); }
			}
		}
	});

	// --- composer ------------------------------------------------------------
	var form = $("#composer");
	var ta = form ? $("textarea", form) : null;
	var convID = $("#main") ? $("#main").getAttribute("data-conv") : null;
	if (ta) {
		var key = convID ? "psmith.draft." + convID : null;
		var grow = function () {
			ta.style.height = "auto";
			ta.style.height = Math.min(ta.scrollHeight, 240) + "px";
		};
		if (key && !ta.value) ta.value = store(key) || "";
		ta.addEventListener("input", function () { grow(); if (key) store(key, ta.value); });
		ta.addEventListener("keydown", function (e) {
			if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
				e.preventDefault();
				if (ta.value.trim() !== "" || $("input[type=file]", form) && $("input[type=file]", form).files.length) form.requestSubmit();
			}
		});
		form.addEventListener("htmx:afterRequest", function (e) {
			if (e.detail && e.detail.successful) {
				ta.value = "";
				if (key) store(key, null);
				form.setAttribute("data-live", "");
			}
			grow();
			ta.focus();
		});
		grow();
	}

	if (form) {
		var stopBtn = $("[data-stop]", form);
		if (stopBtn) stopBtn.addEventListener("click", function () {
			fetch(stopBtn.getAttribute("data-stop"), { method: "POST", credentials: "same-origin" });
		});
	}

	// A finished stream ends the composer's live state.
	document.body.addEventListener("htmx:sseClose", function () {
		if (form && !$("#messages [aria-busy=true]")) form.removeAttribute("data-live");
	});

	// --- follow the stream ---------------------------------------------------
	var scroller = $("#transcript");
	if (scroller) {
		var stick = true;
		var bottom = function () { scroller.scrollTop = scroller.scrollHeight; };
		bottom();
		scroller.addEventListener("scroll", function () {
			stick = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 140;
			var pill = $("#jump-latest");
			if (pill) pill.hidden = stick;
		});
		new MutationObserver(function () { if (stick) bottom(); })
			.observe(scroller, { childList: true, subtree: true, characterData: true });
		document.addEventListener("click", function (e) {
			if (e.target.closest("#jump-latest")) { stick = true; bottom(); }
		});
	}

	// --- explicit save -------------------------------------------------------
	// A form with a save bar counts the fields that differ from what loaded.
	$$("form").forEach(function (f) {
		var bar = $("[data-savebar]", f);
		if (!bar) return;
		var fields = $$("input, select, textarea", f).filter(function (el) { return el.name && el.type !== "file"; });
		var initial = fields.map(function (el) { return el.type === "checkbox" ? el.checked : el.value; });
		var count = function () {
			var n = fields.reduce(function (acc, el, i) {
				return acc + ((el.type === "checkbox" ? el.checked : el.value) !== initial[i] ? 1 : 0);
			}, 0);
			var start = parseInt(bar.getAttribute("data-initial") || "0", 10);
			n = Math.max(n, start);
			bar.hidden = n === 0;
			var label = $("[data-dirty-count]", bar);
			if (label) label.textContent = n === 1 ? "1 unsaved change" : n + " unsaved changes";
		};
		f.addEventListener("input", count);
		f.addEventListener("change", count);
		f.addEventListener("reset", function () {
			setTimeout(function () {
				// A hidden input's value is its attribute, so reset can't
				// restore what a switch wrote there.
				fields.forEach(function (el, i) { if (el.type === "hidden") el.value = initial[i]; });
				$$("[role=switch][data-switch]", f).forEach(function (s) {
					var h = f.querySelector('input[type=hidden][name="' + s.getAttribute("data-switch") + '"]');
					if (h) s.setAttribute("aria-checked", h.value);
				});
				bar.setAttribute("data-initial", "0");
				count();
			});
		});
	});

	// --- filter a table in place ---------------------------------------------
	$$("[data-filter]").forEach(function (input) {
		var target = $(input.getAttribute("data-filter"));
		if (!target) return;
		input.addEventListener("input", function () {
			var q = input.value.trim().toLowerCase();
			$$("tr", target).forEach(function (tr) { tr.hidden = q !== "" && tr.textContent.toLowerCase().indexOf(q) < 0; });
		});
	});

	// --- connection ------------------------------------------------------------
	document.body.addEventListener("htmx:sseError", function () {
		document.documentElement.setAttribute("data-offline", "");
		var s = $("#conn-status span:last-child");
		if (s) s.textContent = "Reconnecting";
	});
	document.body.addEventListener("htmx:sseOpen", function () {
		document.documentElement.removeAttribute("data-offline");
		var s = $("#conn-status span:last-child");
		if (s) s.textContent = "Online";
	});
})();
