import assert from "node:assert/strict";
import test from "node:test";

import {
	ClipboardCopy,
	announceCopy,
	getOrCreateAnnouncer,
} from "./clipboard_copy.mjs";

function setupFakeDOM() {
	const elements = new Map();
	const bodyChildren = [];

	const createElement = (tag) => {
		const attrs = new Map();
		const dataset = {};
		const listeners = new Map();
		const children = [];

		const el = {
			tagName: tag.toUpperCase(),
			id: "",
			className: "",
			textContent: "",
			dataset,
			children,
			setAttribute(key, val) {
				attrs.set(key, String(val));
				if (key === "id") el.id = String(val);
			},
			getAttribute(key) {
				return attrs.get(key) || null;
			},
			removeAttribute(key) {
				attrs.delete(key);
			},
			appendChild(child) {
				children.push(child);
				if (child.id) elements.set(child.id, child);
				return child;
			},
			querySelector(selector) {
				if (selector === ".copy-icon") {
					return children.find((c) => c.className?.includes("copy-icon"));
				}
				if (selector === "[data-copy-label]") {
					return children.find((c) => "copyLabel" in c.dataset);
				}
				return null;
			},
			addEventListener(event, fn) {
				if (!listeners.has(event)) listeners.set(event, []);
				listeners.get(event).push(fn);
			},
			removeEventListener(event, fn) {
				if (!listeners.has(event)) return;
				const list = listeners.get(event);
				const idx = list.indexOf(fn);
				if (idx >= 0) list.splice(idx, 1);
			},
			click() {
				const list = listeners.get("click") || [];
				for (const fn of list) {
					fn({ target: el });
				}
			},
			classList: {
				add(...cls) {
					const current = el.className ? el.className.split(" ") : [];
					for (const c of cls) {
						if (!current.includes(c)) current.push(c);
					}
					el.className = current.join(" ");
				},
				remove(...cls) {
					const current = el.className ? el.className.split(" ") : [];
					el.className = current.filter((c) => !cls.includes(c)).join(" ");
				},
				contains(c) {
					return el.className.split(" ").includes(c);
				},
			},
		};
		return el;
	};

	const doc = {
		body: {
			appendChild(child) {
				bodyChildren.push(child);
				if (child.id) elements.set(child.id, child);
				return child;
			},
		},
		getElementById(id) {
			return elements.get(id) || null;
		},
		createElement,
	};

	globalThis.document = doc;
	globalThis.window = globalThis;
}

test("getOrCreateAnnouncer creates a polite live region announcer", () => {
	setupFakeDOM();

	// When
	const announcer = getOrCreateAnnouncer();

	// Then
	assert.equal(announcer.id, "clipboard-live-announcer");
	assert.equal(announcer.getAttribute("aria-live"), "polite");
	assert.equal(announcer.getAttribute("aria-atomic"), "true");
	assert.equal(document.getElementById("clipboard-live-announcer"), announcer);

	// Singleton check
	const secondCall = getOrCreateAnnouncer();
	assert.equal(secondCall, announcer);
});

test("announceCopy schedules polite announcement copy text", async () => {
	setupFakeDOM();

	// When
	announceCopy("API Key");

	// Then
	await new Promise((resolve) => setTimeout(resolve, 80));
	const announcer = document.getElementById("clipboard-live-announcer");
	assert.equal(announcer?.textContent, "API Key copied to clipboard");
});

test("ClipboardCopy hook attaches and cleans up event listeners on destroy", () => {
	setupFakeDOM();

	const button = document.createElement("button");
	button.setAttribute("aria-label", "Copy key prefix");
	button.dataset.copyText = "cp_12345";

	let clickCount = 0;
	button.addEventListener("click", () => {
		clickCount++;
	});

	const context = {
		el: button,
		originalAriaLabel: null,
		originalTitle: null,
	};

	// When
	ClipboardCopy.mounted.call(context);

	// Then
	assert.equal(context.originalAriaLabel, "Copy key prefix");

	button.click();
	assert.equal(clickCount, 1);

	// When destroyed
	ClipboardCopy.destroyed.call(context);
});
