import { execFileSync } from "node:child_process";
import { join } from "node:path";

export const SailGuardPlugin = async (ctx) => {
  return {
    "tool.execute.before": async (event) => {
      const toolName = event?.tool?.toLowerCase();
      if (toolName !== "bash") {
        return;
      }
      const command = event?.input?.command;
      if (!command) {
        return;
      }
      try {
        const scriptPath = join(process.cwd(), "scripts", "sail-guard.sh");
        const payload = JSON.stringify({
          cwd: process.cwd(),
          tool_input: { command }
        });
        execFileSync("bash", [scriptPath], {
          input: payload,
          stdio: ["pipe", "pipe", "pipe"],
          encoding: "utf-8"
        });
      } catch (err) {
        if (err.status === 2) {
          throw new Error(err.stderr ? err.stderr.trim() : "Blocked by sail-guard");
        }
      }
    }
  };
};

export default SailGuardPlugin;
