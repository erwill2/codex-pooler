import test from "node:test";
import assert from "node:assert/strict";
import { ClipboardCopy } from "./clipboard_copy.mjs";

class FakeElement {
	constructor(attributes = {}, dataset = {}, textContent = "") {
		this.attributes = new Map(Object.entries(attributes));
		this.dataset = dataset;
		this.textContent = textContent;
		this.listeners = {};
		this.children = [];
		this._className = "";
		const self = this;
		this.classList = {
			add(cls) { self._className = (self._className + " " + cls).trim(); },
			remove(cls) {
				const regex = new RegExp("\\b" + cls + "\\b", "g");
				self._className = self._className.replace(regex, "").trim();
			},
			contains(cls) {
				return self._className.split(/\s+/).includes(cls);
			}
		};
	}

	get className() {
		return this._className;
	}

	set className(value) {
		this._className = value;
	}

	hasAttribute(name) {
		return this.attributes.has(name);
	}

	getAttribute(name) {
		return this.attributes.get(name) || null;
	}

	setAttribute(name, value) {
		this.attributes.set(name, value);
	}

	removeAttribute(name) {
		this.attributes.delete(name);
	}

	addEventListener(event, handler) {
		this.listeners[event] = this.listeners[event] || [];
		this.listeners[event].push(handler);
	}

	removeEventListener(event, handler) {
		if (this.listeners[event]) {
			this.listeners[event] = this.listeners[event].filter(h => h !== handler);
		}
	}

	appendChild(child) {
		child.parentNode = this;
		this.children.push(child);
		return child;
	}

	querySelector(selector) {
		if (selector === ".copy-icon") {
			return this.icon || null;
		}
		if (selector === "[data-copy-label]") {
			return this.label || null;
		}
		return null;
	}

	remove() {
		if (this.parentNode) {
			this.parentNode.children = this.parentNode.children.filter(c => c !== this);
		}
	}
}

const originalDocument = globalThis.document;
const originalNavigator = globalThis.navigator;
const originalWindow = globalThis.window;

test("ClipboardCopy - mounts, caches aria-label, and creates live region", () => {
	globalThis.window = globalThis;
	globalThis.document = {
		createElement(tagName) {
			return new FakeElement();
		}
	};

	const el = new FakeElement({ "aria-label": "Original Copy Action" });
	const context = { el };

	ClipboardCopy.mounted.call(context);

	assert.equal(context.originalAriaLabel, "Original Copy Action");
	assert.ok(context.hasOriginalAriaLabel);
	assert.ok(context.liveRegion);
	assert.equal(context.liveRegion.getAttribute("aria-live"), "polite");
	assert.ok(context.liveRegion.classList.contains("sr-only"));
	assert.equal(el.children[0], context.liveRegion);

	ClipboardCopy.destroyed.call(context);
	globalThis.document = originalDocument;
	globalThis.window = originalWindow;
});

test("ClipboardCopy - handles copy click and restores state via timeout", async () => {
	globalThis.window = globalThis;
	let clipboardText = null;
	globalThis.navigator = {
		clipboard: {
			writeText: async (text) => {
				clipboardText = text;
			}
		}
	};

	let timeoutCallback = null;
	let timeoutDelay = null;
	const originalTimeout = globalThis.setTimeout;
	globalThis.setTimeout = (cb, delay) => {
		timeoutCallback = cb;
		timeoutDelay = delay;
		return 123;
	};

	globalThis.document = {
		createElement(tagName) {
			return new FakeElement();
		}
	};

	const el = new FakeElement({ "aria-label": "Copy Token" }, { copyText: "my-secret-token", copiedLabel: "Done!" });
	const icon = new FakeElement();
	icon.classList.add("hero-clipboard-document");
	const label = new FakeElement({}, {}, "Copy");

	el.icon = icon;
	el.label = label;

	const context = { el };
	ClipboardCopy.mounted.call(context);

	await context.clickHandler();

	assert.equal(clipboardText, "my-secret-token");
	assert.equal(label.textContent, "Done!");
	assert.equal(el.getAttribute("aria-label"), "Done!");
	assert.equal(context.liveRegion.textContent, "Done!");
	assert.ok(icon.classList.contains("hero-check"));
	assert.ok(el.classList.contains("btn-success"));
	assert.equal(timeoutDelay, 1400);

	timeoutCallback();

	assert.equal(label.textContent, "Copy");
	assert.equal(el.getAttribute("aria-label"), "Copy Token");
	assert.equal(context.liveRegion.textContent, "");
	assert.ok(!icon.classList.contains("hero-check"));
	assert.ok(icon.classList.contains("hero-clipboard-document"));
	assert.ok(!el.classList.contains("btn-success"));

	ClipboardCopy.destroyed.call(context);

	globalThis.navigator = originalNavigator;
	globalThis.document = originalDocument;
	globalThis.setTimeout = originalTimeout;
	globalThis.window = originalWindow;
});

test("ClipboardCopy - rapid successive clicks do not corrupt cached original aria-label", async () => {
	globalThis.window = globalThis;
	globalThis.navigator = {
		clipboard: {
			writeText: async () => {}
		}
	};

	let timeoutClearedCount = 0;
	const originalClearTimeout = globalThis.clearTimeout;
	globalThis.clearTimeout = () => {
		timeoutClearedCount++;
	};

	const originalTimeout = globalThis.setTimeout;
	globalThis.setTimeout = (cb) => {
		return 456;
	};

	globalThis.document = {
		createElement(tagName) {
			return new FakeElement();
		}
	};

	const el = new FakeElement({ "aria-label": "My Copy Action" }, { copyText: "token" });
	const context = { el };

	ClipboardCopy.mounted.call(context);

	await context.clickHandler();
	assert.equal(context.originalAriaLabel, "My Copy Action");

	await context.clickHandler();
	assert.equal(context.originalAriaLabel, "My Copy Action");
	assert.equal(timeoutClearedCount, 2);

	ClipboardCopy.destroyed.call(context);

	globalThis.navigator = originalNavigator;
	globalThis.document = originalDocument;
	globalThis.clearTimeout = originalClearTimeout;
	globalThis.setTimeout = originalTimeout;
	globalThis.window = originalWindow;
});

test("ClipboardCopy - removes aria-label attribute on timeout/destruction if not originally present", async () => {
	globalThis.window = globalThis;
	globalThis.navigator = {
		clipboard: {
			writeText: async () => {}
		}
	};

	let timeoutCallback = null;
	const originalTimeout = globalThis.setTimeout;
	globalThis.setTimeout = (cb) => {
		timeoutCallback = cb;
		return 789;
	};

	globalThis.document = {
		createElement(tagName) {
			return new FakeElement();
		}
	};

	const el = new FakeElement({}, { copyText: "token" });
	const context = { el };

	ClipboardCopy.mounted.call(context);
	assert.ok(!context.hasOriginalAriaLabel);
	assert.equal(context.originalAriaLabel, null);

	await context.clickHandler();
	assert.equal(el.getAttribute("aria-label"), "Copied");

	timeoutCallback();
	assert.ok(!el.hasAttribute("aria-label"));

	ClipboardCopy.destroyed.call(context);

	globalThis.navigator = originalNavigator;
	globalThis.document = originalDocument;
	globalThis.setTimeout = originalTimeout;
	globalThis.window = originalWindow;
});
