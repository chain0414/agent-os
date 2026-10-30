/** Host-only orchestration: credentials and native identity never enter tool arguments. */
export class NativeCoordinator {
  #rpc;
  #hosts = new Map();
  #deliveries = new Map();
  constructor(rpc) {
    this.#rpc = rpc;
  }
  attach(host) {
    if (this.#hosts.has(host.bindingId))
      throw new Error("HOST_ALREADY_ATTACHED");
    this.#hosts.set(host.bindingId, host);
  }
  #host(bindingId) {
    const host = this.#hosts.get(bindingId);
    if (!host) throw new Error("HOST_NOT_ATTACHED");
    return host;
  }
  async delegate(bindingId, origin, params) {
    const host = this.#host(bindingId);
    if (
      origin?.sessionId !== host.sessionId ||
      typeof origin.callId !== "string" ||
      !origin.callId
    ) {
      throw new Error("ORIGIN_MISMATCH");
    }
    return this.#rpc(host.token, "delegate", {
      ...params,
      requestId: `${host.sessionId}:${origin.callId}`,
    });
  }
  async processOne(targetBindingId) {
    const target = this.#host(targetBindingId);
    const task = await this.#rpc("admin", "takeTask", {
      bindingId: targetBindingId,
    });
    if (!task) return null;
    let startedTurn;
    // On an unknown admission error, leave the broker's accepted state for reconciliation.
    const result = await target.adapter.runTurn(
      target.sessionId,
      task.content,
      {
        mode: task.kind,
        requestId: task.id,
        onStart: async (turnId) => {
          if (startedTurn && startedTurn !== turnId)
            throw new Error("TURN_MISMATCH");
          startedTurn = turnId;
          await this.#rpc("admin", "startTask", { taskId: task.id, turnId });
        },
      },
    );
    if (!startedTurn || startedTurn !== result.turnId)
      throw new Error("TURN_MISMATCH");
    await this.#rpc("admin", "completeTask", {
      taskId: task.id,
      turnId: result.turnId,
      outcome: "succeeded",
      output: result.output,
    });
    const delivery = await this.deliver(task.source, task.id);
    return {
      taskId: task.id,
      turnId: result.turnId,
      output: result.output,
      delivery,
    };
  }
  async deliver(sourceBindingId, taskId) {
    const source = this.#host(sourceBindingId);
    const claim = await this.#rpc(source.token, "claimResult", { taskId });
    if (claim.delivered) return { delivered: true };
    const key = `${sourceBindingId}:${claim.deliveryId}`;
    let delivery = this.#deliveries.get(key);
    if (delivery?.state === "unknown")
      throw new Error("DELIVERY_OUTCOME_UNKNOWN");
    if (!delivery) {
      delivery = { state: "inflight" };
      this.#deliveries.set(key, delivery);
      delivery.promise = Promise.resolve().then(async () => {
        try {
          const response = await source.adapter.deliverGenerated(
            source.sessionId,
            {
              taskId,
              deliveryId: claim.deliveryId,
              ...claim.result,
            },
          );
          if (
            response?.received !== true ||
            response.deliveryId !== claim.deliveryId
          ) {
            throw new Error("DELIVERY_NOT_CONFIRMED");
          }
          delivery.state = "confirmed";
          return response;
        } catch (error) {
          delivery.state = "unknown";
          throw error;
        }
      });
    }
    const response = await delivery.promise;
    await this.#rpc(source.token, "ackResult", {
      taskId,
      deliveryId: claim.deliveryId,
    });
    return response;
  }
}
