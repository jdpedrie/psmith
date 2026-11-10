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

	// --- search as a command line -------------------------------------------------
	// Typing in search asks the server for matching commands, conversations
	// and settings and shows them in place of the rows. After a submitted
	// title search the rows are the results: the arrows move through them,
	// Enter opens one, Esc goes back to the whole list. The column is swapped
	// whole on every refresh, so all of this is delegated and looks its
	// elements up each time.
	var cmdTimer = null;
	function showResults(html) {
		var body = $("#list-body");
		if (!body) return;
		var results = $("#command-results");
		if (!results) {
			results = document.createElement("div");
			results.id = "command-results";
			body.parentNode.insertBefore(results, body);
		}
		results.innerHTML = html;
		body.hidden = true;
	}
	function clearResults() {
		var results = $("#command-results");
		if (results) results.remove();
		var body = $("#list-body");
		if (body) body.hidden = false;
		catchUp();
	}
	document.addEventListener("input", function (e) {
		if (e.target.id !== "search") return;
		var search = e.target, list = $("#list"), key = $("[data-search-key]");
		if (key) key.textContent = (search.value.trim() || (list && list.hasAttribute("data-search"))) ? "Esc" : "/";
		clearTimeout(cmdTimer);
		var q = search.value.trim();
		if (!q) { clearResults(); return; }
		cmdTimer = setTimeout(function () {
			var conv = $("#main") ? $("#main").getAttribute("data-conv") || "" : "";
			fetch("/partials/command?q=" + encodeURIComponent(q) + "&conv=" + encodeURIComponent(conv), { credentials: "same-origin" })
				.then(function (r) { return r.ok ? r.text() : ""; })
				.then(function (html) {
					var s = $("#search");
					if (s && s.value.trim() === q) showResults(html);
				});
		}, 120);
	});
	document.addEventListener("keydown", function (e) {
		if (e.target.id !== "search" || e.isComposing) return;
		var search = e.target, list = $("#list"), results = $("#command-results");
		var searched = list && list.hasAttribute("data-search");
		if (e.key === "Escape") {
			clearTimeout(cmdTimer);
			if (searched) {
				var u = new URL(location.href);
				u.searchParams.delete("q");
				u.searchParams.delete("arch");
				location.href = u.pathname + u.search;
				return;
			}
			search.value = "";
			var key = $("[data-search-key]");
			if (key) key.textContent = "/";
			clearResults();
			search.blur();
			return;
		}
		var opts = results ? $$('[role="option"]', results) : searched ? $$("#rows .row") : [];
		var on = results ? function (o) { return o.getAttribute("aria-selected") === "true"; } : function (o) { return o.classList.contains("kbd"); };
		var cur = opts.findIndex(on);
		if (e.key === "ArrowDown" || e.key === "ArrowUp") {
			if (!opts.length) return;
			e.preventDefault();
			var n = Math.max(0, Math.min(opts.length - 1, cur + (e.key === "ArrowDown" ? 1 : -1)));
			opts.forEach(function (o, i) {
				if (results) o.setAttribute("aria-selected", String(i === n));
				else o.classList.toggle("kbd", i === n);
			});
			opts[n].scrollIntoView({ block: "nearest" });
		} else if (e.key === "Enter" && opts.length && (results || cur >= 0)) {
			e.preventDefault();
			opts[cur < 0 ? 0 : cur].click();
		}
	});

	// --- refreshes ---------------------------------------------------------------
	// The column refreshes by swapping itself whole. It keeps its scroll, and
	// a refresh skipped while something in it was held (a rename, a confirm,
	// an open menu, typed search results) runs once the hold lets go, so the
	// list doesn't stay stale.
	var keptScroll = null, missed = false;
	function held() {
		return !!document.querySelector("#list [data-hold], #list details[open], #command-results");
	}
	function catchUp() {
		var list = $("#list");
		if (!missed || held() || !list || !window.htmx) return;
		missed = false;
		htmx.trigger(list, "sse:conversation-changed");
	}
	document.addEventListener("htmx:sseMessage", function (e) {
		if (e.target.id === "list" && held()) missed = true;
	}, true);
	document.addEventListener("htmx:beforeSwap", function (e) {
		var t = e.detail && e.detail.target;
		if (t && t.id === "list") {
			var rows = $("#rows");
			keptScroll = rows ? rows.scrollTop : null;
		}
	}, true);
	document.addEventListener("htmx:afterSwap", function () {
		var rows = $("#rows");
		if (rows && keptScroll !== null) rows.scrollTop = keptScroll;
		keptScroll = null;
		showDrafts();
		markFinished();
		setTimeout(catchUp);
	}, true);
	document.addEventListener("toggle", function (e) {
		if (e.target.matches && e.target.matches("#list details[data-menu]") && !e.target.open) setTimeout(catchUp);
	}, true);

	// --- drafts --------------------------------------------------------------------
	// Rows show this browser's unsent drafts.
	function draftOf(id) {
		try { return localStorage.getItem("psmith.draft." + id); } catch (e) { return null; }
	}
	function showDrafts() {
		$$("#rows .row[data-id]").forEach(function (r) {
			var d = draftOf(r.getAttribute("data-id"));
			var sub = $(".row-sub", r);
			if (d && sub && !sub.classList.contains("live")) {
				sub.innerHTML = '<span class="draft">Draft:</span> ';
				sub.appendChild(document.createTextNode(d));
			}
		});
	}
	showDrafts();

	// --- unread replies ------------------------------------------------------------
	// A reply that finishes while its conversation isn't open here marks the
	// row until it's opened, as the apps' unseen dot does. The server doesn't
	// track what each device has seen, so like the apps this browser keeps
	// the marks itself. A row's data-at is its newest message's time, so a
	// reply landing moves it between two refreshes of the column. Watching
	// data-live instead missed most replies: the refresh for the user's
	// message lands before the run is registered, and the next one after it
	// ends, so the row was never seen live.
	var UNSEEN = "psmith.unseen", seenAt = {};
	function unseenIDs() {
		try {
			var v = JSON.parse(localStorage.getItem(UNSEEN) || "[]");
			return Array.isArray(v) ? v : [];
		} catch (e) { return []; }
	}
	function saveUnseen(ids) {
		try { localStorage.setItem(UNSEEN, JSON.stringify(ids)); } catch (e) { /* storage refused */ }
	}
	function openConv() {
		var m = $("#main");
		return m ? m.getAttribute("data-conv") || "" : "";
	}
	function showUnseen() {
		var ids = unseenIDs(), open = openConv();
		if (open && ids.indexOf(open) >= 0) {
			ids = ids.filter(function (id) { return id !== open; });
			saveUnseen(ids);
		}
		$$("#rows a.row[data-id]").forEach(function (r) {
			var on = ids.indexOf(r.getAttribute("data-id")) >= 0 && !r.hasAttribute("data-live");
			var time = $(".row-time", r), dot = time && $(".unread", time);
			r.classList.toggle("unseen", on);
			if (on && time && !dot) {
				dot = document.createElement("span");
				dot.className = "unread";
				dot.setAttribute("role", "img");
				dot.setAttribute("aria-label", "Unread reply");
				time.insertBefore(dot, time.firstChild);
			} else if (!on && dot) {
				time.removeChild(dot);
			}
			seenAt[r.getAttribute("data-id")] = r.getAttribute("data-at");
		});
	}
	function markFinished() {
		var open = openConv(), ids = unseenIDs(), changed = false;
		$$("#rows a.row[data-id]").forEach(function (r) {
			var id = r.getAttribute("data-id"), was = seenAt[id];
			if (was !== undefined && was !== r.getAttribute("data-at") && id !== open && ids.indexOf(id) < 0) {
				ids.push(id);
				changed = true;
			}
		});
		if (changed) saveUnseen(ids);
		showUnseen();
	}
	window.addEventListener("storage", function (e) { if (e.key === UNSEEN) showUnseen(); });
	showUnseen();

	// The open conversation's row is in view when the page loads, wherever
	// it sits in the list.
	var current = $("#rows .row[aria-current]");
	if (current) current.scrollIntoView({ block: "nearest" });

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
