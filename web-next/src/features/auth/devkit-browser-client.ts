import type { DevKitAuthConfig, DevKitBrowserClient } from "./types"

export type { DevKitBrowserClient } from "./types"

// An SDK-enabled deployment supplies this factory at build time.
export function createDevKitBrowserClient(_config: DevKitAuthConfig): DevKitBrowserClient | undefined {
  return undefined
}
