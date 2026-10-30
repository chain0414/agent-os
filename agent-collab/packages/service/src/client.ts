import { request as httpRequest } from "node:http";
export type RequestOptions = {
  socketPath: string;
  token: string;
  method: string;
  params?: Record<string, unknown>;
};
/** Credentials belong to the adapter process, never to model-visible arguments. */
export function request(options: RequestOptions): Promise<any> {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      method: options.method,
      params: options.params ?? {},
    });
    const req = httpRequest(
      {
        socketPath: options.socketPath,
        path: "/rpc",
        method: "POST",
        headers: {
          authorization: `Bearer ${options.token}`,
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
        },
      },
      (res) => {
        const interrupted = () => reject(new Error("SERVICE_UNAVAILABLE"));
        res.once("aborted", interrupted);
        res.once("error", interrupted);
        res.once("close", () => {
          if (!res.complete) interrupted();
        });
        const chunks: Buffer[] = [];
        let size = 0;
        res.on("data", (chunk) => {
          size += chunk.length;
          if (size > 2_000_000) {
            req.destroy();
            reject(new Error("RESPONSE_TOO_LARGE"));
          } else chunks.push(chunk);
        });
        res.on("end", () => {
          try {
            const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
            if (value.ok) resolve(value.result);
            else
              reject(
                new Error(
                  typeof value.error?.code === "string"
                    ? value.error.code
                    : "REQUEST_FAILED",
                ),
              );
          } catch {
            reject(new Error("INVALID_RESPONSE"));
          }
        });
      },
    );
    req.setTimeout(10_000, () => req.destroy(new Error("REQUEST_TIMEOUT")));
    req.on("error", () => reject(new Error("SERVICE_UNAVAILABLE")));
    req.end(body);
  });
}
