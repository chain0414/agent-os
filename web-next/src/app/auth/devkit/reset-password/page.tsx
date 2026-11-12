"use client"

import { useEffect, useRef, useState } from "react"
import { useTranslations } from "next-intl"
import { AuthShell } from "@/components/auth/auth-shell"
import { Button } from "@/components/ui/button"
import { Field, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { isValidEmail } from "@/features/auth/account-profile"
import { authApi } from "@/features/auth/api"
import type { DevKitAuthConfig } from "@/features/auth/types"

type Step = "loading" | "request" | "sent" | "reset" | "invalidLink" | "done" | "unavailable"

function takeResetFragment(): string | null {
  const fragment = window.location.hash
  if (!fragment) return null
  const token = new URLSearchParams(fragment.slice(1)).get("token") ?? ""
  window.history.replaceState(window.history.state, "", window.location.pathname)
  return token
}

function resetStep(token: string): Step {
  return /^[A-Za-z0-9_-]{43}$/.test(token) ? "reset" : "invalidLink"
}

export default function DevKitPasswordResetPage() {
  const t = useTranslations("auth")
  const started = useRef(false)
  const resetToken = useRef("")
  const linkRevision = useRef(0)
  const [config, setConfig] = useState<DevKitAuthConfig | null>(null)
  const [step, setStep] = useState<Step>("loading")
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [confirm, setConfirm] = useState("")
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    if (started.current) return
    started.current = true
    const token = takeResetFragment()
    resetToken.current = token ?? ""
    void authApi.config().then(({ devkit }) => {
      if (!devkit?.managedOnly) {
        setStep("unavailable")
        return
      }
      setConfig(devkit)
      setStep(token === null ? "request" : resetStep(token))
    }).catch(() => setStep("unavailable"))
  }, [])

  useEffect(() => {
    if (!config) return
    const onHashChange = () => {
      const token = takeResetFragment()
      if (token === null) return
      linkRevision.current += 1
      resetToken.current = token
      setPassword("")
      setConfirm("")
      setFailed(false)
      setStep(resetStep(token))
    }
    window.addEventListener("hashchange", onHashChange)
    return () => window.removeEventListener("hashchange", onHashChange)
  }, [config])

  const passwordValid = password.length >= 10 && password.length <= 128
    && /[A-Z]/.test(password) && /[a-z]/.test(password) && /[0-9]/.test(password)
  const canSubmit = step === "request" ? isValidEmail(email) : passwordValid && password === confirm
  const submit = async () => {
    if (!config || busy || !canSubmit) return
    const revision = linkRevision.current
    setBusy(true)
    setFailed(false)
    try {
      if (step === "request") {
        await authApi.requestDevKitPasswordReset(config, email)
        if (revision === linkRevision.current) setStep("sent")
      } else if (step === "reset") {
        await authApi.resetDevKitPassword(config, resetToken.current, password)
        if (revision !== linkRevision.current) return
        resetToken.current = ""
        setPassword("")
        setConfirm("")
        setStep("done")
      }
    } catch {
      if (revision === linkRevision.current) setFailed(true)
    } finally {
      setBusy(false)
    }
  }
  const restart = () => {
    resetToken.current = ""
    setPassword("")
    setConfirm("")
    setFailed(false)
    setStep("request")
  }

  return (
    <AuthShell>
      <h1 className="mb-6 text-center text-2xl font-bold tracking-tight">{t("forgotPassword.title")}</h1>
      {step === "request" || step === "reset" ? (
        <form noValidate onSubmit={(event) => { event.preventDefault(); void submit() }}>
          <FieldGroup>
            {step === "request" ? (
              <Field>
                <FieldLabel htmlFor="devkit-reset-email">{t("fields.email")}</FieldLabel>
                <Input id="devkit-reset-email" name="email" type="email" autoComplete="email"
                  value={email} onChange={(event) => setEmail(event.currentTarget.value)} disabled={busy} />
              </Field>
            ) : (
              <>
                <Field>
                  <FieldLabel htmlFor="devkit-new-password">{t("forgotPassword.newPassword")}</FieldLabel>
                  <Input id="devkit-new-password" name="password" type="password" autoComplete="new-password"
                    value={password} onChange={(event) => setPassword(event.currentTarget.value)} disabled={busy}
                    aria-describedby="devkit-password-requirements" />
                  <p id="devkit-password-requirements" className="text-sm text-muted-foreground">{t("devkitPassword.requirements")}</p>
                </Field>
                <Field>
                  <FieldLabel htmlFor="devkit-confirm-password">{t("fields.confirmPassword")}</FieldLabel>
                  <Input id="devkit-confirm-password" name="confirmPassword" type="password" autoComplete="new-password"
                    value={confirm} onChange={(event) => setConfirm(event.currentTarget.value)} disabled={busy} />
                  {confirm && password !== confirm ? <p className="text-sm text-destructive">{t("register.passwordMismatch")}</p> : null}
                </Field>
              </>
            )}
            <Button className="h-11" type="submit" disabled={busy || !canSubmit}>
              {busy ? t("devkitPassword.submitting") : t(step === "request" ? "devkitPassword.send" : "forgotPassword.submit")}
            </Button>
            {failed ? <p role="alert" className="text-center text-sm text-destructive">
              {t(step === "request" ? "devkitPassword.requestFailed" : "devkitPassword.resetFailed")}
            </p> : null}
          </FieldGroup>
        </form>
      ) : (
        <p role="status" className="text-center text-sm text-muted-foreground">
          {t(step === "done" ? "forgotPassword.done" : `devkitPassword.${step}`)}
        </p>
      )}
      <div className="mt-5 flex flex-wrap items-center justify-center gap-4 text-sm">
        {(step === "sent" || step === "invalidLink" || (step === "reset" && failed)) ? (
          <button type="button" onClick={restart} className="font-medium underline">{t("devkitPassword.requestAgain")}</button>
        ) : null}
        <a className="font-medium underline" href="/#/login">{t("forgotPassword.backToLogin")}</a>
      </div>
    </AuthShell>
  )
}
