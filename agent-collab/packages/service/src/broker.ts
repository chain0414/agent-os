import { DatabaseSync } from "node:sqlite";
import { randomBytes, createHash } from "node:crypto";
import { mkdirSync, chmodSync, realpathSync } from "node:fs";
import { join, relative, isAbsolute } from "node:path";
import { execFileSync } from "node:child_process";

type Capabilities = {
  trustedOrigin?: boolean;
  generatedDelivery?: boolean;
  restrictedReview?: boolean;
  execute?: boolean;
};
type Session = {
  id: string;
  tokenHash: string;
  runtime: string;
  instanceId: string;
  sessionId: string;
  cwd: string;
  capabilities: Capabilities;
};
type Task = {
  id: string;
  requestId: string;
  fingerprint: string;
  source: string;
  target: string;
  kind: string;
  content: string;
  cwd: string;
  planHash: string;
  state: string;
  deadline: number;
  turnId?: string;
  output?: string;
  delivery: string;
  deliveryId?: string;
};
type Grant = {
  id: string;
  bindingId: string;
  cwd: string;
  planHash: string;
  userMessageId: string;
  contentHash: string;
  used: boolean;
};
type State = {
  version: 1;
  sessions: Session[];
  tasks: Task[];
  grants: Grant[];
};
const digest = (value: string) =>
  createHash("sha256").update(value).digest("hex");
const id = () => randomBytes(24).toString("hex");
function fail(code: string): never {
  throw new Error(code);
}
function text(value: unknown): string {
  if (typeof value !== "string" || !value.trim() || value.length > 1_000_000)
    fail("INVALID_PARAMS");
  return value;
}
function workspace(path: unknown): string {
  const resolved = realpathSync(text(path));
  try {
    return realpathSync(
      execFileSync("git", ["-C", resolved, "rev-parse", "--show-toplevel"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim(),
    );
  } catch {
    return resolved;
  }
}
function overlaps(a: string, b: string): boolean {
  const contains = (a: string, b: string) => {
    const p = relative(a, b);
    return p === "" || (!p.startsWith("..") && !isAbsolute(p));
  };
  return contains(a, b) || contains(b, a);
}
const active = (t: Task) =>
  ["accepted", "running", "unknown"].includes(t.state);

/** Trusted adapter operations are separated from session-scoped model operations.
 * The transport must never map a caller-supplied literal "admin" to administrator.
 */
export class Broker {
  db: DatabaseSync;
  state: State;
  constructor(directory: string) {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    chmodSync(directory, 0o700);
    const path = join(directory, "tasks.sqlite");
    this.db = new DatabaseSync(path);
    chmodSync(path, 0o600);
    this.db.exec(
      "PRAGMA journal_mode=DELETE; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)",
    );
    const row = this.db
      .prepare("SELECT payload FROM state WHERE id=1")
      .get() as { payload: string } | undefined;
    this.state = row
      ? JSON.parse(row.payload)
      : { version: 1, sessions: [], tasks: [], grants: [] };
    if (this.state.version !== 1) fail("UNSUPPORTED_STORAGE_VERSION");
    // Admission/completion could have happened before disconnect. Do not replay.
    for (const task of this.state.tasks) {
      if (active(task)) task.state = "unknown";
      if (task.delivery === "claimed") task.delivery = "unknown";
    }
    this.save();
  }
  close() {
    this.db.close();
  }
  private save() {
    this.db
      .prepare(
        "INSERT INTO state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
      )
      .run(JSON.stringify(this.state));
  }
  private session(auth: string) {
    return (
      this.state.sessions.find((s) => s.tokenHash === digest(auth)) ??
      fail("UNAUTHORIZED")
    );
  }
  private task(source: Session, taskId: unknown) {
    const task =
      this.state.tasks.find((t) => t.id === taskId) ?? fail("TASK_NOT_FOUND");
    if (task.source !== source.id) fail("FORBIDDEN");
    return task;
  }
  call(auth: string, method: string, p: Record<string, unknown> = {}): any {
    const admin = auth === "admin";
    const adminMethods = [
      "registerSession",
      "authorizeExecution",
      "takeTask",
      "startTask",
      "completeTask",
      "reconcileTask",
      "reconcileDelivery",
    ];
    if (adminMethods.includes(method) && !admin) fail("FORBIDDEN");
    let result: any;
    if (method === "health")
      return {
        status: "ok",
        protocolVersion: "1.0",
        nativeInteropVerified: false,
      };
    if (method === "registerSession") {
      const runtime = text(p.runtime);
      if (!["codex", "dsh"].includes(runtime)) fail("INVALID_PARAMS");
      const instanceId = text(p.instanceId),
        sessionId = text(p.sessionId),
        cwd = workspace(p.cwd);
      if (
        this.state.sessions.some(
          (s) =>
            s.runtime === runtime &&
            s.instanceId === instanceId &&
            s.sessionId === sessionId,
        )
      )
        fail("SESSION_ALREADY_BOUND");
      const c = p.capabilities;
      if (!c || typeof c !== "object" || Array.isArray(c))
        fail("INVALID_PARAMS");
      const raw = c as Record<string, unknown>,
        capabilities: Capabilities = {};
      for (const key of [
        "trustedOrigin",
        "generatedDelivery",
        "restrictedReview",
        "execute",
      ] as const)
        capabilities[key] = raw[key] === true;
      const token = id(),
        bindingId = id();
      this.state.sessions.push({
        id: bindingId,
        tokenHash: digest(token),
        runtime,
        instanceId,
        sessionId,
        cwd,
        capabilities,
      });
      result = { bindingId, token };
    } else if (method === "authorizeExecution") {
      const source =
        this.state.sessions.find((s) => s.id === p.bindingId) ??
        fail("BINDING_NOT_FOUND");
      const cwd = workspace(p.cwd);
      if (cwd !== source.cwd) fail("WORKSPACE_MISMATCH");
      const grant: Grant = {
        id: id(),
        bindingId: source.id,
        cwd,
        planHash: text(p.planHash),
        userMessageId: text(p.userMessageId),
        contentHash: digest(text(p.content)),
        used: false,
      };
      const prior = this.state.grants.find(
        (g) =>
          g.bindingId === source.id && g.userMessageId === grant.userMessageId,
      );
      if (prior) {
        if (
          prior.planHash !== grant.planHash ||
          prior.cwd !== grant.cwd ||
          prior.contentHash !== grant.contentHash
        )
          fail("AUTHORIZATION_CONFLICT");
        return { grantId: prior.id };
      }
      this.state.grants.push(grant);
      result = { grantId: grant.id };
    } else if (method === "takeTask") {
      const target =
        this.state.sessions.find((s) => s.id === p.bindingId) ??
        fail("BINDING_NOT_FOUND");
      for (const t of this.state.tasks) {
        if (t.state === "queued" && t.deadline <= Date.now())
          t.state = "expired";
      }
      const sameTarget = (t: Task) => {
        const s = this.state.sessions.find((s) => s.id === t.target)!;
        return (
          s.runtime === target.runtime &&
          s.instanceId === target.instanceId &&
          s.sessionId === target.sessionId
        );
      };
      const task = this.state.tasks.find(
        (t) =>
          t.target === target.id &&
          t.state === "queued" &&
          !this.state.tasks.some(
            (a) =>
              active(a) &&
              (sameTarget(a) ||
                ((a.kind === "execute" || t.kind === "execute") &&
                  overlaps(a.cwd, t.cwd))),
          ),
      );
      if (task) task.state = "accepted";
      result = task ? structuredClone(task) : null;
    } else if (method === "reconcileTask") {
      const task =
        this.state.tasks.find((t) => t.id === p.taskId) ??
        fail("TASK_NOT_FOUND");
      if (task.state !== "unknown") fail("INVALID_STATE");
      if (p.receiptId !== task.id) fail("RECEIPT_MISMATCH");
      if (p.outcome === "notAccepted") {
        task.state = "notAccepted";
      } else {
        if (!["running", "succeeded", "failed"].includes(String(p.outcome)))
          fail("INVALID_PARAMS");
        const turnId = text(p.turnId);
        if (task.turnId !== undefined && task.turnId !== turnId)
          fail("TURN_MISMATCH");
        const output = p.outcome === "running" ? undefined : text(p.output);
        task.turnId = turnId;
        task.state = String(p.outcome);
        if (output !== undefined) {
          task.output = output;
          task.delivery = "pending";
        }
      }
      result = structuredClone(task);
    } else if (method === "reconcileDelivery") {
      const task =
        this.state.tasks.find((t) => t.id === p.taskId) ??
        fail("TASK_NOT_FOUND");
      if (task.delivery !== "unknown") fail("INVALID_STATE");
      if (typeof p.deliveryId !== "string" || task.deliveryId !== p.deliveryId)
        fail("DELIVERY_MISMATCH");
      if (typeof p.received !== "boolean") fail("INVALID_PARAMS");
      task.delivery = p.received ? "delivered" : "pending";
      result = structuredClone(task);
    } else if (method === "startTask" || method === "completeTask") {
      const task =
        this.state.tasks.find((t) => t.id === p.taskId) ??
        fail("TASK_NOT_FOUND");
      const turnId = text(p.turnId);
      if (method === "startTask") {
        if (task.state !== "accepted") fail("INVALID_STATE");
        task.turnId = turnId;
        task.state = "running";
      } else {
        if (!["running", "unknown"].includes(task.state)) fail("INVALID_STATE");
        if (task.turnId !== turnId) fail("TURN_MISMATCH");
        if (!["succeeded", "failed"].includes(String(p.outcome)))
          fail("INVALID_PARAMS");
        const output = text(p.output);
        task.state = String(p.outcome);
        task.output = output;
        task.delivery = "pending";
      }
      result = structuredClone(task);
    } else {
      if (admin) fail("SESSION_CREDENTIAL_REQUIRED");
      const source = this.session(auth);
      if (method === "delegate") {
        const target =
          this.state.sessions.find((s) => s.id === p.targetBindingId) ??
          fail("BINDING_NOT_FOUND");
        const kind = text(p.kind);
        if (!["review", "execute"].includes(kind)) fail("INVALID_PARAMS");
        if (
          !source.capabilities.trustedOrigin ||
          !source.capabilities.generatedDelivery ||
          !target.capabilities.trustedOrigin ||
          (kind === "review" && !target.capabilities.restrictedReview) ||
          (kind === "execute" && !target.capabilities.execute)
        )
          fail("CAPABILITY_UNVERIFIED");
        const cwd = workspace(p.cwd),
          planHash = text(p.planHash),
          content = text(p.content);
        if (cwd !== source.cwd || cwd !== target.cwd)
          fail("WORKSPACE_MISMATCH");
        const duration = p.deadlineMs === undefined ? 3_600_000 : p.deadlineMs;
        if (
          typeof duration !== "number" ||
          !Number.isSafeInteger(duration) ||
          duration < 1 ||
          duration > 86_400_000
        )
          fail("INVALID_PARAMS");
        const requestId = text(p.requestId);
        const fingerprint = digest(
          JSON.stringify({
            target: target.id,
            kind,
            content,
            cwd,
            planHash,
            grantId: p.grantId ?? null,
            deadlineMs: duration,
          }),
        );
        const prior = this.state.tasks.find(
          (t) => t.source === source.id && t.requestId === requestId,
        );
        if (prior) {
          if (prior.fingerprint !== fingerprint) fail("REQUEST_ID_CONFLICT");
          return structuredClone(prior);
        }
        let grant: Grant | undefined;
        if (kind === "execute") {
          grant = this.state.grants.find(
            (g) =>
              g.id === p.grantId &&
              g.bindingId === source.id &&
              g.planHash === planHash &&
              g.cwd === cwd &&
              g.contentHash === digest(content) &&
              !g.used,
          );
          if (!grant) fail("EXECUTION_NOT_AUTHORIZED");
        }
        const task: Task = {
          id: id(),
          requestId,
          fingerprint,
          source: source.id,
          target: target.id,
          kind,
          content,
          cwd,
          planHash,
          state: "queued",
          deadline: Date.now() + duration,
          delivery: "none",
        };
        if (grant) grant.used = true;
        this.state.tasks.push(task);
        result = structuredClone(task);
      } else if (
        ["readTask", "claimResult", "ackResult", "cancelTask"].includes(method)
      ) {
        const task = this.task(source, p.taskId);
        if (method === "readTask") result = structuredClone(task);
        if (method === "cancelTask") {
          if (task.state === "queued") {
            task.state = "cancelled";
            result = { cancelled: true };
          } else
            result = {
              cancelled: false,
              reason: active(task)
                ? "SAFE_RUNTIME_CANCEL_UNAVAILABLE"
                : "ALREADY_TERMINAL",
            };
        }
        if (method === "claimResult") {
          if (!["pending", "claimed", "delivered"].includes(task.delivery))
            fail(
              task.delivery === "unknown"
                ? "DELIVERY_OUTCOME_UNKNOWN"
                : "RESULT_NOT_READY",
            );
          if (task.delivery === "delivered") result = { delivered: true };
          else {
            task.delivery = "claimed";
            task.deliveryId ??= id();
            result = {
              deliveryId: task.deliveryId,
              result: {
                output: task.output,
                outcome: task.state,
                planHash: task.planHash,
                source: { kind: "generated", bindingId: task.target },
              },
            };
          }
        }
        if (method === "ackResult") {
          if (task.deliveryId !== p.deliveryId) fail("DELIVERY_MISMATCH");
          if (!["claimed", "delivered"].includes(task.delivery))
            fail("DELIVERY_OUTCOME_UNKNOWN");
          task.delivery = "delivered";
          result = { delivered: true };
        }
      } else fail("UNKNOWN_METHOD");
    }
    this.save();
    return result;
  }
}
