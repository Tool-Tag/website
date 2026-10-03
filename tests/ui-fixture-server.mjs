// LOCAL TEST TRANSPORT ONLY. This is not Supabase Auth/PostgREST and is never imported by the app.
// Runs the actual migrations and RPCs against isolated in-memory PostgreSQL for browser smoke tests.
import { createServer } from "node:http";
import { readFile, readdir } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
const db = new PGlite();
const admin = "90000000-0000-0000-0000-000000000001";
const unit = "10000000-0000-0000-0000-000000000002";
await db.exec(
  `create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;create function auth.role() returns text language sql stable as $$select current_setting('request.jwt.claim.role',true)$$;grant usage on schema auth to anon,authenticated,service_role;grant execute on all functions in schema auth to anon,authenticated,service_role;`,
);
for (const f of (await readdir("supabase/migrations")).sort())
  await db.exec(await readFile(`supabase/migrations/${f}`, "utf8"));
await db.exec(
  `insert into auth.users values('${admin}');insert into public.memberships select id,'${admin}','admin' from public.business_units;select set_config('request.jwt.claim.sub','${admin}',false);`,
);
await db.query("select public.publish_policy($1,$2,$3)", [
  unit,
  "LOCAL TEST — NOT A LEGAL AGREEMENT",
  "This is an isolated test fixture. These words are not legal terms and must never be sent to a real customer.",
]);
const user = {
  id: admin,
  email: "admin@example.test",
  aud: "authenticated",
  role: "authenticated",
  created_at: new Date().toISOString(),
  app_metadata: { provider: "email" },
  user_metadata: {},
  identities: [],
};
const token =
  Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString(
    "base64url",
  ) +
  "." +
  Buffer.from(
    JSON.stringify({
      sub: admin,
      role: "authenticated",
      aud: "authenticated",
      exp: Math.floor(Date.now() / 1000) + 86400,
      iat: Math.floor(Date.now() / 1000),
      iss: "http://127.0.0.1:54329/auth/v1",
    }),
  ).toString("base64url") +
  ".local_test_only";
let queue = Promise.resolve();
const identifier = (x) => {
  if (!/^[a-z_]+$/.test(x)) throw Error("Invalid identifier");
  return `"${x}"`;
};
createServer(async (req, res) => {
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") {
    res.end();
    return;
  }
  const url = new URL(req.url, "http://127.0.0.1:54329");
  let body = "";
  for await (const c of req) body += c;
  const json = () => (body ? JSON.parse(body) : {});
  const send = (value, status = 200) => {
    res.statusCode = status;
    res.end(JSON.stringify(value));
  };
  if (url.pathname === "/auth/v1/token") {
    const p = json();
    if (
      p.email !== "admin@example.test" ||
      p.password !== "local-test-password"
    ) {
      send({ msg: "Test credentials only" }, 400);
      return;
    }
    send({
      access_token: token,
      refresh_token: "local-refresh-only",
      token_type: "bearer",
      expires_in: 86400,
      expires_at: Math.floor(Date.now() / 1000) + 86400,
      user,
    });
    return;
  }
  if (url.pathname === "/auth/v1/user") {
    if (req.headers.authorization !== `Bearer ${token}`) {
      send({ msg: "Unauthorized" }, 401);
      return;
    }
    send(user);
    return;
  }
  if (url.pathname === "/auth/v1/logout") {
    send({});
    return;
  }
  queue = queue
    .then(async () => {
      try {
        const isAdmin = req.headers.authorization === `Bearer ${token}`;
        await db.exec(
          `reset role;select set_config('request.jwt.claim.sub','${isAdmin ? admin : ""}',false);select set_config('request.jwt.claim.role','${isAdmin ? "authenticated" : "anon"}',false);set role ${isAdmin ? "authenticated" : "anon"};`,
        );
        if (url.pathname.startsWith("/rest/v1/rpc/")) {
          const name = identifier(url.pathname.split("/").pop());
          const p = json(),
            keys = Object.keys(p),
            values = Object.values(p).map((v) =>
              typeof v === "object" ? JSON.stringify(v) : v,
            );
          const result = await db.query(
            `select public.${name}(${keys.map((k, i) => `${identifier(k)} => $${i + 1}`).join(",")}) as value`,
            values,
          );
          send(
            result.rows.length === 1
              ? result.rows[0].value
              : result.rows.map((r) => r.value),
          );
          return;
        }
        if (url.pathname.startsWith("/rest/v1/") && req.method === "GET") {
          const table = identifier(url.pathname.split("/").pop());
          const values = [],
            where = [];
          for (const [k, v] of url.searchParams) {
            if (["select", "order", "limit", "offset"].includes(k)) continue;
            if (k === "or") {
              const match = v.match(
                /^\(unit_id.eq.([a-f0-9-]+),unit_id.is.null\)$/,
              );
              if (!match) throw Error("Unsupported test filter");
              values.push(match[1]);
              where.push(`(unit_id=$${values.length} or unit_id is null)`);
              continue;
            }
            if (!v.startsWith("eq.")) throw Error("Unsupported filter");
            values.push(v.slice(3));
            where.push(`${identifier(k)}=$${values.length}`);
          }
          const order = url.searchParams.get("order");
          const [col, dir] = order?.split(".") ?? [];
          const result = await db.query(
            `select * from public.${table}${where.length ? " where " + where.join(" and ") : ""}${col ? " order by " + identifier(col) + (dir === "desc" ? " desc" : " asc") : ""} limit ${Math.min(1000, Number(url.searchParams.get("limit") ?? 200))}`,
            values,
          );
          res.setHeader(
            "Content-Range",
            `0-${Math.max(0, result.rows.length - 1)}/${result.rows.length}`,
          );
          send(
            req.headers.accept?.includes("vnd.pgrst.object")
              ? (result.rows[0] ?? null)
              : result.rows,
          );
          return;
        }
        send({ message: "Unsupported test endpoint" }, 404);
      } catch (e) {
        send({ message: e.message, code: e.code ?? "TEST" }, 400);
      }
    })
    .catch((e) => send({ message: e.message }, 500));
}).listen(54329, "127.0.0.1", () =>
  console.log(
    "Isolated SQL/UI fixture listening on 127.0.0.1:54329. No real data or Auth.",
  ),
);
