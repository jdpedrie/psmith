// Keeps the transcript pinned to the latest message: on load, after a send
// (htmx appends the user bubble + streaming element), and as streamed deltas
// land — but only while the reader is already near the bottom, so scrolling up
// to re-read isn't yanked back down.
(function () {
	function init() {
		var el = document.getElementById("messages");
		if (!el) return;

		var THRESHOLD = 140;
		var stick = true;

		function nearBottom() {
			return el.scrollHeight - el.scrollTop - el.clientHeight < THRESHOLD;
		}
		function toBottom() {
			el.scrollTop = el.scrollHeight;
		}

		toBottom();

		el.addEventListener("scroll", function () {
			stick = nearBottom();
		});

		// Streamed deltas mutate the assistant .md node in place.
		new MutationObserver(function () {
			if (stick) toBottom();
		}).observe(el, { childList: true, subtree: true, characterData: true });

		// A send appends new nodes to #messages; always follow that.
		document.body.addEventListener("htmx:afterSwap", function (e) {
			if (e.target && e.target.id === "messages") {
				stick = true;
				toBottom();
			}
			syncModel();
		});

		// Mirror the model the chip shows into the composer's hidden field, so a
		// send always carries an explicit provider/model (picking a model swaps
		// the chip in place; this keeps the field current without a reload).
		function syncModel() {
			var chip = document.getElementById("composer-model-chip");
			var field = document.getElementById("composer-model");
			if (chip && field && chip.dataset.model != null) {
				field.value = chip.dataset.model;
			}
		}
		syncModel();

		// Composer: grow the textarea with its content (up to the CSS max),
		// submit on Enter (Shift+Enter for a newline), and clear only after a
		// successful send so a failed message stays put for a retry.
		var ta = document.querySelector(".composer textarea");
		var form = document.getElementById("composer");
		if (ta && form) {
			var grow = function () {
				ta.style.height = "auto";
				ta.style.height = Math.min(ta.scrollHeight, 220) + "px";
			};
			ta.addEventListener("input", grow);
			ta.addEventListener("keydown", function (e) {
				if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
					e.preventDefault();
					if (ta.value.trim() !== "") form.requestSubmit();
				}
			});
			form.addEventListener("htmx:afterRequest", function (e) {
				if (e.detail && e.detail.successful) {
					ta.value = "";
					ta.style.height = "auto";
				}
				ta.focus();
			});
			grow();
		}
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", init);
	} else {
		init();
	}
})();
