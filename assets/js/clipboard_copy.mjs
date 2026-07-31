export const ClipboardCopy = {
	mounted() {
		this.hasOriginalAriaLabel = this.el.hasAttribute("aria-label");
		this.originalAriaLabel = this.hasOriginalAriaLabel ? this.el.getAttribute("aria-label") : null;

		this.liveRegion = document.createElement("div");
		this.liveRegion.className = "sr-only";
		this.liveRegion.setAttribute("aria-live", "polite");
		this.el.appendChild(this.liveRegion);

		this.clickHandler = async () => {
			const icon = this.el.querySelector(".copy-icon");
			const label = this.el.querySelector("[data-copy-label]");
			window.clearTimeout(this.timeout);
			try {
				await navigator.clipboard.writeText(this.el.dataset.copyText);
			} catch (err) {
				// Fallback if clipboard API fails
			}

			const copiedText = this.el.dataset.copiedLabel || "Copied";
			if (label) {
				label.textContent = copiedText;
			}
			this.el.setAttribute("aria-label", copiedText);
			this.liveRegion.textContent = copiedText;

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

				if (this.hasOriginalAriaLabel) {
					this.el.setAttribute("aria-label", this.originalAriaLabel);
				} else {
					this.el.removeAttribute("aria-label");
				}
				this.liveRegion.textContent = "";
			}, 1400);
		};

		this.el.addEventListener("click", this.clickHandler);
	},
	destroyed() {
		window.clearTimeout(this.timeout);
		this.el.removeEventListener("click", this.clickHandler);
		this.liveRegion?.remove();
		if (this.hasOriginalAriaLabel) {
			this.el.setAttribute("aria-label", this.originalAriaLabel);
		} else {
			this.el.removeAttribute("aria-label");
		}
	},
};
