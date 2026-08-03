import test from "node:test";
import assert from "node:assert/strict";
import { ClipboardCopy } from "./clipboard_copy.mjs";

test("ClipboardCopy Hook - mounted & clicked & timeout & destroyed lifecycle", async () => {
  const origDocument = globalThis.document;
  const origClipboard = globalThis.navigator?.clipboard;
  const origSetTimeout = globalThis.setTimeout;
  const origClearTimeout = globalThis.clearTimeout;
  const origWindow = globalThis.window;

  // Mock window and setTimeout/clearTimeout
  globalThis.window = globalThis;
  let timeoutCallback = null;
  let timeoutDelay = null;
  let timeoutId = null;

  globalThis.setTimeout = (cb, delay) => {
    timeoutCallback = cb;
    timeoutDelay = delay;
    timeoutId = 123;
    return timeoutId;
  };
  globalThis.clearTimeout = (id) => {
    if (id === timeoutId) {
      timeoutCallback = null;
      timeoutDelay = null;
      timeoutId = null;
    }
  };

  // Mock document
  const createdElements = [];
  const mockDocument = {
    createElement(tag) {
      const el = {
        tagName: tag.toUpperCase(),
        style: {},
        setAttribute(name, value) {
          this[name] = value;
        },
        remove() {
          this.removed = true;
        },
      };
      createdElements.push(el);
      return el;
    },
    body: {
      appendChild(child) {
        mockDocument.body.children.push(child);
      },
      children: [],
    },
  };

  // Mock navigator
  let writtenText = null;
  const mockClipboard = {
    async writeText(text) {
      writtenText = text;
    },
  };

  globalThis.document = mockDocument;
  if (globalThis.navigator) {
    Object.defineProperty(globalThis.navigator, "clipboard", {
      value: mockClipboard,
      configurable: true,
      writable: true,
    });
  } else {
    Object.defineProperty(globalThis, "navigator", {
      value: { clipboard: mockClipboard },
      configurable: true,
      writable: true,
    });
  }

  try {
    // Setup hook context
    const mockIcon = {
      classList: {
        add(cls) {
          this.classes.add(cls);
        },
        remove(cls) {
          this.classes.delete(cls);
        },
        classes: new Set(["hero-clipboard-document"]),
      },
    };
    const mockLabel = {
      textContent: "Copy",
    };

    const elementClasses = new Set();
    const attributes = { "aria-label": "Initial Copy Label" };
    const mockEl = {
      dataset: {
        copyText: "secret-key-123",
        copyLabel: "Copy",
        copiedLabel: "Copied!",
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
        return null;
      },
      addEventListener(event, handler) {
        this.listeners[event] = handler;
      },
      removeEventListener(event, handler) {
        if (this.listeners[event] === handler) {
          delete this.listeners[event];
        }
      },
      classList: {
        add(cls) {
          elementClasses.add(cls);
        },
        remove(cls) {
          elementClasses.delete(cls);
        },
      },
      listeners: {},
    };

    const context = {
      el: mockEl,
      ...ClipboardCopy,
    };

    // 1. Test mounted()
    context.mounted();

    assert.equal(context.originalAriaLabel, "Initial Copy Label");
    assert.equal(createdElements.length, 1);
    assert.equal(createdElements[0].tagName, "SPAN");
    assert.equal(createdElements[0]["aria-live"], "polite");
    assert.equal(mockDocument.body.children.length, 1);
    assert.equal(mockDocument.body.children[0], createdElements[0]);
    assert.ok(mockEl.listeners.click);

    // 2. Test click interaction
    await mockEl.listeners.click();

    assert.equal(writtenText, "secret-key-123");
    assert.equal(mockLabel.textContent, "Copied!");
    assert.equal(attributes["aria-label"], "Copied!");
    assert.equal(createdElements[0].textContent, "Copied! to clipboard");
    assert.ok(mockIcon.classList.classes.has("hero-check"));
    assert.ok(!mockIcon.classList.classes.has("hero-clipboard-document"));
    assert.ok(elementClasses.has("btn-success"));
    assert.equal(timeoutId, 123);
    assert.equal(timeoutDelay, 1400);
    assert.ok(timeoutCallback);

    // 3. Test timeout callback execution
    const savedCallback = timeoutCallback;
    savedCallback();

    assert.equal(mockLabel.textContent, "Copy");
    assert.equal(attributes["aria-label"], "Initial Copy Label");
    assert.equal(createdElements[0].textContent, "");
    assert.ok(!mockIcon.classList.classes.has("hero-check"));
    assert.ok(mockIcon.classList.classes.has("hero-clipboard-document"));
    assert.ok(!elementClasses.has("btn-success"));

    // 4. Test destroyed() cleanup
    context.destroyed();

    assert.equal(mockEl.listeners.click, undefined);
    assert.equal(createdElements[0].removed, true);
    assert.equal(attributes["aria-label"], "Initial Copy Label");
  } finally {
    globalThis.document = origDocument;
    if (globalThis.navigator) {
      Object.defineProperty(globalThis.navigator, "clipboard", {
        value: origClipboard,
        configurable: true,
        writable: true,
      });
    }
    globalThis.setTimeout = origSetTimeout;
    globalThis.clearTimeout = origClearTimeout;
    globalThis.window = origWindow;
  }
});
