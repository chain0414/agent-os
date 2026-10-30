import { startService } from "./server.ts";
import { request } from "./client.ts";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const [command, flag, directory] = process.argv.slice(2);
try {
  if (
    flag !== "--data-dir" ||
    !directory ||
    !["start", "health"].includes(command)
  )
    throw new Error(
      "USAGE: agent-collab start|health --data-dir <private-directory>",
    );
  if (command === "start") {
    const service = await startService(directory);
    console.log(
      JSON.stringify({
        status: "listening",
        socketPath: service.socketPath,
        nativeInteropVerified: false,
      }),
    );
    for (const signal of ["SIGINT", "SIGTERM"])
      process.once(signal, async () => {
        await service.close();
        process.exitCode = 0;
      });
  } else {
    const token = readFileSync(join(directory, "admin-token"), "utf8");
    const result = await request({
      socketPath: join(directory, "service.sock"),
      token,
      method: "health",
    });
    console.log(JSON.stringify(result));
  }
} catch (error) {
  const code =
    error instanceof Error && /^[A-Z_]+$/.test(error.message)
      ? error.message
      : "COMMAND_FAILED";
  console.error(JSON.stringify({ status: "error", code }));
  process.exitCode = 1;
}
