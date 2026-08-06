import test from "node:test"
import assert from "node:assert/strict"

// The ClipboardCopy hook logic under test, copied exactly from assets/js/app.js
const ClipboardCopy = {
	mounted() {
		this.originalAriaLabel = this.el.getAttribute("aria-label");
		this.handleClick = async () => {
			const icon = this.el.querySelector(".copy-icon");
			const label = this.el.querySelector("[data-copy-label]");
			window.clearTimeout(this.timeout);
			await navigator.clipboard.writeText(this.el.dataset.copyText);

			const copiedText = this.el.dataset.copiedLabel || "Copied";

			if (label) {
				label.textContent = copiedText;
			}

			icon?.classList.remove("hero-clipboard-document");
			icon?.classList.add("hero-check");
			this.el.classList.add("btn-success");
			this.el.setAttribute("aria-label", copiedText);

			let announcer = document.getElementById("clipboard-live-announcer");
			if (!announcer) {
				announcer = document.createElement("div");
				announcer.id = "clipboard-live-announcer";
				announcer.className = "sr-only";
				announcer.setAttribute("aria-live", "polite");
				announcer.style.cssText = "position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0;";
				document.body.appendChild(announcer);
			}
			announcer.textContent = "";
			// Force browser repaint to trigger screen reader announcement
			void announcer.offsetHeight;
			announcer.textContent = copiedText;

			this.timeout = window.setTimeout(() => {
				icon?.classList.remove("hero-check");
				icon?.classList.add("hero-clipboard-document");
				this.el.classList.remove("btn-success");

				if (this.originalAriaLabel !== null) {
					this.el.setAttribute("aria-label", this.originalAriaLabel);
				} else {
					this.el.removeAttribute("aria-label");
				}

				if (label) {
					label.textContent = this.el.dataset.copyLabel || "Copy";
				}
				if (announcer) {
					announcer.textContent = "";
				}
			}, 1400);
		};

		this.el.addEventListener("click", this.handleClick);
	},
	destroyed() {
		this.el.removeEventListener("click", this.handleClick);
		window.clearTimeout(this.timeout);
		const announcer = document.getElementById("clipboard-live-announcer");
		if (announcer) {
			announcer.textContent = "";
		}
	},
};

// Set up minimal JSDOM-like environment
globalThis.document = {
  createElement(tag) {
    return {
      id: "",
      className: "",
      style: { cssText: "" },
      setAttribute(name, value) { this[name] = value },
      getAttribute(name) { return this[name] || "" },
      textContent: ""
    };
  },
  body: {
    appendChild(el) {
      globalThis.document.body.children.push(el);
    },
    children: []
  },
  getElementById(id) {
    return globalThis.document.body.children.find(el => el.id === id) || null;
  }
};

const mockClipboard = {
  written: "",
  async writeText(text) {
    this.written = text;
  }
};

Object.defineProperty(globalThis, "navigator", {
  value: {
    clipboard: mockClipboard
  },
  configurable: true,
  writable: true
});

globalThis.window = {
  clearTimeout(id) {
    globalThis.window.cleared = id;
  },
  setTimeout(fn, delay) {
    globalThis.window.timeoutFn = fn;
    globalThis.window.timeoutDelay = delay;
    return 42; // Dummy timer ID
  }
};

test("ClipboardCopy hook correctly mounts, copies, and cleans up", async () => {
  const mockElement = {
    dataset: {
      copyText: "hello-world-secret",
      copyLabel: "Copy",
      copiedLabel: "Copied!"
    },
    classList: {
      add(className) {
        this.classes = this.classes || [];
        this.classes.push(className);
      },
      remove(className) {
        this.classes = this.classes || [];
        this.classes = this.classes.filter(c => c !== className);
      }
    },
    getAttribute(name) {
      if (name === "aria-label") return "Copy button";
      return null;
    },
    setAttribute(name, value) {
      this.attributes = this.attributes || {};
      this.attributes[name] = value;
    },
    removeAttribute(name) {
      this.attributes = this.attributes || {};
      delete this.attributes[name];
    },
    querySelector(selector) {
      if (selector === ".copy-icon") return { classList: { remove() {}, add() {} } };
      if (selector === "[data-copy-label]") return { textContent: "" };
      return null;
    },
    addEventListener(event, handler) {
      this.listeners = this.listeners || {};
      this.listeners[event] = handler;
    },
    removeEventListener(event, handler) {
      if (this.listeners && this.listeners[event] === handler) {
        delete this.listeners[event];
      }
    }
  };

  const context = {
    el: mockElement,
    mounted: ClipboardCopy.mounted,
    destroyed: ClipboardCopy.destroyed
  };

  // 1. Mount hook
  context.mounted();
  assert.equal(context.originalAriaLabel, "Copy button");
  assert.ok(mockElement.listeners.click);

  // 2. Trigger copy click
  await mockElement.listeners.click();
  assert.equal(mockClipboard.written, "hello-world-secret");
  assert.equal(mockElement.attributes["aria-label"], "Copied!");

  const announcer = globalThis.document.getElementById("clipboard-live-announcer");
  assert.ok(announcer);
  assert.equal(announcer.textContent, "Copied!");

  // 3. Destroy hook
  context.destroyed();
  assert.deepEqual(mockElement.listeners, {});
});
