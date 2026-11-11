"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { useTranslations } from "next-intl"
import { toast } from "sonner"
import { SettingsSection } from "@/components/settings/settings-section"
import { Button } from "@/components/ui/button"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog"
import { Field, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { isValidEmail, normalizeEmail } from "@/features/auth/account-profile"
import { authApi } from "@/features/auth/api"
import { createDevKitBrowserClient, type DevKitBrowserClient } from "@/features/auth/devkit-browser-client"
import type { DevKitAuthConfig } from "@/features/auth/types"

type FeishuLinkAttempt = {
  client: DevKitBrowserClient
  controller: AbortController
  config: DevKitAuthConfig
  token: string
}

export function DevKitAccountLink({ config, token, feishuAvailable = false }: {
  config: DevKitAuthConfig
  token: string
  feishuAvailable?: boolean
}) {
  const t = useTranslations("auth")
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(false)
  const [signingUp, setSigningUp] = useState(false)
  const [checkEmail, setCheckEmail] = useState(false)
  const pendingFeishu = useRef<FeishuLinkAttempt | null>(null)
  const [verifiedFeishu, setVerifiedFeishu] = useState<FeishuLinkAttempt | null>(null)
  const feishuReady = feishuAvailable && verifiedFeishu?.config === config
    && verifiedFeishu.token === token && !verifiedFeishu.controller.signal.aborted
  const actionLabel = t(feishuReady ? "devkit.linkFeishu" : signingUp ? "devkit.signUp" : "devkit.link")
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const canSubmit = !busy && isValidEmail(email) && Boolean(password)

  const clearFeishu = useCallback(() => {
    const attempt = pendingFeishu.current
    if (!attempt) return
    pendingFeishu.current = null
    attempt.controller.abort()
    void attempt.client.signOut().catch(() => undefined)
  }, [])
  useEffect(() => clearFeishu, [clearFeishu, config, token, feishuAvailable])

  function resetForm() {
    clearFeishu()
    setVerifiedFeishu(null)
    setEmail("")
    setPassword("")
    setError(false)
    setSigningUp(false)
    setCheckEmail(false)
  }

  function changeOpen(next: boolean) {
    if (busy) return
    setOpen(next)
    if (!next) resetForm()
  }

  async function submit(continueWithFeishu = false) {
    if (!canSubmit || (continueWithFeishu && (!feishuAvailable || signingUp))) return
    setBusy(true)
    setError(false)
    let attempt: FeishuLinkAttempt | undefined
    try {
      if (signingUp) {
        await authApi.signUpWithDevKit(config, { email, password })
        setCheckEmail(true)
        setPassword("")
        return
      }
      if (continueWithFeishu) {
        const client = createDevKitBrowserClient(config)
        if (!client) throw new Error("DevKit browser client unavailable")
        const controller = new AbortController()
        attempt = { client, controller, config, token }
        pendingFeishu.current = attempt
        const { accessToken } = await client.signInWithPassword({ email: normalizeEmail(email), password })
        if (controller.signal.aborted) return
        await authApi.linkDevKitWithAccessToken(token, accessToken, controller.signal)
        if (controller.signal.aborted) return
        setPassword("")
        setVerifiedFeishu(attempt)
        return
      }
      await authApi.linkDevKit(token, config, { email, password })
      setOpen(false)
      resetForm()
      toast.success(t("devkit.linked"))
    } catch {
      if (!attempt?.controller.signal.aborted) {
        setError(true)
        setPassword("")
      }
      if (attempt && pendingFeishu.current === attempt) clearFeishu()
    } finally {
      setBusy(false)
    }
  }

  async function linkFeishu() {
    if (!feishuReady || busy) return
    const { client, controller } = verifiedFeishu
    setBusy(true)
    setError(false)
    try {
      await client.linkOAuthWithPopup({ providerId: "feishu", signal: controller.signal })
      if (controller.signal.aborted) return
      setOpen(false)
      resetForm()
      toast.success(t("devkit.feishuLinked"))
    } catch {
      if (!controller.signal.aborted) setError(true)
    } finally {
      setBusy(false)
    }
  }

  return (
    <SettingsSection title={t("devkit.account")} action={
      <Dialog open={open} onOpenChange={changeOpen}>
        <DialogTrigger asChild>
          <Button type="button" variant="outline" size="sm">{t("devkit.link")}</Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{actionLabel}</DialogTitle>
            <DialogDescription>{t(feishuReady ? "devkit.linkFeishuDescription" : signingUp ? "devkit.signUpDescription" : "devkit.linkDescription")}</DialogDescription>
          </DialogHeader>
          {feishuReady ? (
            <>
              {error ? <p role="alert" className="text-sm text-destructive">{t("devkit.feishuLinkFailed")}</p> : null}
              <DialogFooter>
                <Button type="button" disabled={busy} onClick={() => void linkFeishu()}>{actionLabel}</Button>
              </DialogFooter>
            </>
          ) : checkEmail ? <p role="status">{t("devkit.checkEmail")}</p> : <form className="flex flex-col gap-4" onSubmit={(event) => { event.preventDefault(); void submit() }}>
            <Field>
              <FieldLabel htmlFor="devkit-email">{t("fields.email")}</FieldLabel>
              <Input id="devkit-email" type="email" value={email} onChange={(event) => setEmail(event.currentTarget.value)} autoComplete="username" disabled={busy} />
            </Field>
            <Field>
              <FieldLabel htmlFor="devkit-password">{t("fields.password")}</FieldLabel>
              <Input id="devkit-password" type="password" value={password} onChange={(event) => setPassword(event.currentTarget.value)} autoComplete={signingUp ? "new-password" : "current-password"} disabled={busy} />
            </Field>
            {error ? <p role="alert" className="text-sm text-destructive">{t(signingUp ? "devkit.signUpFailed" : "devkit.linkFailed")}</p> : null}
            {feishuAvailable && !signingUp ? (
              <Button type="button" variant="outline" disabled={!canSubmit} onClick={() => void submit(true)}>
                {t("devkit.continueWithFeishu")}
              </Button>
            ) : null}
            <DialogFooter>
              <Button type="button" variant="ghost" disabled={busy} onClick={() => {
                setSigningUp(!signingUp)
                setPassword("")
                setError(false)
              }}>
                {t(signingUp ? "devkit.backToLink" : "devkit.signUp")}
              </Button>
              <Button type="submit" disabled={!canSubmit}>{actionLabel}</Button>
            </DialogFooter>
          </form>}
        </DialogContent>
      </Dialog>
    } />
  )
}
