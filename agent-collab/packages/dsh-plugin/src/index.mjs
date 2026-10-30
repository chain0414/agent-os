/** Only loop-owned execution metadata is accepted; model arguments are never consulted. */
export function currentDshOrigin(exec) {
  const sessionId = exec?.agent?.id,
    callId = exec?.callId;
  if (
    typeof sessionId !== "string" ||
    !sessionId ||
    typeof callId !== "string" ||
    !callId
  )
    throw new Error("HOST_ORIGIN_UNAVAILABLE");
  return { runtime: "dsh", sessionId, callId };
}
export function hostCapabilities(exec) {
  let callerContextAvailable = false;
  try {
    currentDshOrigin(exec);
    callerContextAvailable = true;
  } catch {}
  return {
    runtime: "dsh",
    callerContextAvailable,
    generatedDelivery: false,
    restrictedReview: false,
    safeRunningCancellation: false,
    runtimeVerified: false,
    delegationEnabled: false,
  };
}
export const name = "agent-collab-dsh";
export const inject = ["tools"];
/** Inspection is deliberately the only tool until native delivery and restriction probes pass. */
export function apply(ctx) {
  ctx.effect(() =>
    ctx.tools.register({
      name: "agent_collab_capabilities",
      description: "检查当前对话的协作接入能力。",
      parameters: {
        type: "object",
        properties: {},
        additionalProperties: false,
      },
      output: {
        schema: { type: "object", additionalProperties: true },
        render: (_args, value) => [
          { type: "text", text: JSON.stringify(value) },
        ],
      },
      execute: async (_args, exec) => hostCapabilities(exec),
    }),
  );
}
