import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const appJsPath = path.join(__dirname, "app.js");
const appJsContent = fs.readFileSync(appJsPath, "utf-8");

// Extract ClipboardCopy definition
const match = appJsContent.match(/const ClipboardCopy = \{[\s\S]*?\n\};/);
if (!match) {
	throw new Error("Could not find ClipboardCopy in app.js");
}

const clipboardCopyCode = match[0];

// We can define a helper to get ClipboardCopy in our test context:
function getClipboardCopy() {
	const context = {};
	// Eval in a function context to avoid global scope pollution
	const fn = new Function("exports", `${clipboardCopyCode}\nreturn ClipboardCopy;`);
	return fn(context);
}

class FakeElement {
	constructor(attributes = {}, dataset = {}, textContent = "") {
		this.attributes = new Map(Object.entries(attributes));
		this.dataset = dataset;
		this.textContent = textContent;
		this.children = [];
		this.listeners = {};
		this.classList = {
			classes: new Set(),
			add(c) { this.classes.add(c); },
			remove(c) { this.classes.delete(c); },
			contains(c) { return this.classes.has(c); }
		};
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

	appendChild(child) {
		this.children.push(child);
		return child;
	}

	querySelector(selector) {
		if (selector === ".copy-icon") {
			return this.iconMock || null;
		}
		if (selector === "[data-copy-label]") {
			return this.labelMock || null;
		}
		return null;
	}

	addEventListener(event, callback) {
		this.listeners[event] = callback;
	}

	dispatchEvent(event) {
		if (this.listeners[event]) {
			this.listeners[event]();
		}
	}
}

// Setup a global mock document for testing document.createElement
Object.defineProperty(globalThis, "document", {
	value: {
		createElement: (tag) => {
			const el = new FakeElement();
			el.tagName = tag.toUpperCase();
			return el;
		}
	},
	configurable: true,
	writable: true,
});

test("ClipboardCopy - mounts and caches original aria-label, sets up aria-live", () => {
	const ClipboardCopy = getClipboardCopy();

	const el = new FakeElement({ "aria-label": "Copy API Token" });
	const hook = {
		el,
	};

	ClipboardCopy.mounted.call(hook);

	assert.equal(hook.originalAriaLabel, "Copy API Token");
	assert.equal(el.children.length, 1);
	assert.equal(el.children[0].className, "sr-only");
	assert.equal(el.children[0].getAttribute("aria-live"), "polite");
});

test("ClipboardCopy - click action triggers clipboard write, sets aria-label and announcements, and restores on timeout", async () => {
	const ClipboardCopy = getClipboardCopy();

	// Setup fake timers and navigator
	let writeTextCalledWith = null;
	Object.defineProperty(globalThis, "navigator", {
		value: {
			clipboard: {
				writeText: async (text) => {
					writeTextCalledWith = text;
				},
			},
		},
		configurable: true,
		writable: true,
	});

	let timeoutCallback = null;
	let timeoutDelay = null;
	let timeoutIdCounter = 1;
	const timeoutsCleared = [];

	globalThis.window = {
		clearTimeout: (id) => {
			timeoutsCleared.push(id);
		},
		setTimeout: (callback, delay) => {
			timeoutCallback = callback;
			timeoutDelay = delay;
			return timeoutIdCounter++;
		},
	};

	const el = new FakeElement(
		{ "aria-label": "Copy Token" },
		{ copyText: "my-secret-key", copiedLabel: "Copied!" }
	);

	const iconMock = {
		classList: {
			classes: new Set(["hero-clipboard-document"]),
			remove(c) { this.classes.delete(c); },
			add(c) { this.classes.add(c); },
		}
	};
	const labelMock = { textContent: "Copy" };

	el.iconMock = iconMock;
	el.labelMock = labelMock;

	const hook = { el };

	ClipboardCopy.mounted.call(hook);
	assert.equal(hook.originalAriaLabel, "Copy Token");

	// Trigger click
	await el.listeners["click"]();

	// Verify clipboard write
	assert.equal(writeTextCalledWith, "my-secret-key");

	// Verify label updates
	assert.equal(labelMock.textContent, "Copied!");
	assert.equal(el.getAttribute("aria-label"), "Copy Token - Copied!");

	// Verify aria-live announcement
	const srFeedback = el.children[0];
	assert.equal(srFeedback.textContent, "Copied!");

	// Verify timeout setup
	assert.ok(timeoutCallback);
	assert.equal(timeoutDelay, 1400);

	// Trigger timeout callback (restore)
	timeoutCallback();

	// Verify restored state
	assert.equal(labelMock.textContent, "Copy");
	assert.equal(el.getAttribute("aria-label"), "Copy Token");
	assert.equal(srFeedback.textContent, "");

	// Clean up globals
	delete globalThis.navigator;
	delete globalThis.window;
});

test("ClipboardCopy - handles rapid successive clicks without corrupting original state", async () => {
	const ClipboardCopy = getClipboardCopy();

	Object.defineProperty(globalThis, "navigator", {
		value: {
			clipboard: {
				writeText: async () => {},
			},
		},
		configurable: true,
		writable: true,
	});

	let activeTimeoutId = null;
	const timeoutsCleared = [];

	globalThis.window = {
		clearTimeout: (id) => {
			timeoutsCleared.push(id);
		},
		setTimeout: (callback) => {
			activeTimeoutId = 999;
			return activeTimeoutId;
		},
	};

	const el = new FakeElement(
		{ "aria-label": "Copy Token" },
		{ copyText: "my-secret-key", copiedLabel: "Copied!" }
	);

	const iconMock = {
		classList: {
			remove() {},
			add() {},
		}
	};
	const labelMock = { textContent: "Copy" };

	el.iconMock = iconMock;
	el.labelMock = labelMock;

	const hook = { el };

	ClipboardCopy.mounted.call(hook);

	// First click
	await el.listeners["click"]();
	assert.equal(el.getAttribute("aria-label"), "Copy Token - Copied!");

	// Second rapid click (before timeout)
	await el.listeners["click"]();
	assert.equal(timeoutsCleared.length, 2); // cleared initial undefined and then the first active timeout
	assert.equal(el.getAttribute("aria-label"), "Copy Token - Copied!"); // originalAriaLabel is still untouched and correct

	// Clean up globals
	delete globalThis.navigator;
	delete globalThis.window;
});
