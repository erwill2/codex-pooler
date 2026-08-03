export const ClipboardCopy = {
  mounted() {
    this.originalAriaLabel = this.el.getAttribute("aria-label");

    // Create a visually hidden aria-live="polite" element for polite copy announcements
    this.srContainer = document.createElement("span");
    this.srContainer.style.position = "absolute";
    this.srContainer.style.width = "1px";
    this.srContainer.style.height = "1px";
    this.srContainer.style.padding = "0";
    this.srContainer.style.margin = "-1px";
    this.srContainer.style.overflow = "hidden";
    this.srContainer.style.clip = "rect(0, 0, 0, 0)";
    this.srContainer.style.whiteSpace = "nowrap";
    this.srContainer.style.border = "0";
    this.srContainer.setAttribute("aria-live", "polite");
    document.body.appendChild(this.srContainer);

    this.handleClick = async () => {
      const icon = this.el.querySelector(".copy-icon");
      const label = this.el.querySelector("[data-copy-label]");
      window.clearTimeout(this.timeout);

      const copyText = this.el.dataset.copyText || "";
      const copiedLabel = this.el.dataset.copiedLabel || "Copied";

      if (navigator.clipboard) {
        try {
          await navigator.clipboard.writeText(copyText);
        } catch (err) {
          console.error("Failed to copy text: ", err);
        }
      }

      if (label) {
        label.textContent = copiedLabel;
      }

      // Update element's aria-label and announce to screen readers
      this.el.setAttribute("aria-label", copiedLabel);
      this.srContainer.textContent = `${copiedLabel} to clipboard`;

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

        this.srContainer.textContent = "";
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
    this.srContainer?.remove();
    if (this.originalAriaLabel) {
      this.el.setAttribute("aria-label", this.originalAriaLabel);
    } else {
      this.el.removeAttribute("aria-label");
    }
  },
};
