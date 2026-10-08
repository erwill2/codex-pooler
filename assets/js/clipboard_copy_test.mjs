import assert from "node:assert/strict";
import test from "node:test";
import { ClipboardCopy } from "./clipboard_copy.mjs";

function setup(copyResult = Promise.resolve()) {
	const elements = new Map();
	const attributes = new Map([["aria-label", "Copy API key prefix"]]);
	const classes = new Set();
	const listeners = new Map();
	const iconClasses = new Set(["hero-clipboard-document"]);
	const label = { textContent: "Copy" };
	const button = {
		dataset: { copyText: "private-value", copyLabel: "Copy" },
		classList: {
			add: (name) => classes.add(name),
			remove: (name) => classes.delete(name),
		},
		getAttribute: (name) => attributes.get(name) ?? null,
		setAttribute: (name, value) => attributes.set(name, value),
		removeAttribute: (name) => attributes.delete(name),
		querySelector: (selector) =>
			selector === ".copy-icon"
				? {
					classList: {
						add: (name) => iconClasses.add(name),
						remove: (name) => iconClasses.delete(name),
					},
				}
				: label,
		addEventListener: (name, handler) => listeners.set(name, handler),
		removeEventListener: (name, handler) => {
			if (listeners.get(name) === handler) listeners.delete(name);
		},
	};
	globalThis.document = {
		getElementById: (id) => elements.get(id) ?? null,
		createElement: () => ({
			setAttribute(name, value) {
				this[name] = value;
			},
		}),
		body: { appendChild: (element) => elements.set(element.id, element) },
	};
	globalThis.window = globalThis;
	Object.defineProperty(globalThis, "navigator", {
		configurable: true,
		value: { clipboard: { writeText: () => copyResult } },
	});
	return { button, attributes, classes, elements, label, listeners };
}

test("copy announces a safe description and restores its original label", async () => {
	const { button, attributes, classes, elements, label, listeners } = setup();
	const hook = { el: button };
	ClipboardCopy.mounted.call(hook);
	await listeners.get("click")();
	assert.equal(label.textContent, "Copied");
	assert.equal(attributes.get("aria-label"), "Copy API key prefix (Copied)");
	assert.equal(classes.has("btn-success"), true);
	await new Promise((resolve) => setTimeout(resolve, 80));
	assert.equal(
		elements.get("clipboard-live-announcer").textContent,
		"Copy API key prefix copied to clipboard",
	);
	ClipboardCopy.destroyed.call(hook);
	assert.equal(attributes.get("aria-label"), "Copy API key prefix");
	assert.equal(listeners.has("click"), false);
});

test("failed copy does not show success", async () => {
	const { button, classes, label, listeners } = setup(
		Promise.reject(new Error("denied")),
	);
	const hook = { el: button };
	ClipboardCopy.mounted.call(hook);
	await listeners.get("click")();
	assert.equal(label.textContent, "Copy");
	assert.equal(classes.has("btn-success"), false);
	ClipboardCopy.destroyed.call(hook);
});
