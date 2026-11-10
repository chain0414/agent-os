"use client"

import { useState } from "react"
import { useTranslations } from "next-intl"
import { toast } from "sonner"
import { SettingsSection } from "@/components/settings/settings-section"
import { Button } from "@/components/ui/button"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog"
import { Field, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { isValidEmail } from "@/features/auth/account-profile"
import { authApi } from "@/features/auth/api"
import type { DevKitAuthConfig } from "@/features/auth/types"

export function DevKitAccountLink({ config, token }: { config: DevKitAuthConfig; token: string }) {
  const t = useTranslations("auth")
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(false)
  const [signingUp, setSigningUp] = useState(false)
  const [checkEmail, setCheckEmail] = useState(false)
  const actionLabel = t(signingUp ? "devkit.signUp" : "devkit.link")
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const canSubmit = !busy && isValidEmail(email) && Boolean(password)

  function changeOpen(next: boolean) {
    if (busy) return
    setOpen(next)
    if (!next) {
      setEmail("")
      setPassword("")
      setError(false)
      setSigningUp(false)
      setCheckEmail(false)
    }
  }

  async function submit() {
    if (!canSubmit) return
    setBusy(true)
    setError(false)
    try {
      if (signingUp) {
        await authApi.signUpWithDevKit(config, { email, password })
        setCheckEmail(true)
        setPassword("")
        return
      }
      await authApi.linkDevKit(token, config, { email, password })
      setOpen(false)
      setEmail("")
      setPassword("")
      toast.success(t("devkit.linked"))
    } catch {
      setError(true)
      setPassword("")
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
            <DialogDescription>{t(signingUp ? "devkit.signUpDescription" : "devkit.linkDescription")}</DialogDescription>
          </DialogHeader>
          {checkEmail ? <p role="status">{t("devkit.checkEmail")}</p> : <form className="flex flex-col gap-4" onSubmit={(event) => { event.preventDefault(); void submit() }}>
            <Field>
              <FieldLabel htmlFor="devkit-email">{t("fields.email")}</FieldLabel>
              <Input id="devkit-email" type="email" value={email} onChange={(event) => setEmail(event.currentTarget.value)} autoComplete="username" disabled={busy} />
            </Field>
            <Field>
              <FieldLabel htmlFor="devkit-password">{t("fields.password")}</FieldLabel>
              <Input id="devkit-password" type="password" value={password} onChange={(event) => setPassword(event.currentTarget.value)} autoComplete={signingUp ? "new-password" : "current-password"} disabled={busy} />
            </Field>
            {error ? <p role="alert" className="text-sm text-destructive">{t(signingUp ? "devkit.signUpFailed" : "devkit.linkFailed")}</p> : null}
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
