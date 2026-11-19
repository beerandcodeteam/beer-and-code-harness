import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url));

function resolveScript() {
  const candidates = [
    join(PLUGIN_DIR, "scripts", "sail-guard.sh"),
    join(PLUGIN_DIR, "sail-guard.sh"),
    join(process.cwd(), "scripts", "sail-guard.sh"),
  ];
  return candidates.find((path) => existsSync(path));
}

export const SailGuardPlugin = async (ctx) => {
  return {
    "tool.execute.before": async (input, output) => {
      const toolName = input?.tool?.toLowerCase();
      if (toolName !== "bash") {
        return;
      }
      const command = output?.args?.command;
      if (!command) {
        return;
      }
      const scriptPath = resolveScript();
      if (!scriptPath) {
        return;
      }
      try {
        const payload = JSON.stringify({
          cwd: process.cwd(),
          tool_input: { command },
        });
        execFileSync("bash", [scriptPath], {
          input: payload,
          stdio: ["pipe", "pipe", "pipe"],
          encoding: "utf-8",
        });
      } catch (err) {
        if (err.status === 2) {
          throw new Error(err.stderr ? err.stderr.trim() : "Blocked by sail-guard");
        }
      }
    },
  };
};

export default SailGuardPlugin;
