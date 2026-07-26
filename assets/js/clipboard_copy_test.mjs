import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"

// Read and extract ClipboardCopy from app.js
const appJsPath = path.resolve("js/app.js");
const appContent = fs.readFileSync(appJsPath, "utf8");

const startIdx = appContent.indexOf("const ClipboardCopy = {");
const endIdx = appContent.indexOf("const WorkerFailureMarker = {");

if (startIdx === -1 || endIdx === -1) {
  throw new Error("Could not extract ClipboardCopy definition from app.js");
}

const clipboardCopyCode = appContent.slice(startIdx, endIdx);

const getClipboardCopy = () => {
  const codeToEval = `
    (function() {
      ${clipboardCopyCode}
      return ClipboardCopy;
    })()
  `;
  return eval(codeToEval);
};

test("ClipboardCopy hook mount, click, and timeout flow", async () => {
  const ClipboardCopy = getClipboardCopy();

  // Mock document body and announcer state
  let announcerElement = null;
  const mockAnnouncer = {
    id: "clipboard-announcer",
    className: "",
    attributes: {},
    textContent: "",
    setAttribute(name, val) {
      this.attributes[name] = val;
    }
  };

  const mockBody = {
    appendChild(el) {
      announcerElement = el;
    }
  };

  // Mock globals
  const originalDocument = globalThis.document;
  const originalWindow = globalThis.window;
  const originalNavigator = globalThis.navigator;

  let writeTextCalledWith = null;
  let timeoutCallback = null;
  let timeoutMs = null;
  let clearTimeoutCalledWith = null;

  globalThis.navigator = {
    clipboard: {
      async writeText(text) {
        writeTextCalledWith = text;
      }
    }
  };

  globalThis.window = {
    clearTimeout(id) {
      clearTimeoutCalledWith = id;
    },
    setTimeout(callback, ms) {
      timeoutCallback = callback;
      timeoutMs = ms;
      return 12345; // mock timer ID
    },
    requestAnimationFrame(callback) {
      callback();
    }
  };

  globalThis.document = {
    body: mockBody,
    getElementById(id) {
      if (id === "clipboard-announcer") {
        return announcerElement;
      }
      return null;
    },
    createElement(tag) {
      if (tag === "div") {
        return mockAnnouncer;
      }
      return {};
    }
  };

  // Mock element
  const iconClasses = new Set(["hero-clipboard-document"]);
  const elClasses = new Set(["some-btn"]);
  const mockIcon = {
    classList: {
      remove(cls) { iconClasses.delete(cls); },
      add(cls) { iconClasses.add(cls); }
    }
  };
  const mockLabel = {
    textContent: "Copy"
  };

  let elAttributes = {
    "aria-label": "Copy code to clipboard"
  };
  let clickListener = null;

  const context = {
    el: {
      dataset: {
        copyText: "hello world code",
        copiedLabel: "Copied!",
        copyLabel: "Copy"
      },
      getAttribute(name) {
        return elAttributes[name] || null;
      },
      setAttribute(name, val) {
        elAttributes[name] = val;
      },
      removeAttribute(name) {
        delete elAttributes[name];
      },
      querySelector(selector) {
        if (selector === ".copy-icon") return mockIcon;
        if (selector === "[data-copy-label]") return mockLabel;
        return null;
      },
      addEventListener(event, callback) {
        if (event === "click") {
          clickListener = callback;
        }
      },
      classList: {
        add(cls) { elClasses.add(cls); },
        remove(cls) { elClasses.delete(cls); }
      }
    },
    timeout: 999
  };

  // Run mount
  ClipboardCopy.mounted.call(context);

  // Assertions after mount
  assert.equal(context.originalAriaLabel, "Copy code to clipboard");
  assert.ok(clickListener !== null);

  // Trigger click
  await clickListener();

  // Assertions after click
  assert.equal(clearTimeoutCalledWith, 999);
  assert.equal(writeTextCalledWith, "hello world code");
  assert.equal(mockLabel.textContent, "Copied!");
  assert.equal(elAttributes["aria-label"], "Copied!");

  // Verify announcer was created and set
  assert.ok(announcerElement !== null);
  assert.equal(announcerElement.id, "clipboard-announcer");
  assert.equal(announcerElement.attributes["aria-live"], "polite");
  assert.equal(announcerElement.attributes["aria-atomic"], "true");
  assert.equal(announcerElement.textContent, "Copied!");

  // Verify visual changes on the element
  assert.ok(iconClasses.has("hero-check"));
  assert.ok(!iconClasses.has("hero-clipboard-document"));
  assert.ok(elClasses.has("btn-success"));

  // Verify timeout was scheduled
  assert.equal(timeoutMs, 1400);
  assert.ok(timeoutCallback !== null);

  // Execute the timeout
  timeoutCallback();

  // Assertions after timeout
  assert.ok(!iconClasses.has("hero-check"));
  assert.ok(iconClasses.has("hero-clipboard-document"));
  assert.ok(!elClasses.has("btn-success"));
  assert.equal(elAttributes["aria-label"], "Copy code to clipboard"); // restored original label
  assert.equal(mockLabel.textContent, "Copy");

  // TEST CASE 2: No initial aria-label
  elAttributes = {};
  clickListener = null;
  const context2 = {
    el: {
      ...context.el,
      getAttribute(name) {
        return elAttributes[name] || null;
      },
      setAttribute(name, val) {
        elAttributes[name] = val;
      },
      removeAttribute(name) {
        delete elAttributes[name];
      },
      addEventListener(event, callback) {
        if (event === "click") {
          clickListener = callback;
        }
      }
    },
    timeout: 888
  };

  ClipboardCopy.mounted.call(context2);
  assert.equal(context2.originalAriaLabel, "");
  assert.ok(clickListener !== null);

  await clickListener();
  assert.equal(elAttributes["aria-label"], "Copied!");

  timeoutCallback();
  // Ensure aria-label was completely removed
  assert.equal(elAttributes["aria-label"], undefined);

  // Cleanup globals
  globalThis.document = originalDocument;
  globalThis.window = originalWindow;
  globalThis.navigator = originalNavigator;
});
