// conv area behavior: the More menu, in-place edits, the context-start
// strip, choices, live timers, and uploads that start before the send.
// Shared behavior lives in app.js; every control here also works as a plain
// link or form without this file.
(function () {
	"use strict";

	var $ = function (sel, root) { return (root || document).querySelector(sel); };
	var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

	function copy(text, btn) {
		if (!navigator.clipboard) return;
		navigator.clipboard.writeText(text).then(function () {
			if (btn) { btn.setAttribute("data-copied", ""); setTimeout(function () { btn.removeAttribute("data-copied"); }, 1200); }
		});
	}

	// Swap a fragment into place without a page load.
	function swap(url, target) {
		if (window.htmx) htmx.ajax("GET", url, { target: target, swap: "outerHTML" });
		else location.href = url;
	}

	function closeMenus(except) {
		$$(".more-wrap .msg-menu").forEach(function (m) {
			var wrap = m.closest(".more-wrap");
			if (except && wrap.contains(except)) return;
			var btn = $(".more-btn", wrap);
			if (btn) { btn.classList.remove("on"); btn.setAttribute("aria-expanded", "false"); }
			m.remove();
		});
	}

	document.addEventListener("click", function (e) {
		var t = e.target;
		closeMenus(t);

		var b = t.closest("[data-copy-text]");
		if (b) {
			var row = b.closest("[data-text]");
			var text = row ? $$(".md", row).filter(function (m) { return !m.closest(".think-panel,.partial"); }).map(function (m) { return m.innerText; }).join("\n\n") : "";
			copy(text, b);
		}
		if (t.closest("[data-close-menu]")) { setTimeout(function () { closeMenus(); }, 0); return; }

		b = t.closest("[data-start-toggle]");
		if (b) {
			e.preventDefault();
			var open = b.getAttribute("aria-expanded") !== "true";
			b.setAttribute("aria-expanded", String(open));
			var panel = document.getElementById(b.getAttribute("aria-controls"));
			if (panel) panel.hidden = !open;
			return;
		}

		b = t.closest("[data-choice]");
		if (b && b.getAttribute("data-choice").indexOf("compose:") === 0) {
			e.preventDefault();
			var ta = $("#composer textarea");
			if (ta) {
				ta.value = b.getAttribute("data-choice").slice(8);
				ta.dispatchEvent(new Event("input", { bubbles: true }));
				ta.focus();
			}
		}
	});

	document.addEventListener("keydown", function (e) {
		if (e.defaultPrevented || e.isComposing) return;
		var form = e.target.closest && e.target.closest("form[data-escape]");
		if (e.key === "Escape") {
			if ($(".more-wrap .msg-menu")) { closeMenus(); return; }
			if (form) { e.preventDefault(); swap(form.getAttribute("data-escape"), form.id ? "#" + form.id : form.closest("header")); return; }
			var back = $(".image-back");
			if (back) { e.preventDefault(); location.href = back.getAttribute("href"); }
			return;
		}
		if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && form && e.target.tagName === "TEXTAREA") {
			e.preventDefault();
			form.requestSubmit($('button[type="submit"]:not([name])', form) || undefined);
		}
	});

	// A swapped-in transcript with a reply streaming puts the composer in its
	// live state, so Stop shows.
	document.body.addEventListener("htmx:afterSettle", function () {
		var f = $("#composer");
		if (!f) return;
		if ($("#messages [aria-busy=true]")) f.setAttribute("data-live", ""); else f.removeAttribute("data-live");
	});

	// Live chips count up from when they started.
	setInterval(function () {
		$$("[data-since]").forEach(function (el) {
			var since = parseInt(el.getAttribute("data-since"), 10);
			if (since > 0) el.textContent = Math.max(0, (Date.now() - since) / 1000).toFixed(1) + "s";
		});
	}, 100);

	// --- uploads ---------------------------------------------------------------
	// Files upload as soon as they are picked, dropped or pasted, so the send
	// carries stored ids. Send waits for uploads still in flight.
	var form = $("#composer");
	var uploadURL = form ? form.getAttribute("data-upload") : null;
	var box = $("#pending");
	var inflight = 0, sendQueued = false;

	function human(n) { return n >= 1048576 ? (n / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1024)) + " KB"; }

	function setUploading() {
		if (!form) return;
		var hint = $(".composer-bar .hint", form);
		if (inflight > 0) {
			form.setAttribute("data-uploading", "");
			if (hint) {
				if (!hint.hasAttribute("data-idle")) hint.setAttribute("data-idle", hint.innerHTML);
				hint.textContent = inflight === 1 ? "Uploading 1 file. Send waits for it." : "Uploading " + inflight + " files. Send waits for them.";
			}
			return;
		}
		form.removeAttribute("data-uploading");
		if (hint && hint.hasAttribute("data-idle")) { hint.innerHTML = hint.getAttribute("data-idle"); hint.removeAttribute("data-idle"); }
		if (sendQueued) { sendQueued = false; form.requestSubmit(); }
	}

	function upload(file) {
		var chip = document.createElement("span");
		chip.className = "pend up";
		chip.innerHTML = '<span class="thumb"></span><span class="pname"></span><span class="size tnum" role="progressbar" aria-valuemin="0" aria-valuemax="100"></span><button type="button" data-unpend>×</button><span class="bar" aria-hidden="true"></span>';
		$(".pname", chip).textContent = file.name;
		$("button", chip).setAttribute("aria-label", "Cancel upload of " + file.name);
		var size = $(".size", chip), bar = $(".bar", chip);
		var progress = function (pct) {
			size.textContent = pct + "% of " + human(file.size);
			size.setAttribute("aria-valuenow", String(pct));
			bar.style.width = pct + "%";
		};
		progress(0);
		box.appendChild(chip);
		box.hidden = false;

		var fd = new FormData();
		fd.append("file", file, file.name);
		var xhr = new XMLHttpRequest();
		chip._xhr = xhr;
		inflight++;
		setUploading();
		var done = function () { inflight--; chip._xhr = null; setUploading(); };
		xhr.upload.onprogress = function (ev) { if (ev.lengthComputable) progress(Math.round(ev.loaded * 100 / ev.total)); };
		xhr.onload = function () {
			if (xhr.status >= 200 && xhr.status < 300) {
				var tmp = document.createElement("div");
				tmp.innerHTML = xhr.responseText;
				var stored = tmp.firstElementChild;
				if (stored && chip.parentNode) chip.replaceWith(stored);
			} else {
				size.textContent = "Failed";
				bar.style.width = "0";
			}
			done();
		};
		xhr.onerror = function () { size.textContent = "Failed"; done(); };
		xhr.onabort = done;
		xhr.open("POST", uploadURL);
		xhr.send(fd);
	}

	if (form && box && uploadURL) {
		var input = $("input[type=file]", form);
		// Capture runs before app.js's own change listener, which would
		// otherwise redraw the chips from the input and drop stored ones.
		document.addEventListener("change", function (e) {
			if (e.target !== input) return;
			e.stopPropagation();
			Array.prototype.forEach.call(input.files || [], upload);
			input.value = "";
		}, true);

		box.addEventListener("click", function (e) {
			var b = e.target.closest("[data-unpend]");
			if (!b) return;
			var chip = b.closest(".pend");
			if (chip._xhr) chip._xhr.abort();
			chip.remove();
			box.hidden = !$(".pend", box);
		});

		form.addEventListener("submit", function (e) {
			if (inflight > 0) { e.preventDefault(); e.stopImmediatePropagation(); sendQueued = true; }
		}, true);

		// A sent message took its stored files with it. Their chips (and the
		// hidden ids inside them) stayed, so the next message carried the same
		// files again. An upload still running belongs to the next message.
		form.addEventListener("htmx:afterRequest", function (e) {
			if (!e.detail || !e.detail.successful || e.detail.elt !== form) return;
			Array.prototype.forEach.call(box.querySelectorAll(".pend"), function (chip) {
				if (!chip._xhr) chip.remove();
			});
			box.hidden = !box.querySelector(".pend");
		});

		var ta = $("textarea", form);
		if (ta) ta.addEventListener("paste", function (e) {
			var files = e.clipboardData ? Array.prototype.slice.call(e.clipboardData.files || []) : [];
			if (!files.length) return;
			e.preventDefault();
			files.forEach(upload);
		});

		var main = $("#main"), zone = $("#drop-zone");
		var hasFiles = function (e) { return e.dataTransfer && Array.prototype.indexOf.call(e.dataTransfer.types || [], "Files") >= 0; };
		if (main && zone && input) {
			var depth = 0;
			main.addEventListener("dragenter", function (e) {
				if (!hasFiles(e)) return;
				depth++;
				zone.hidden = false;
			});
			main.addEventListener("dragover", function (e) { if (hasFiles(e)) e.preventDefault(); });
			main.addEventListener("dragleave", function () { if (--depth <= 0) { depth = 0; zone.hidden = true; } });
			main.addEventListener("drop", function (e) {
				if (!hasFiles(e)) return;
				e.preventDefault();
				depth = 0;
				zone.hidden = true;
				Array.prototype.forEach.call(e.dataTransfer.files, upload);
			});
		}
	}

	// --- offline (board Offline) -----------------------------------------------
	// app.js marks <html data-offline> while a stream is down. The transcript
	// says when it dropped; a send is held, not lost, and goes out when the
	// stream reopens.
	var lostAt = null;
	document.body.addEventListener("htmx:sseError", function () {
		if (lostAt) return;
		lostAt = new Date();
		var t = $("[data-lost-text]");
		if (t) {
			var hm = String(lostAt.getHours()).padStart(2, "0") + ":" + String(lostAt.getMinutes()).padStart(2, "0");
			t.textContent = "Lost the connection at " + hm + ". New replies show up here when it's back.";
		}
	});
	document.body.addEventListener("htmx:sseOpen", function () {
		lostAt = null;
		var held = $("form.composer[data-held]");
		if (held) {
			held.removeAttribute("data-held");
			requestAnimationFrame(function () { held.requestSubmit(); });
		}
	});
	document.addEventListener("submit", function (e) {
		var f = e.target.closest && e.target.closest("form.composer");
		if (!f || !document.documentElement.hasAttribute("data-offline")) return;
		e.preventDefault();
		e.stopImmediatePropagation();
		f.setAttribute("data-held", "");
	}, true);

	// --- live thinking ------------------------------------------------------------
	// Each chips event redraws the chip row closed; keep a chip's state in
	// step with its panel, which the redraw doesn't touch.
	document.body.addEventListener("htmx:afterSettle", function (e) {
		var row = e.target;
		if (!row.classList || !row.classList.contains("reply-chips")) return;
		row.querySelectorAll("[data-disclose][aria-controls]").forEach(function (b) {
			var p = document.getElementById(b.getAttribute("aria-controls"));
			if (p) b.setAttribute("aria-expanded", String(!p.hidden));
		});
	});
})();

// A transcript refresh would close a row's editor, delete strip or menu and
// drop what was typed in it, or replace the row a row request is about to
// swap into. While either is the case the refresh waits (the #messages-sync
// trigger asks psmithHoldTranscript), and runs once it's over.
(function () {
	"use strict";
	var held = false, rowRequests = 0, refresh = null;
	function open() {
		return !!document.querySelector("#messages form.edit-form, #messages form.del-confirm, #messages .msg-menu");
	}
	function holding() { return rowRequests > 0 || open(); }
	function fromRow(e) {
		var el = e.detail && e.detail.elt;
		return !!(el && el.closest && el.closest("#messages") && el.id !== "messages");
	}
	// A refresh already out when a row acts would still land on that row:
	// the reader's action wins, and the refresh runs again after it.
	function yieldRefresh() {
		var sync = document.getElementById("messages-sync");
		if (!refresh || !sync) return;
		refresh = null;
		held = true;
		htmx.trigger(sync, "htmx:abort");
	}
	// Counted off the XHR: a row request that replaces #messages detaches
	// its own element, and htmx's events on a detached element never reach
	// the body.
	document.body.addEventListener("htmx:beforeRequest", function (e) {
		var d = e.detail || {};
		if (!d.xhr) return;
		if (d.elt && d.elt.id === "messages-sync") {
			var xhr = d.xhr;
			refresh = xhr;
			xhr.addEventListener("loadend", function () { if (refresh === xhr) refresh = null; });
			return;
		}
		if (!fromRow(e)) return;
		yieldRefresh();
		rowRequests++;
		d.xhr.addEventListener("loadend", function () {
			rowRequests = Math.max(0, rowRequests - 1);
			setTimeout(flush, 0);
		});
	});
	window.psmithHoldTranscript = function () {
		if (holding()) { held = true; return true; }
		return false;
	};
	function flush() {
		if (!held || holding()) return;
		held = false;
		var sync = document.getElementById("messages-sync");
		if (sync) htmx.ajax("GET", sync.getAttribute("hx-get"), { source: sync, target: "#messages", select: "#messages", swap: "outerHTML" });
	}
	document.body.addEventListener("htmx:afterSettle", flush);
})();

// The header (title, model, context gauge) follows the transcript: a reply,
// a generated title or a compression changes it, and nothing else redraws
// it. Not while it's being renamed.
document.body.addEventListener("htmx:afterSwap", function (e) {
	var d = e.detail || {};
	var path = d.requestConfig && d.requestConfig.path;
	if (!path || !/\/partials\/messages$/.test(path)) return;
	var head = document.getElementById("conv-head");
	if (!head || head.querySelector("form.rename")) return;
	htmx.ajax("GET", path.replace(/\/partials\/messages$/, "/head"), { target: "#conv-head", swap: "outerHTML" });
});
