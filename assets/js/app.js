// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/codex_pooler"
import {renderSVG} from "uqr"
import topbar from "topbar"
import {classifyLiveSocketConnection} from "./live_socket_connection.mjs"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const ClipboardCopy = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const icon = this.el.querySelector(".copy-icon")
      const label = this.el.querySelector("[data-copy-label]")
      window.clearTimeout(this.timeout)
      await navigator.clipboard.writeText(this.el.dataset.copyText)

      if (label) {
        label.textContent = this.el.dataset.copiedLabel || "Copied"
      }

      icon?.classList.remove("hero-clipboard-document")
      icon?.classList.add("hero-check")
      this.el.classList.add("btn-success")

      this.timeout = window.setTimeout(() => {
        icon?.classList.remove("hero-check")
        icon?.classList.add("hero-clipboard-document")
        this.el.classList.remove("btn-success")

        if (label) {
          label.textContent = this.el.dataset.copyLabel || "Copy"
        }
      }, 1400)
    })
  },
  destroyed() {
    window.clearTimeout(this.timeout)
  },
}
const TotpSetupTools = {
  mounted() {
    this.renderQr()
  },
  updated() {
    this.renderQr()
  },
  renderQr() {
    const target = this.el.querySelector("[data-totp-qr]")
    const uri = this.el.dataset.otpauthUri

    if (!target || !uri) return

    try {
      const size = Number.parseInt(target.dataset.qrSize || "176", 10)
      const svg = renderSVG(uri, {border: 1})
        .replaceAll('fill="white"', 'fill="#f7f7f7"')
        .replaceAll('fill="black"', 'fill="#0e0e0e"')

      target.innerHTML = svg

      const rendered = target.querySelector("svg")
      rendered?.setAttribute("width", size.toString())
      rendered?.setAttribute("height", size.toString())
      rendered?.setAttribute("role", "img")
      rendered?.setAttribute("aria-label", "Authenticator app QR code")
    } catch (_error) {
      target.replaceWith(Object.assign(document.createElement("p"), {
        className: "text-sm text-error",
        textContent: "QR code could not be rendered",
      }))
    }
  },
}
const FlashAutoDismiss = {
  mounted() {
    if (this.el.hasAttribute("hidden")) return

    const timeout = this.el.dataset.flashKind === "error" ? 7000 : 4200
    this.timer = window.setTimeout(() => {
      this.dismiss()
    }, timeout)
  },
  dismiss() {
    if (this.dismissing) return

    this.dismissing = true
    this.el.classList.add(
      "opacity-0",
      "translate-y-2",
      "scale-95",
      "transition-all",
      "duration-200",
      "ease-in"
    )

    window.setTimeout(() => {
      this.pushEvent("lv:clear-flash", {key: this.el.dataset.flashKind})
      this.el.remove()
    }, 200)
  },
  destroyed() {
    window.clearTimeout(this.timer)
  },
}
const OtpInput = {
  mounted() {
    this.hiddenInput = this.el.querySelector("[data-otp-value]")
    this.slots = Array.from(this.el.querySelectorAll("[data-otp-slot]"))
    this.length = Number.parseInt(this.el.dataset.otpLength || this.slots.length.toString(), 10)

    this.slots.forEach((slot, index) => {
      slot.addEventListener("input", () => this.handleInput(index))
      slot.addEventListener("keydown", event => this.handleKeydown(event, index))
      slot.addEventListener("paste", event => this.handlePaste(event, index))
      slot.addEventListener("focus", () => slot.select())
    })

    this.syncSlotsFromValue()
  },
  handleInput(index) {
    const slot = this.slots[index]
    const digits = this.onlyDigits(slot.value)

    if (digits.length > 1) {
      this.fillFrom(index, digits)
      return
    }

    slot.value = digits
    this.syncValueFromSlots()

    if (digits && index < this.slots.length - 1) {
      this.focusSlot(index + 1)
    }
  },
  handleKeydown(event, index) {
    if (event.metaKey || event.ctrlKey || event.altKey) return

    if (event.key === "Backspace") {
      if (this.slots[index].value === "" && index > 0) {
        event.preventDefault()
        this.focusSlot(index - 1)
        this.slots[index - 1].value = ""
        this.syncValueFromSlots()
      }

      return
    }

    if (event.key === "Delete") {
      this.slots[index].value = ""
      this.syncValueFromSlots()
      return
    }

    if (event.key === "ArrowLeft" && index > 0) {
      event.preventDefault()
      this.focusSlot(index - 1)
      return
    }

    if (event.key === "ArrowRight" && index < this.slots.length - 1) {
      event.preventDefault()
      this.focusSlot(index + 1)
      return
    }

    if (event.key.length === 1 && !/\d/.test(event.key)) {
      event.preventDefault()
    }
  },
  handlePaste(event, index) {
    const digits = this.onlyDigits(event.clipboardData?.getData("text") || "")

    if (!digits) return

    event.preventDefault()
    this.fillFrom(index, digits)
  },
  fillFrom(index, digits) {
    digits
      .slice(0, this.slots.length - index)
      .split("")
      .forEach((digit, offset) => {
        this.slots[index + offset].value = digit
      })

    this.syncValueFromSlots()
    this.focusSlot(Math.min(index + digits.length, this.slots.length - 1))
  },
  syncSlotsFromValue() {
    const digits = this.onlyDigits(this.hiddenInput?.value || "").slice(0, this.length)

    this.slots.forEach((slot, index) => {
      slot.value = digits[index] || ""
    })

    this.syncValueFromSlots()
  },
  syncValueFromSlots() {
    if (!this.hiddenInput) return

    this.hiddenInput.value = this.slots.map(slot => slot.value).join("").slice(0, this.length)
    this.hiddenInput.dispatchEvent(new Event("input", {bubbles: true}))
    this.hiddenInput.dispatchEvent(new Event("change", {bubbles: true}))
  },
  focusSlot(index) {
    const slot = this.slots[index]

    if (slot) {
      slot.focus()
      slot.select()
    }
  },
  onlyDigits(value) {
    return value.replace(/\D/g, "")
  },
}
const CONNECTION_VISUAL_STATES = {
  connecting: {
    dataState: "connecting",
    icon: "hero-wifi",
    toneClass: "text-base-content/45",
    buttonToneClass: "text-base-content/60",
    label: "Admin page live updates: connecting",
    stateText: "connecting",
  },
  websocketConnected: {
    dataState: "connected",
    icon: "hero-wifi",
    toneClass: "text-success",
    buttonToneClass: "text-success",
    label: "Admin page live updates: connected via WebSocket",
    stateText: "connected via WebSocket",
  },
  longPollFallback: {
    dataState: "fallback",
    icon: "hero-exclamation-triangle",
    toneClass: "text-warning",
    buttonToneClass: "text-warning",
    label: "Admin page live updates: long polling fallback",
    stateText: "long polling",
  },
  disconnected: {
    dataState: "disconnected",
    icon: "hero-x-circle",
    toneClass: "text-error",
    buttonToneClass: "text-error",
    label: "Admin page live updates: disconnected",
    stateText: "disconnected",
  },
}
const CONNECTION_TONE_CLASSES = Object.values(CONNECTION_VISUAL_STATES).flatMap(state => [
  state.toneClass,
  state.buttonToneClass,
])
const CONNECTION_ICON_CLASSES = Object.values(CONNECTION_VISUAL_STATES).map(state => state.icon)

const WebSocketState = {
  mounted() {
    this.updateState()
    this.interval = window.setInterval(() => this.updateState(), 1000)
  },
  destroyed() {
    window.clearInterval(this.interval)
  },
  updateState() {
    const liveSocket = window.liveSocket
    const socket = liveSocket?.socket
    const connection = classifyLiveSocketConnection(liveSocket, socket)
    const visualState = CONNECTION_VISUAL_STATES[connection.visualState]
    const endpoint = socket?.endPoint || "/live"
    const heartbeat = socket?.heartbeatIntervalMs ? `${socket.heartbeatIntervalMs}ms` : "default"

    this.applyVisualState(visualState, connection.transportKey)
    this.setText("[data-ws-state]", visualState.stateText)
    this.setTone("[data-ws-state]", visualState.toneClass)
    this.setText("[data-ws-transport]", connection.transportLabel)
    this.setText("[data-ws-endpoint]", endpoint)
    this.setText("[data-ws-heartbeat]", heartbeat)
  },
  applyVisualState(visualState, transportKey) {
    const indicator = document.getElementById("topbar-connection-indicator")
    const button = indicator?.querySelector("[data-ws-button]")
    const icon = indicator?.querySelector("[data-ws-icon] span")
    const label = indicator?.querySelector("[data-ws-label]")

    indicator?.setAttribute("data-state", visualState.dataState)
    indicator?.setAttribute("data-transport", transportKey)
    this.el.setAttribute("data-state", visualState.dataState)
    this.el.setAttribute("data-transport", transportKey)

    if (button) {
      button.classList.remove(...CONNECTION_TONE_CLASSES)
      button.classList.add(visualState.buttonToneClass)
      button.setAttribute("aria-label", visualState.label)
    }

    if (icon) {
      icon.classList.remove(...CONNECTION_ICON_CLASSES, ...CONNECTION_TONE_CLASSES)
      icon.classList.add(visualState.icon, visualState.toneClass)
    }

    if (label) label.textContent = visualState.label
  },
  setText(selector, text) {
    const target = this.el.querySelector(selector)
    if (target) target.textContent = text
  },
  setTone(selector, toneClass) {
    const target = this.el.querySelector(selector)
    if (!target) return

    target.classList.remove(...CONNECTION_TONE_CLASSES)
    target.classList.add(toneClass)
  },
}

const forgetMemorizedLongPollFallback = () => {
  try {
    window.sessionStorage?.removeItem("phx:fallback:LongPoll")
  } catch (_error) {
    return
  }
}

forgetMemorizedLongPollFallback()

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 8000,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ClipboardCopy, FlashAutoDismiss, OtpInput, TotpSetupTools, WebSocketState},
})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
