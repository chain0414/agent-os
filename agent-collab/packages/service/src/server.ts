import { createServer } from "node:http";
import { randomBytes, createHash, timingSafeEqual } from "node:crypto";
import {
  mkdirSync,
  chmodSync,
  openSync,
  closeSync,
  writeFileSync,
  readFileSync,
  unlinkSync,
  existsSync,
} from "node:fs";
import { resolve, join } from "node:path";
import { Broker } from "./broker.ts";

export async function startService(directory: string) {
  if (process.platform === "win32") throw new Error("UNIX_SOCKET_REQUIRED");
  const dataDir = resolve(directory);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  chmodSync(dataDir, 0o700);
  const socketPath = join(dataDir, "service.sock");
  if (Buffer.byteLength(socketPath) > 100)
    throw new Error("SOCKET_PATH_TOO_LONG");
  const lockPath = join(dataDir, "service.lock");
  const acquire = () => {
    const fd = openSync(lockPath, "wx", 0o600);
    writeFileSync(fd, String(process.pid));
    closeSync(fd);
  };
  try {
    acquire();
  } catch {
    let owner: number;
    try {
      owner = Number(readFileSync(lockPath, "utf8"));
      if (!Number.isSafeInteger(owner) || owner < 1) throw new Error();
    } catch {
      throw new Error("SERVICE_LOCK_UNREADABLE");
    }
    let alive = true;
    try {
      process.kill(owner, 0);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") alive = false;
    }
    if (alive) throw new Error("SERVICE_ALREADY_RUNNING");
    throw new Error("SERVICE_LOCK_STALE");
  }
  let broker: Broker | undefined;
  try {
    const tokenPath = join(dataDir, "admin-token");
    let adminToken: string;
    if (existsSync(tokenPath)) adminToken = readFileSync(tokenPath, "utf8");
    else {
      adminToken = randomBytes(32).toString("hex");
      writeFileSync(tokenPath, adminToken, { mode: 0o600, flag: "wx" });
    }
    if (!/^[a-f0-9]{64}$/.test(adminToken))
      throw new Error("INVALID_SERVICE_CREDENTIAL");
    chmodSync(tokenPath, 0o600);
    if (existsSync(socketPath)) unlinkSync(socketPath);
    broker = new Broker(dataDir);
    const hash = (s: string) => createHash("sha256").update(s).digest();
    const server = createServer(async (req, res) => {
      const reply = (status: number, value: unknown) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify(value));
      };
      if (req.method !== "POST" || req.url !== "/rpc") {
        reply(404, { ok: false, error: { code: "NOT_FOUND" } });
        return;
      }
      const auth = req.headers.authorization;
      const token = auth?.startsWith("Bearer ") ? auth.slice(7) : "";
      if (!token || token === "admin") {
        reply(401, { ok: false, error: { code: "UNAUTHORIZED" } });
        return;
      }
      const role = timingSafeEqual(hash(token), hash(adminToken))
        ? "admin"
        : token;
      let size = 0;
      const chunks: Buffer[] = [];
      try {
        for await (const chunk of req) {
          size += chunk.length;
          if (size > 1_100_000) {
            reply(413, { ok: false, error: { code: "REQUEST_TOO_LARGE" } });
            return;
          }
          chunks.push(chunk);
        }
        const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (
          typeof body.method !== "string" ||
          !body.params ||
          typeof body.params !== "object" ||
          Array.isArray(body.params)
        )
          throw new Error("INVALID_PARAMS");
        const result = broker!.call(role, body.method, body.params);
        reply(200, { ok: true, result });
      } catch (error) {
        const message = error instanceof Error ? error.message : "";
        const code = /^[A-Z][A-Z0-9_]+$/.test(message)
          ? message
          : "INVALID_PARAMS";
        reply(400, { ok: false, error: { code } });
      }
    });
    server.requestTimeout = 15_000;
    server.headersTimeout = 10_000;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, () => {
        server.removeListener("error", reject);
        resolve();
      });
    });
    chmodSync(socketPath, 0o600);
    let closed = false;
    return {
      socketPath,
      async close() {
        if (closed) return;
        closed = true;
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        );
        broker!.close();
        if (existsSync(socketPath)) unlinkSync(socketPath);
        if (existsSync(lockPath)) unlinkSync(lockPath);
      },
    };
  } catch (error) {
    broker?.close();
    if (existsSync(lockPath)) unlinkSync(lockPath);
    throw error;
  }
}
