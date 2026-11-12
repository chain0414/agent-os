"use client"

import { lazy, Suspense } from "react"
import { AuthProvider, useAuth } from "./auth-context"
import { BootstrapScreen } from "./bootstrap-screen"
import { LoginScreen } from "./login-screen"
import { RegisterScreen } from "./register-screen"
import { ForgotPasswordScreen } from "./forgot-password-screen"
import { OAuthNewUserScreen } from "./oauth-new-user-screen"
import { OAuthLinkExistingScreen } from "./oauth-link-existing-screen"
import { SignedOutScreen } from "./signed-out-screen"
import { DesktopOAuthFlow, MobileOAuthFlow, PluginOAuthFlow } from "./mobile-oauth-page"
import { LoadingState } from "@/components/loading-state"
import { announcementPageEnabled } from "@/features/announcements/read-state"

const Workspace = lazy(() => import("@/components/demo").then(({ Demo }) => ({ default: Demo })))
const PluginOnboardingPage = lazy(() => import("@/components/onboarding/plugin-onboarding-page").then(({ PluginOnboardingPage }) => ({ default: PluginOnboardingPage })))
const FilePreviewPage = lazy(() => import("@/components/file-preview-page").then(({ FilePreviewPage }) => ({ default: FilePreviewPage })))
const AnnouncementGate = lazy(() => import("@/components/announcements/announcement-gate").then(({ AnnouncementGate }) => ({ default: AnnouncementGate })))

function AuthRouterInner() {
  const { screen, loading, isAuthenticated, devkit } = useAuth()

  if (loading) {
    return (
      <LoadingState className="min-h-screen bg-background" />
    )
  }
  if (devkit?.managedOnly && ["bootstrap", "register", "forgot-password", "oauth-new-user", "oauth-link-existing"].includes(screen)) {
    return isAuthenticated ? <Workspace /> : <LoginScreen />
  }
  if (screen === "bootstrap") return <BootstrapScreen />
  if (screen === "app") return isAuthenticated ? <Workspace /> : <LoginScreen />
  if (screen === "signed-out") return <SignedOutScreen />
  if (screen === "register") return <RegisterScreen />
  if (screen === "forgot-password") return <ForgotPasswordScreen />
  if (screen === "oauth-new-user") return <OAuthNewUserScreen />
  if (screen === "oauth-link-existing") return <OAuthLinkExistingScreen />
  if (screen === "mobile-oauth") return <MobileOAuthFlow />
  if (screen === "desktop-oauth") return <DesktopOAuthFlow />
  if (screen === "plugin-oauth") return <PluginOAuthFlow />
  if (screen === "onboarding") return <PluginOnboardingPage />
  if (screen === "preview") return <FilePreviewPage />
  return <LoginScreen />
}

export function AuthRouter() {
  return (
    <AuthProvider>
      <AuthRouterContent />
    </AuthProvider>
  )
}

function AuthRouterContent() {
  const { screen, loading } = useAuth()
  return (
    <>
      <Suspense fallback={<LoadingState className="min-h-screen bg-background" />}>
        <AuthRouterInner />
      </Suspense>
      {!loading && announcementPageEnabled(screen) ? (
        <Suspense fallback={null}><AnnouncementGate page={screen} /></Suspense>
      ) : null}
    </>
  )
}
