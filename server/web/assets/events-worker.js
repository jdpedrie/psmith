// One account event stream for every Psmith tab in this browser.
//
// Over HTTP/1.1 a browser keeps six connections per host. Each tab held its
// own /events stream, so a handful of tabs left none for a send or a reply's
// stream: they queued until a tab closed or navigated. Tabs share this
// worker's one connection instead (events-shared.js is the page's half).
//
// EventSource only delivers named events to listeners registered by name, so
// each tab says which names it wants and the worker listens for the union.
"use strict";

var source = null;
var ports = [];
var names = new Set();

function broadcast(msg) {
	ports.forEach(function (p) { p.postMessage(msg); });
}

function listen(name) {
	source.addEventListener(name, function (e) {
		broadcast({ type: "event", name: name, data: e.data, lastEventId: e.lastEventId });
	});
}

function connect() {
	source = new EventSource("/events", { withCredentials: true });
	source.onopen = function () { broadcast({ type: "open" }); };
	source.onerror = function () { broadcast({ type: "error", readyState: source.readyState }); };
	names.forEach(listen);
}

self.onconnect = function (e) {
	var port = e.ports[0];
	ports.push(port);
	port.onmessage = function (m) {
		var d = m.data || {};
		if (d.listen && !names.has(d.listen)) {
			names.add(d.listen);
			if (source) listen(d.listen);
		}
		if (d.hello) {
			// A tab whose source closed asks again; reconnect if no one is.
			if (!source || source.readyState === 2) {
				connect();
			} else if (source.readyState === 1) {
				port.postMessage({ type: "open" });
			}
		}
		if (d.bye) {
			ports = ports.filter(function (p) { return p !== port; });
			if (ports.length === 0 && source) {
				source.close();
				source = null;
			}
		}
	};
	port.start();
};
