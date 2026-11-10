import type { DevKitAuthConfig } from "./types"

export interface DevKitBrowserClient {
  providers(): Promise<readonly { providerId: string; flow: "password" | "popup" }[]>
  signInWithPassword(input: { email: string; password: string }): Promise<{ accessToken: string }>
  signInWithOAuthPopup(input: { providerId: "feishu"; signal?: AbortSignal }): Promise<{ accessToken: string }>
  linkOAuthWithPopup(input: { providerId: "feishu"; signal?: AbortSignal }): Promise<void>
  signOut(): Promise<void>
}

// An SDK-enabled deployment supplies this factory at build time.
export function createDevKitBrowserClient(_config: DevKitAuthConfig): DevKitBrowserClient | undefined {
  return undefined
}
