// The page's half of events-worker.js: htmx's SSE extension asks
// htmx.createEventSource for each connection, and /events gets a stand-in
// fed by the shared worker. Run streams (/c/{id}/stream) stay direct: they
// belong to one tab and end with their reply.
//
// The worker is named for the signed-in account, so a tab signed in as
// someone else never shares another account's stream. Without SharedWorker
// (Chrome on Android), or where a worker can't reach the server (some
// embedded browsers refuse its requests outright), the page connects
// directly, as before: a shared stream that fails before it ever opened
// hands over to a direct one, and the tab remembers for its later pages.
(function () {
	"use strict";
	var account = document.documentElement.getAttribute("data-account");
	if (!window.htmx || typeof SharedWorker === "undefined" || !account) return;
	var direct = htmx.createEventSource || function (url) { return new EventSource(url, { withCredentials: true }); };
	var DIRECT_KEY = "psmith-events-direct";
	function sharedFailed() {
		try { return sessionStorage.getItem(DIRECT_KEY) === "1"; } catch (e) { return false; }
	}
	function rememberFailed() {
		try { sessionStorage.setItem(DIRECT_KEY, "1"); } catch (e) { /* private mode */ }
	}

	function SharedSource(url) {
		var self = this;
		this.url = url;
		this.withCredentials = true;
		this.readyState = 0;
		this.onopen = null;
		this.onerror = null;
		this.onmessage = null;
		this._listeners = {};
		this._opened = false;
		this._real = null;
		this._worker = new SharedWorker("/web-assets/events-worker.js", { name: "psmith-events-" + account });
		this._port = this._worker.port;
		this._port.onmessage = function (m) { self._receive(m.data || {}); };
		this._port.start();
		this._port.postMessage({ listen: "message" });
		this._port.postMessage({ hello: true });
		window.addEventListener("pagehide", function () { self.close(); });
	}
	SharedSource.CONNECTING = 0;
	SharedSource.OPEN = 1;
	SharedSource.CLOSED = 2;

	SharedSource.prototype.addEventListener = function (name, fn) {
		var self = this;
		var fresh = !this._listeners[name];
		(this._listeners[name] = this._listeners[name] || []).push(fn);
		if (name === "open" || name === "error") return;
		if (this._real) {
			if (fresh) this._real.addEventListener(name, function (ev) { self._dispatch(name, ev); });
		} else {
			this._port.postMessage({ listen: name });
		}
	};
	SharedSource.prototype.removeEventListener = function (name, fn) {
		var l = this._listeners[name];
		if (l) this._listeners[name] = l.filter(function (f) { return f !== fn; });
	};
	SharedSource.prototype._fire = function (name, ev) {
		var handler = this["on" + name];
		if (typeof handler === "function") handler.call(this, ev);
		(this._listeners[name] || []).slice().forEach(function (fn) { fn.call(this, ev); }, this);
	};
	SharedSource.prototype._dispatch = function (name, ev) {
		if (name === "message") {
			this._fire("message", ev);
		} else {
			(this._listeners[name] || []).slice().forEach(function (fn) { fn.call(this, ev); }, this);
		}
	};
	SharedSource.prototype._receive = function (d) {
		if (this.readyState === 2 || this._real) return;
		if (d.type === "open") {
			this._opened = true;
			this.readyState = 1;
			this._fire("open", new Event("open"));
		} else if (d.type === "error") {
			if (!this._opened) {
				this._goDirect();
				return;
			}
			this.readyState = d.readyState === 2 ? 2 : 0;
			this._fire("error", new Event("error"));
		} else if (d.type === "event") {
			this._dispatch(d.name, new MessageEvent(d.name, { data: d.data, lastEventId: d.lastEventId || "" }));
		}
	};
	// The shared stream never opened: connect this page directly and feed
	// the same listeners from it.
	SharedSource.prototype._goDirect = function () {
		var self = this;
		rememberFailed();
		try { this._port.postMessage({ bye: true }); this._port.close(); } catch (e) { /* gone */ }
		var real = this._real = direct(this.url);
		real.onopen = function (ev) { self.readyState = 1; self._fire("open", ev); };
		real.onerror = function (ev) { self.readyState = real.readyState; self._fire("error", ev); };
		Object.keys(this._listeners).forEach(function (name) {
			if (name === "open" || name === "error") return;
			real.addEventListener(name, function (ev) { self._dispatch(name, ev); });
		});
	};
	SharedSource.prototype.close = function () {
		if (this.readyState === 2) return;
		this.readyState = 2;
		if (this._real) {
			this._real.close();
			return;
		}
		try { this._port.postMessage({ bye: true }); this._port.close(); } catch (e) { /* already gone */ }
	};

	htmx.createEventSource = function (url) {
		if (url === "/events" && !sharedFailed()) {
			try { return new SharedSource(url); } catch (e) { /* fall through */ }
		}
		return direct(url);
	};
})();
