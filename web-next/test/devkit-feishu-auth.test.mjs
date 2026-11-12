import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { registerHooks } from "node:module"
import test from "node:test"
import { JSDOM } from "jsdom"
import { registerSource } from "./helpers/onboarding-source.mjs"

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "https://app.example.test/",
  pretendToBeVisual: true,
})
for (const name of ["window", "document", "navigator", "HTMLElement", "HTMLInputElement", "HTMLButtonElement", "Element", "Node", "NodeFilter", "Event", "CustomEvent", "MutationObserver", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"]) {
  Object.defineProperty(globalThis, name, { configurable: true, value: dom.window[name] })
}
window.matchMedia = () => ({ matches: true, addEventListener() {}, removeEventListener() {} })
globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
globalThis.IS_REACT_ACT_ENVIRONMENT = true

const { createElement: h, act } = await import("react")
const { createRoot } = await import("react-dom/client")
const { NextIntlClientProvider } = await import("next-intl")
const source = registerSource()
const injectedFactory = registerHooks({
  load(url, context, next) {
    if (url.endsWith("/features/auth/devkit-browser-client.ts")) {
      return {
        format: "module", shortCircuit: true,
        source: "export const createDevKitBrowserClient = config => globalThis.testDevKitFactory(config)",
      }
    }
    if (url.endsWith("/components/auth/auth-shell.tsx")) {
      return { format: "module", shortCircuit: true, source: "export const AuthShell = ({ children }) => children" }
    }
    return next(url, context)
  },
})
const { AuthProvider } = await import("../src/components/auth/auth-context.tsx")
const { authApi } = await import("../src/features/auth/api.ts")
const { LoginScreen } = await import("../src/components/auth/login-screen.tsx")
const { DevKitAccountLink } = await import("../src/components/pages/devkit-account-link.tsx")
injectedFactory.deregister()
source.deregister()

const messages = JSON.parse(readFileSync(new URL("../messages/zh-CN.json", import.meta.url), "utf8"))
const config = { apiUrl: "https://devkit.example.test", publishableKey: "synthetic-publishable-key" }
const agentAccount = { userId: "agent-os-user", role: "admin", accessToken: "synthetic-agent-os-session" }
const devkitAccessToken = "synthetic-devkit-session"

async function render(t, component, { client, linkStatus = 204, managedOnly = false } = {}) {
  window.localStorage.clear()
  window.sessionStorage.clear()
  window.history.replaceState({}, "", "/#/login")
  globalThis.testDevKitFactory = () => client
  const exchanges = []
  const passwordRequests = []
  t.mock.method(globalThis, "fetch", async (url, init) => {
    const path = new URL(url, window.location.origin).pathname
    if (path === "/api/runtime/v1/auth/login") {
      passwordRequests.push({ url, body: JSON.parse(init.body) })
      return Response.json({ accessToken: devkitAccessToken })
    }
    if (path.endsWith("/auth/config")) {
      return Response.json({
        devkit: { ...config, managedOnly }, needsBootstrap: false, registrationOpen: false,
        oauthEnabled: !managedOnly, oauthProviderLabel: managedOnly ? null : "Agent OS OAuth",
      })
    }
    if (path.endsWith("/auth/me")) return Response.json(agentAccount)
    if (path.endsWith("/auth/devkit/login") || path.endsWith("/auth/devkit/link")) {
      exchanges.push({
        operation: path.split("/").at(-1),
        token: new Headers(init.headers).get("authorization"),
        body: JSON.parse(init.body),
      })
      if (path.endsWith("/login")) return Response.json(agentAccount)
      if (linkStatus === 204) return new Response(null, { status: 204 })
      return Response.json({ detail: "Account binding conflict" }, { status: linkStatus })
    }
    throw new Error("Unexpected Auth request")
  })
  const container = document.createElement("div")
  document.body.append(container)
  const root = createRoot(container)
  await act(async () => root.render(h(NextIntlClientProvider, {
    locale: "zh-CN", messages, timeZone: "Asia/Shanghai",
  }, component)))
  t.after(async () => {
    await act(async () => root.unmount())
    container.remove()
    delete globalThis.testDevKitFactory
  })
  return { container, exchanges, passwordRequests }
}

function button(scope, label) {
  return [...scope.querySelectorAll("button")].find(item => item.textContent === label)
}

async function click(scope, label) {
  const target = button(scope, label)
  assert.ok(target, `Missing button ${label}`)
  await act(async () => target.click())
}

async function fill(scope, selector, value) {
  const input = scope.querySelector(selector)
  assert.ok(input, `Missing input ${selector}`)
  await act(async () => {
    Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set.call(input, value)
    input.dispatchEvent(new window.Event("input", { bubbles: true }))
  })
}

for (const [description, client] of [
  ["no SDK", undefined],
  ["no Feishu provider", { providers: async () => [{ providerId: "password", flow: "password" }] }],
]) {
  test(`email and Agent OS OAuth stay available with ${description}`, async t => {
    const { container } = await render(t, h(AuthProvider, null, h(LoginScreen)), { client })
    assert.ok(button(container, messages.auth.devkit.signIn))
    assert.ok(button(container, messages.auth.login.oauth.replace("{provider}", "Agent OS OAuth")))
    assert.equal(button(container, "使用 DevKit 飞书登录"), undefined)
  })
}

test("a discovered Feishu popup signs in through the Agent OS exchange", async t => {
  const events = []
  const client = {
    providers: async () => [{ providerId: "feishu", flow: "popup" }],
    signInWithOAuthPopup: async ({ providerId }) => {
      events.push(providerId)
      return { accessToken: devkitAccessToken }
    },
    signOut: async () => { events.push("signOut") },
  }
  const { container, exchanges } = await render(t, h(AuthProvider, null, h(LoginScreen)), { client })
  const target = button(container, "使用 DevKit 飞书登录")
  assert.ok(target)
  assert.equal(target.disabled, false)
  await act(async () => {
    target.click()
    assert.deepEqual(events, ["feishu"], "the popup begins within the user click")
  })
  assert.deepEqual(exchanges, [{ operation: "login", token: null, body: { accessToken: devkitAccessToken } }])
  assert.deepEqual(events, ["feishu", "signOut"])
  assert.deepEqual(JSON.parse(window.localStorage.getItem("aa.session.v1")), agentAccount)
  assert.equal([...Object.values(window.localStorage), ...Object.values(window.sessionStorage)].some(value => value.includes(devkitAccessToken)), false)
})

for (const linkStatus of [204, 409]) {
  test(`settings requires both existing identities before opening the Feishu popup (Agent OS ${linkStatus})`, async t => {
    const events = []
    const client = {
      signInWithPassword: async ({ email, password }) => {
        assert.equal(email, "member@example.test")
        assert.equal(password === "synthetic-password", true)
        events.push("password")
        return { accessToken: devkitAccessToken }
      },
      signInWithOAuthPopup: () => assert.fail("Settings must not sign up or sign in via Feishu"),
      linkOAuthWithPopup: async ({ providerId }) => { events.push(`link:${providerId}`) },
      signOut: async () => { events.push("signOut") },
    }
    const { container, exchanges } = await render(t, h(DevKitAccountLink, {
      config, token: agentAccount.accessToken, feishuAvailable: true,
    }), { client, linkStatus })
    await click(container, messages.auth.devkit.link)
    const dialog = document.querySelector('[role="dialog"]')
    assert.ok(dialog)
    assert.equal(button(dialog, "绑定飞书"), undefined)
    await fill(dialog, "#devkit-email", "member@example.test")
    await fill(dialog, "#devkit-password", "synthetic-password")
    await click(dialog, "继续绑定飞书")
    assert.deepEqual(exchanges, [{
      operation: "link", token: `Bearer ${agentAccount.accessToken}`, body: { accessToken: devkitAccessToken },
    }])
    if (linkStatus === 409) {
      assert.equal(button(dialog, "绑定飞书"), undefined)
      assert.deepEqual(events, ["password", "signOut"])
      assert.ok(dialog.querySelector('[role="alert"]'))
      return
    }
    assert.deepEqual(events, ["password"])
    const target = button(dialog, "绑定飞书")
    assert.ok(target)
    await act(async () => {
      target.click()
      assert.deepEqual(events, ["password", "link:feishu"], "binding opens from the second user click")
    })
    assert.deepEqual(events, ["password", "link:feishu", "signOut"])
    assert.equal(document.querySelector('[role="dialog"]'), null)
  })
}


test("managed login uses DevKit for the primary password action and shows one Feishu entry", async (t) => {
  const credentials = { email: "original@example.test", password: "synthetic-password" }
  const client = { providers: async () => [{ providerId: "feishu", flow: "popup" }] }
  const { container, exchanges, passwordRequests } = await render(t, h(AuthProvider, null, h(LoginScreen)), {
    client, managedOnly: true,
  })
  assert.ok(button(container, "使用飞书登录"))
  assert.ok(container.querySelector('a[href="/auth/devkit/reset-password"]'))
  assert.equal(button(container, "使用 DevKit 飞书登录"), undefined)
  assert.equal(button(container, "使用 DevKit 登录"), undefined)
  await fill(container, "#login-email", credentials.email)
  await fill(container, "#login-password", credentials.password)
  const submit = container.querySelector('button[type="submit"]')
  assert.equal(submit.disabled, false)
  await act(async () => submit.click())
  assert.deepEqual(passwordRequests, [{
    url: "https://devkit.example.test/api/runtime/v1/auth/login", body: credentials,
  }])
  assert.deepEqual(exchanges, [{ operation: "login", token: null, body: { accessToken: devkitAccessToken } }])
  assert.deepEqual(JSON.parse(window.localStorage.getItem("aa.session.v1")), agentAccount)
})

test("DevKit recovery sends email and new password only to the project Auth API", async (t) => {
  const calls = []
  t.mock.method(globalThis, "fetch", async (url, init) => {
    calls.push([url, init.credentials, JSON.parse(init.body)])
    return Response.json(url.endsWith("request") ? { accepted: true } : { reset: true })
  })
  await authApi.requestDevKitPasswordReset(config, " EXAMPLE@EXAMPLE.TEST ")
  await authApi.resetDevKitPassword(config, "synthetic-reset-token", "NewPassword99")
  assert.deepEqual(calls, [
    ["https://devkit.example.test/api/runtime/v1/auth/password/reset/request", "omit", {
      email: "example@example.test", redirectTo: "https://app.example.test/auth/devkit/reset-password",
    }],
    ["https://devkit.example.test/api/runtime/v1/auth/password/reset/confirm", "omit", {
      token: "synthetic-reset-token", password: "NewPassword99",
    }],
  ])
})
