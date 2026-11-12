"use client"

import { useState } from "react"
import { Globe, User, Lock, Eye, EyeOff } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Field, FieldGroup, FieldLabel as Label } from "@/components/ui/field"
import { isValidEmail } from "@/features/auth/account-profile"
import { InputGroup, InputGroupAddon, InputGroupInput, InputGroupButton } from "@/components/ui/input-group"
import { AuthShell } from "./auth-shell"
import { useAuth } from "./auth-context"
import { PrivacyNotice } from "./privacy-notice"
import { useTranslations } from "next-intl"

export function LoginScreen() {
  const { navigate, login, loading, error, devkit, devkitFeishuAvailable, loginWithDevKitFeishu, oauthEnabled, oauthProviderLabel, registrationOpen, passwordResetEnabled, startOAuth } = useAuth()
  const t = useTranslations("auth")
  const [showPassword, setShowPassword] = useState(false)
  const [email, setEmail] = useState("")
  const [emailBlurred, setEmailBlurred] = useState(false)
  const [password, setPassword] = useState("")
  const emailValid = isValidEmail(email)
  const emailInvalid = emailBlurred && email.includes("@") && !emailValid
  const canSubmit = !loading && emailValid && Boolean(password)

  const submit = async (useDevKit = false) => {
    if (!canSubmit) return
    await login({ email, password }, useDevKit).catch(() => undefined)
  }

  return (
    <AuthShell>
      <div className="flex flex-col items-center gap-2 text-center mb-8">
        <h1 className="text-2xl font-bold tracking-tight">
          {t("login.titlePrefix")}{" "}
          <span className="aa-wordmark">Agents Anywhere</span>
        </h1>
        <p className="text-sm text-muted-foreground leading-relaxed">
          {t("login.description")}
        </p>
      </div>

      <form noValidate onSubmit={(event) => { event.preventDefault(); void submit() }}>
        <FieldGroup>
          <Field>
            <Label htmlFor="login-email">{t("fields.email")}</Label>
            <InputGroup className="h-11 rounded-lg has-[[data-slot][aria-invalid=true]]:border-destructive/50 has-[[data-slot][aria-invalid=true]]:ring-0">
              <InputGroupAddon><User className="size-4" /></InputGroupAddon>
              <InputGroupInput
                id="login-email"
                value={email}
                onChange={(event) => setEmail(event.currentTarget.value)}
                onFocus={() => setEmailBlurred(false)}
                onBlur={() => setEmailBlurred(true)}
                placeholder={t("login.userPlaceholder")}
                type="email"
                name="email"
                inputMode="email"
                autoCapitalize="none"
                autoCorrect="off"
                autoComplete="username"
                spellCheck={false}
                className="code-mono"
                aria-invalid={emailInvalid}
              />
            </InputGroup>
          </Field>

          <Field>
            <Label htmlFor="login-password">{t("fields.password")}</Label>
            <InputGroup className="h-11 rounded-lg">
              <InputGroupAddon><Lock className="size-4" /></InputGroupAddon>
              <InputGroupInput
                id="login-password"
                name="password"
                type={showPassword ? "text" : "password"}
                value={password}
                onChange={(event) => setPassword(event.currentTarget.value)}
                placeholder={t("login.passwordPlaceholder")}
                autoComplete="current-password"
                spellCheck={false}
                className="code-mono"
              />
              <InputGroupAddon align="inline-end">
                <InputGroupButton onClick={() => setShowPassword((v) => !v)} aria-label={showPassword ? t("actions.hidePassword") : t("actions.showPassword")}>
                  {showPassword ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
                </InputGroupButton>
              </InputGroupAddon>
            </InputGroup>
          </Field>

          <Button
            className="h-11 w-full font-medium"
            disabled={!canSubmit}
            type="submit"
          >
            {loading ? t("login.signingIn") : t("login.submitWithEnter")}
          </Button>

          {devkit && !devkit.managedOnly ? (
            <Button
              type="button"
              variant="outline"
              className="h-11 w-full"
              disabled={!canSubmit}
              onClick={() => void submit(true)}
            >
              {t("devkit.signIn")}
            </Button>
          ) : null}

          {devkitFeishuAvailable ? (
            <Button
              type="button"
              variant="outline"
              className="h-11 w-full"
              disabled={loading}
              onClick={() => void loginWithDevKitFeishu()}
            >
              {t(devkit?.managedOnly ? "devkit.managedFeishuSignIn" : "devkit.feishuSignIn")}
            </Button>
          ) : null}

          {error ? <p className="text-center text-sm text-destructive">{error}</p> : null}

          {oauthEnabled && oauthProviderLabel ? (
            <Button
              type="button"
              variant="outline"
              className="h-11 w-full gap-2"
              disabled={loading}
              onClick={() => void startOAuth()}
            >
              <Globe className="size-4" />
              {t("login.oauth", { provider: oauthProviderLabel })}
            </Button>
          ) : null}

          {registrationOpen || passwordResetEnabled ? (
            <div className="flex flex-col items-center gap-1 text-sm text-muted-foreground">
              {registrationOpen ? (
                <p>
                  {t("login.newHere")}{" "}
                  <button
                    type="button"
                    className="font-medium text-foreground underline-offset-4 hover:underline"
                    onClick={() => navigate("register")}
                  >
                    {t("login.createAccount")}
                  </button>
                </p>
              ) : null}
              {passwordResetEnabled ? (
                <button
                  type="button"
                  className="font-medium text-foreground underline-offset-4 hover:underline"
                  onClick={() => navigate("forgot-password")}
                >
                  {t("login.resetPassword")}
                </button>
              ) : (
                <p>{t("login.forgot")}</p>
              )}
            </div>
          ) : null}

          <PrivacyNotice message={t("login.privacyNotice")} />
        </FieldGroup>
      </form>
    </AuthShell>
  )
}
