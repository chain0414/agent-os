import { stripTypeScriptTypes } from "node:module";
import { readFile, writeFile, mkdir, readdir, rm, cp } from "node:fs/promises";
const source = new URL("../src/", import.meta.url),
  target = new URL("../lib/", import.meta.url);
await rm(target, { recursive: true, force: true });
await mkdir(target, { recursive: true });
for (const file of await readdir(source)) {
  if (!file.endsWith(".ts")) continue;
  const text = await readFile(new URL(file, source), "utf8");
  const output = stripTypeScriptTypes(text, { mode: "strip" }).replace(
    /(from\s+["']\.\/[^"']+)\.ts(["'])/g,
    "$1.js$2",
  );
  await writeFile(new URL(file.replace(/\.ts$/, ".js"), target), output);
}

await cp(
  new URL("../../../contracts/1.0/", import.meta.url),
  new URL("../lib/contracts/1.0/", import.meta.url),
  { recursive: true },
);
