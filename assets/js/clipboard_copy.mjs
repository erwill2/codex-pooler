export function getOrCreateAnnouncer() {
	let announcer = document.getElementById("clipboard-live-announcer");
	if (!announcer) {
		announcer = document.createElement("div");
		announcer.id = "clipboard-live-announcer";
		announcer.className = "sr-only";
		announcer.setAttribute("aria-live", "polite");
		announcer.setAttribute("aria-atomic", "true");
		document.body.appendChild(announcer);
	}
	return announcer;
}

export function announceCopy(description) {
	const announcer = getOrCreateAnnouncer();
	announcer.textContent = "";
	window.setTimeout(() => {
		announcer.textContent = `${description} copied to clipboard`;
	}, 50);
}

export const ClipboardCopy = {
	mounted() {
		this.originalAriaLabel = this.el.getAttribute("aria-label");
		this.originalTitle = this.el.getAttribute("title");

		this.handleClick = async () => {
			const copyText = this.el.dataset.copyText;
			if (!copyText) return;

			const icon = this.el.querySelector(".copy-icon");
			const label = this.el.querySelector("[data-copy-label]");
			const desc =
				this.originalAriaLabel ||
				this.originalTitle ||
				label?.textContent ||
				"Text";

			window.clearTimeout(this.timeout);

			try {
				await navigator.clipboard.writeText(copyText);
			} catch (_error) {
				return;
			}

			const copiedLabelText = this.el.dataset.copiedLabel || "Copied";
			if (label) {
				label.textContent = copiedLabelText;
			}

			icon?.classList.remove("hero-clipboard-document");
			icon?.classList.add("hero-check");
			this.el.classList.add("btn-success");

			this.el.setAttribute("aria-label", `${desc} (${copiedLabelText})`);
			announceCopy(desc);

			this.timeout = window.setTimeout(() => {
				icon?.classList.remove("hero-check");
				icon?.classList.add("hero-clipboard-document");
				this.el.classList.remove("btn-success");

				if (label) {
					label.textContent = this.el.dataset.copyLabel || "Copy";
				}

				if (this.originalAriaLabel) {
					this.el.setAttribute("aria-label", this.originalAriaLabel);
				} else {
					this.el.removeAttribute("aria-label");
				}
			}, 1400);
		};

		this.el.addEventListener("click", this.handleClick);
	},
	destroyed() {
		window.clearTimeout(this.timeout);
		this.el.removeEventListener("click", this.handleClick);
	},
};
