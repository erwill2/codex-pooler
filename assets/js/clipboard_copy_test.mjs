import test from "node:test";
import assert from "node:assert/strict";
import { ClipboardCopy } from "./clipboard_copy.mjs";

test("ClipboardCopy caches original aria-label and sets up live region", () => {
	const appendedChildren = [];
	const mockEl = {
		getAttribute(name) {
			if (name === "aria-label") return "Copy item description";
			return null;
		},
		querySelector(selector) {
			if (selector === ".sr-only[aria-live]") return null;
			return null;
		},
		appendChild(child) {
			appendedChildren.push(child);
		},
		addEventListener() {},
	};

	const context = {
		el: mockEl,
	};

	// Mock document.createElement globally for this test
	const originalCreateElement = globalThis.document?.createElement;
	globalThis.document = {
		createElement(tagName) {
			return {
				tagName,
				attributes: {},
				setAttribute(name, value) {
					this.attributes[name] = value;
				},
			};
		},
	};

	ClipboardCopy.mounted.call(context);

	assert.equal(context.originalAriaLabel, "Copy item description");
	assert.equal(appendedChildren.length, 1);
	assert.equal(appendedChildren[0].tagName, "span");
	assert.equal(appendedChildren[0].className, "sr-only");
	assert.equal(appendedChildren[0].attributes["aria-live"], "polite");

	// Clean up globalThis
	if (originalCreateElement) {
		globalThis.document.createElement = originalCreateElement;
	} else {
		delete globalThis.document;
	}
});

test("ClipboardCopy click interaction triggers clipboard copy and updates label/ARIA", async () => {
	let clickHandler = null;
	const mockIcon = {
		classList: {
			removed: [],
			added: [],
			remove(cls) {
				this.removed.push(cls);
			},
			add(cls) {
				this.added.push(cls);
			},
		},
	};
	const mockLabel = { textContent: "Copy" };
	const mockLiveEl = { textContent: "" };

	const attributes = { "aria-label": "Initial Label" };
	const elementClasses = [];

	const mockEl = {
		dataset: {
			copyText: "Hello World",
			copiedLabel: "Copied!",
			copyLabel: "Copy",
		},
		getAttribute(name) {
			return attributes[name] || null;
		},
		setAttribute(name, value) {
			attributes[name] = value;
		},
		removeAttribute(name) {
			delete attributes[name];
		},
		querySelector(selector) {
			if (selector === ".copy-icon") return mockIcon;
			if (selector === "[data-copy-label]") return mockLabel;
			if (selector === ".sr-only[aria-live]") return mockLiveEl;
			return null;
		},
		addEventListener(event, handler) {
			if (event === "click") {
				clickHandler = handler;
			}
		},
		classList: {
			add(cls) {
				elementClasses.push(cls);
			},
			remove(cls) {
				const index = elementClasses.indexOf(cls);
				if (index > -1) elementClasses.splice(index, 1);
			},
		},
	};

	const context = {
		el: mockEl,
	};

	// Save original navigator and window
	const originalNavigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
	const originalWindowDescriptor = Object.getOwnPropertyDescriptor(globalThis, "window");

	// Mock navigator.clipboard
	let copiedData = null;
	Object.defineProperty(globalThis, "navigator", {
		value: {
			clipboard: {
				async writeText(text) {
					copiedData = text;
				},
			},
		},
		configurable: true,
		writable: true,
	});

	// Mock setTimeout to capture delay
	let timeoutDelay = null;
	let timeoutCallback = null;
	Object.defineProperty(globalThis, "window", {
		value: {
			clearTimeout() {},
			setTimeout(cb, delay) {
				timeoutCallback = cb;
				timeoutDelay = delay;
				return 42;
			},
		},
		configurable: true,
		writable: true,
	});

	ClipboardCopy.mounted.call(context);

	assert.notEqual(clickHandler, null);

	// Trigger click
	await clickHandler();

	assert.equal(copiedData, "Hello World");
	assert.equal(mockLabel.textContent, "Copied!");
	assert.equal(attributes["aria-label"], "Copied!");
	assert.equal(mockLiveEl.textContent, "Copied!");
	assert.deepEqual(mockIcon.classList.removed, ["hero-clipboard-document"]);
	assert.deepEqual(mockIcon.classList.added, ["hero-check"]);
	assert.deepEqual(elementClasses, ["btn-success"]);
	assert.equal(timeoutDelay, 1400);

	// Trigger timeout callback
	mockIcon.classList.removed = [];
	mockIcon.classList.added = [];
	timeoutCallback();

	assert.deepEqual(mockIcon.classList.removed, ["hero-check"]);
	assert.deepEqual(mockIcon.classList.added, ["hero-clipboard-document"]);
	assert.deepEqual(elementClasses, []);
	assert.equal(mockLabel.textContent, "Copy");
	assert.equal(attributes["aria-label"], "Initial Label");
	assert.equal(mockLiveEl.textContent, "");

	// Restore original navigator and window descriptors
	if (originalNavigatorDescriptor) {
		Object.defineProperty(globalThis, "navigator", originalNavigatorDescriptor);
	} else {
		delete globalThis.navigator;
	}

	if (originalWindowDescriptor) {
		Object.defineProperty(globalThis, "window", originalWindowDescriptor);
	} else {
		delete globalThis.window;
	}
});
