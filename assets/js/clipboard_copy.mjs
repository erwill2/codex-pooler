const announcerId = "clipboard-live-announcer";

function announce(message) {
	let region = document.getElementById(announcerId);
	if (!region) {
		region = document.createElement("div");
		region.id = announcerId;
		region.className = "sr-only";
		region.setAttribute("aria-live", "polite");
		region.setAttribute("aria-atomic", "true");
		document.body.appendChild(region);
	}
	region.textContent = "";
	window.setTimeout(() => {
		region.textContent = message;
	}, 50);
}

export const ClipboardCopy = {
	mounted() {
		this.originalAriaLabel = this.el.getAttribute("aria-label");
		this.handleClick = async () => {
			const copyText = this.el.dataset.copyText;
			if (!copyText) return;

			const icon = this.el.querySelector(".copy-icon");
			const label = this.el.querySelector("[data-copy-label]");
			const description =
				this.originalAriaLabel || this.el.dataset.copyLabel || "Text";

			try {
				await navigator.clipboard.writeText(copyText);
			} catch {
				announce(`Could not copy ${description.toLowerCase()}`);
				return;
			}

			window.clearTimeout(this.timeout);
			const copiedLabel = this.el.dataset.copiedLabel || "Copied";
			if (label) label.textContent = copiedLabel;
			icon?.classList.remove("hero-clipboard-document");
			icon?.classList.add("hero-check");
			this.el.classList.add("btn-success");
			this.el.setAttribute("aria-label", `${description} (${copiedLabel})`);
			announce(`${description} copied to clipboard`);

			this.timeout = window.setTimeout(() => {
				icon?.classList.remove("hero-check");
				icon?.classList.add("hero-clipboard-document");
				this.el.classList.remove("btn-success");
				if (label) label.textContent = this.el.dataset.copyLabel || "Copy";
				this.restoreAriaLabel();
			}, 1400);
		};
		this.restoreAriaLabel = () => {
			if (this.originalAriaLabel === null) this.el.removeAttribute("aria-label");
			else this.el.setAttribute("aria-label", this.originalAriaLabel);
		};
		this.el.addEventListener("click", this.handleClick);
	},
	destroyed() {
		window.clearTimeout(this.timeout);
		this.el.removeEventListener("click", this.handleClick);
		this.restoreAriaLabel();
	},
};
