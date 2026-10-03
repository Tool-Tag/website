import { cp, mkdir } from "node:fs/promises";
// dist remains the source of truth for the existing public website and local tools.
await mkdir("public", { recursive: true });
await cp("dist", "public", { recursive: true });
