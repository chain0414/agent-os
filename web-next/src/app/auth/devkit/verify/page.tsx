"use client"

import { useEffect, useRef, useState } from "react"
import { useTranslations } from "next-intl"
import { AuthShell } from "@/components/auth/auth-shell"
import { authApi } from "@/features/auth/api"

export default function DevKitEmailVerificationPage() {
  const t = useTranslations("auth.devkit")
  const started = useRef(false)
  const [status, setStatus] = useState<"verifying" | "verified" | "verificationFailed">("verifying")

  useEffect(() => {
    if (started.current) return
    started.current = true
    const token = new URLSearchParams(window.location.hash.slice(1)).get("token")
    window.history.replaceState(null, "", window.location.pathname)
    if (!token) {
      setStatus("verificationFailed")
      return
    }
    void authApi.config().then(async ({ devkit }) => {
      if (!devkit) throw new Error("DevKit Auth is unavailable")
      await authApi.verifyDevKitEmail(devkit, token)
      setStatus("verified")
    }).catch(() => setStatus("verificationFailed"))
  }, [])

  return (
    <AuthShell>
      <p role="status" className="mb-4">{t(status)}</p>
      <a className="underline" href="/#/settings/account">{t("returnToAccount")}</a>
    </AuthShell>
  )
}
