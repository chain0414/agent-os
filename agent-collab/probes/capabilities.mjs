/** A schema is static evidence, never proof of successful native delivery. */
export function inspectSchema(schema) {
  let toolOutputDeclared = false;
  function visit(value) {
    if (!value || typeof value !== "object") return;
    if (value.properties && Object.hasOwn(value.properties, "toolOutput"))
      toolOutputDeclared = true;
    for (const child of Object.values(value)) visit(child);
  }
  visit(schema);
  return { toolOutputDeclared, runtimeVerified: false };
}
export function inspectDshSource({ tools, controller }) {
  return {
    callerContextDeclared: /readonly\s+agent\??\s*:\s*Agent/.test(tools),
    promptCreatesUserInput: /kind\s*:\s*['"]user['"]/.test(controller),
    runtimeVerified: false,
  };
}
