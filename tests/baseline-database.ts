import { Client, type QueryResultRow } from "pg";
import { readFile, readdir } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
const run = promisify(execFile);
const localUrl = process.env.BASELINE_DATABASE_URL;
export class BaselineDatabase {
  private client!: Client;
  private name = `baseline_test_${randomUUID().replaceAll("-", "")}`;
  private ready: Promise<void>;
  constructor() {
    this.ready = this.initialize();
  }
  private async initialize() {
    if (!localUrl) throw new Error("A local baseline database URL is required");
    const parsed = new URL(localUrl);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(parsed.hostname)) throw new Error("Baseline tests may only use a local database");
    const admin = new Client({ connectionString: localUrl });
    await admin.connect();
    await admin.query(`CREATE DATABASE ${this.name}`);
    await admin.end();
    parsed.pathname = `/${this.name}`;
    this.client = new Client({ connectionString: parsed.href });
    await this.client.connect();
    await this.client.query(await readFile("supabase/baseline-stage1-support/platform-prerequisites.sql", "utf8"));
    for (const file of (await readdir("supabase/migrations")).filter(file => file.endsWith(".sql")).sort()) {
      // Use PostgreSQL's restore client so COPY FROM stdin is preserved exactly.
      await run(path.join(process.env.BASELINE_PG_BIN || "", "psql"), ["-X", "-v", "ON_ERROR_STOP=1", "-f", `supabase/migrations/${file}`], {
        env: { ...process.env, PGHOST: parsed.hostname, PGPORT: parsed.port || "5432", PGUSER: decodeURIComponent(parsed.username), PGPASSWORD: decodeURIComponent(parsed.password), PGDATABASE: this.name },
      });
    }
    // A successful pg_dump restore deliberately disables body checks. Restore normal test behavior.
    await this.client.query("SET check_function_bodies=on; SET row_security=on; SET search_path=public");
  }
  async exec(sql: string) { await this.ready; await this.client.query(sql); }
  async query<T extends QueryResultRow>(sql: string, args: unknown[] = []): Promise<{rows:T[]}> {
    await this.ready;
    return this.client.query<T>(sql,args);
  }
  async close() {
    try { await this.ready; } finally {
      if (this.client) await this.client.end();
      const admin = new Client({connectionString:localUrl}); await admin.connect();
      await admin.query(`DROP DATABASE IF EXISTS ${this.name} WITH (FORCE)`); await admin.end();
    }
  }
}
