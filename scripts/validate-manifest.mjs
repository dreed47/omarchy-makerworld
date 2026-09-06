// Minimal manifest sanity check, run from `npm run check`.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const m = JSON.parse(readFileSync(join(root, "manifest.json"), "utf8"));

const problems = [];
if (m.schemaVersion !== 1) problems.push("schemaVersion must be 1");
if (!/^[a-z0-9.]+\.[a-z0-9-]+$/i.test(m.id || "")) problems.push("id looks wrong: " + m.id);
if (!m.version) problems.push("missing version");
if (!Array.isArray(m.kinds) || !m.kinds.includes("service")) problems.push("kinds must include 'service'");
if (!m.entryPoints || m.entryPoints.service !== "Service.qml") problems.push("entryPoints.service must be 'Service.qml'");
if (m.version !== JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version)
  problems.push("manifest.json and package.json versions differ");

if (problems.length) {
  console.error("manifest invalid:\n - " + problems.join("\n - "));
  process.exit(1);
}
console.log("manifest ok (" + m.id + " v" + m.version + ")");
