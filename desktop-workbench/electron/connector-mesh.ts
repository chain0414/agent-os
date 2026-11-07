export async function createConnectorMesh(endpoint: { unixPath: string } | { pipe: string }, key: string, instanceId: string) {
  const { Mesh, Router } = await import("meshcall");
  const mesh = new Mesh(new Router(endpoint), { token: key, peerId: `desktop-workbench-${instanceId}` });

  // MeshCall 0.3.0 can reject the result while call.open is still being written.
  // Observe the rejection immediately so the RPC caller can handle the same promise.
  const client = mesh.client as unknown as {
    registerCall?: (...args: unknown[]) => { result?: Promise<unknown> };
  };
  const registerCall = client.registerCall;
  if (typeof registerCall === "function") {
    client.registerCall = (...args) => {
      const registered = registerCall.apply(client, args);
      void registered.result?.catch(() => undefined);
      return registered;
    };
  }
  return mesh;
}
