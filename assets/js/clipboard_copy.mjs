export const ClipboardCopy = {
	mounted() {
		this.originalAriaLabel = this.el.getAttribute("aria-label") || "";
		this.timeout = null;

		// Ensure a visually hidden live region exists within the button
		let liveEl = this.el.querySelector(".sr-only[aria-live]");
		if (!liveEl) {
			liveEl = document.createElement("span");
			liveEl.className = "sr-only";
			liveEl.setAttribute("aria-live", "polite");
			this.el.appendChild(liveEl);
		}
		this.liveEl = liveEl;

		this.el.addEventListener("click", async () => {
			const icon = this.el.querySelector(".copy-icon");
			const label = this.el.querySelector("[data-copy-label]");
			window.clearTimeout(this.timeout);
			await navigator.clipboard.writeText(this.el.dataset.copyText);

			const copiedText = this.el.dataset.copiedLabel || "Copied";

			if (label) {
				label.textContent = copiedText;
			}

			// Dynamic aria-label and live-region announcements
			this.el.setAttribute("aria-label", copiedText);
			this.liveEl.textContent = copiedText;

			icon?.classList.remove("hero-clipboard-document");
			icon?.classList.add("hero-check");
			this.el.classList.add("btn-success");

			this.timeout = window.setTimeout(() => {
				icon?.classList.remove("hero-check");
				icon?.classList.add("hero-clipboard-document");
				this.el.classList.remove("btn-success");

				if (label) {
					label.textContent = this.el.dataset.copyLabel || "Copy";
				}

				// Revert to original cached aria-label and clear live region
				if (this.originalAriaLabel) {
					this.el.setAttribute("aria-label", this.originalAriaLabel);
				} else {
					this.el.removeAttribute("aria-label");
				}
				this.liveEl.textContent = "";
			}, 1400);
		});
	},
	destroyed() {
		window.clearTimeout(this.timeout);
	},
};
