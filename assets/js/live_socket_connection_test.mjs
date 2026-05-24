import test from "node:test"
import assert from "node:assert/strict"

import {classifyLiveSocketConnection, normalizeLiveSocketTransport} from "./live_socket_connection.mjs"

test("normalizes Phoenix longpoll transport through transportName instead of minified constructor name", () => {
  const socket = {
    transport: function At() {},
    transportName: () => "LongPoll",
  }

  assert.deepEqual(normalizeLiveSocketTransport(socket), {
    transportKey: "longpoll",
    transportLabel: "long polling",
  })
})

test("normalizes websocket transport through Phoenix transportName", () => {
  const socket = {
    transport: function wt() {},
    transportName: () => "WebSocket",
  }

  assert.deepEqual(normalizeLiveSocketTransport(socket), {
    transportKey: "websocket",
    transportLabel: "WebSocket",
  })
})

test("never exposes minified unknown transport names to operators", () => {
  const socket = {transport: function At() {}}

  assert.deepEqual(normalizeLiveSocketTransport(socket), {
    transportKey: "unknown",
    transportLabel: "unknown",
  })
})

test("classifies connected browser admin websocket separately from Codex protocol websocket", () => {
  const liveSocket = {isConnected: () => true}
  const socket = {
    transport: function wt() {},
    transportName: () => "WebSocket",
    connectionState: () => "open",
  }

  assert.deepEqual(classifyLiveSocketConnection(liveSocket, socket), {
    transportKey: "websocket",
    transportLabel: "WebSocket",
    visualState: "websocketConnected",
  })
})

test("classifies connected longpoll as browser admin fallback", () => {
  const liveSocket = {isConnected: () => true}
  const socket = {
    transport: function At() {},
    transportName: () => "LongPoll",
    connectionState: () => "open",
  }

  assert.deepEqual(classifyLiveSocketConnection(liveSocket, socket), {
    transportKey: "longpoll",
    transportLabel: "long polling",
    visualState: "longPollFallback",
  })
})
