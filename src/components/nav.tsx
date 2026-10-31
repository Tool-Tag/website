"use client";

import { canAny, sectionPermissions, type Access } from "@/lib/auth/permissions";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import type { WorkspaceAttention } from "@/lib/domain/workspace-attention";

type AttentionKey = Exclude<keyof WorkspaceAttention,"urgency">;

type LinkSpec = {
  path: string;
  label: string;
  count?: number;
  title?: string;
  attentionKey?: AttentionKey;
};

const EMPTY_ATTENTION: WorkspaceAttention = {
  getTagged: 0,
  quotes: 0,
  jobs: 0,
  refunds: 0,
  notifications: 0,
  lost: 0,
};

const ATTENTION_KEYS: AttentionKey[] = [
  "getTagged",
  "quotes",
  "jobs",
  "refunds",
  "notifications",
  "lost",
];

const ATTENTION_PATHS: Record<AttentionKey, string> = {
  getTagged: "/app/get-tagged",
  quotes: "/app/quotes",
  jobs: "/app/jobs",
  refunds: "/app/refunds",
  notifications: "/app/support",
  lost: "/app/lost",
};

const POLL_INTERVAL_MS = 30_000;
const REMINDER_INTERVAL_MS = 5 * 60_000;
const NUDGE_DURATION_MS = 1_600;

function pathIsInside(pathname: string, href: string) {
  if (href === "/app") return pathname === href;
  return pathname === href || pathname.startsWith(`${href}/`);
}

function parseAttention(value: unknown): WorkspaceAttention | null {
  if (!value || typeof value !== "object") return null;

  const row = value as Partial<Record<AttentionKey, unknown>>;
  const next = { ...EMPTY_ATTENTION };

  for (const key of ATTENTION_KEYS) {
    const count = Number(row[key]);
    if (!Number.isFinite(count) || count < 0) return null;
    next[key] = Math.floor(count);
  }

  const colors=(value as WorkspaceAttention).urgency;
  if(colors && [colors.notifications,colors.refunds,colors.lost].every(color=>["red","orange","green"].includes(color)))next.urgency=colors;
  return next;
}

export function Nav({
  attention,
  access = { owner: false, blocks: [] },
  grouped = false, utilities = [],
}: {
  grouped?: boolean; utilities?: {label:string;href:string}[];
  access?: Access;
  attention?: WorkspaceAttention;
}) {
  const path = usePathname();
  const enabled = attention !== undefined;
  const [liveAttention, setLiveAttention] = useState<WorkspaceAttention>(
    attention ?? EMPTY_ATTENTION,
  );
  const liveAttentionRef = useRef<WorkspaceAttention>(
    attention ?? EMPTY_ATTENTION,
  );
  const [nudging, setNudging] = useState<Record<AttentionKey, boolean>>({
    getTagged: false,
    quotes: false,
    jobs: false,
    refunds: false,
    notifications: false,
    lost: false,
  });
  const nudgeTimers = useRef<Partial<Record<AttentionKey, number>>>({});
  const lastNudgeAt = useRef<Record<AttentionKey, number>>({
    getTagged: 0,
    quotes: 0,
    jobs: 0,
    refunds: 0,
    notifications: 0,
    lost: 0,
  });
  const bootstrapped = useRef(false);

  const isAttentionAreaActive = useCallback(
    (key: AttentionKey) => pathIsInside(path, ATTENTION_PATHS[key]),
    [path],
  );

  const clearNudge = useCallback((key: AttentionKey, quietAt?: number) => {
    const timer = nudgeTimers.current[key];
    if (timer !== undefined) {
      window.clearTimeout(timer);
      delete nudgeTimers.current[key];
    }

    setNudging((current) =>
      current[key] ? { ...current, [key]: false } : current,
    );

    if (quietAt !== undefined) {
      lastNudgeAt.current[key] = quietAt;
    }
  }, []);

  const triggerNudge = useCallback(
    (key: AttentionKey, at = Date.now()) => {
      if (isAttentionAreaActive(key)) return;

      const timer = nudgeTimers.current[key];
      if (timer !== undefined) {
        window.clearTimeout(timer);
      }

      lastNudgeAt.current[key] = at;
      setNudging((current) => ({ ...current, [key]: true }));

      nudgeTimers.current[key] = window.setTimeout(() => {
        delete nudgeTimers.current[key];
        setNudging((current) =>
          current[key] ? { ...current, [key]: false } : current,
        );
      }, NUDGE_DURATION_MS);
    },
    [isAttentionAreaActive],
  );

  const applyAttention = useCallback(
    (next: WorkspaceAttention) => {
      const previous = liveAttentionRef.current;
      liveAttentionRef.current = next;
      setLiveAttention(next);

      for (const key of ATTENTION_KEYS) {
        if (next[key] <= 0) {
          clearNudge(key, 0);
          continue;
        }

        if (next[key] > previous[key] && !isAttentionAreaActive(key)) {
          triggerNudge(key);
        }
      }
    },
    [clearNudge, isAttentionAreaActive, triggerNudge],
  );

  const refreshAttention = useCallback(async () => {
    try {
      const response = await fetch("/api/workspace-attention", {
        cache: "no-store",
        headers: { Accept: "application/json" },
      });
      if (!response.ok) return;

      const next = parseAttention(await response.json());
      if (next) applyAttention(next);
    } catch {
      // Keep the latest known counters if the lightweight refresh fails.
    }
  }, [applyAttention]);

  const remindPendingAreas = useCallback(() => {
    const now = Date.now();

    for (const key of ATTENTION_KEYS) {
      if (
        liveAttentionRef.current[key] > 0 &&
        !isAttentionAreaActive(key) &&
        now - lastNudgeAt.current[key] >= REMINDER_INTERVAL_MS
      ) {
        triggerNudge(key, now);
      }
    }
  }, [isAttentionAreaActive, triggerNudge]);

  useEffect(() => {
    if (!enabled || !attention) return;

    const timer = window.setTimeout(() => {
      if (!bootstrapped.current) {
        liveAttentionRef.current = attention;
        setLiveAttention(attention);

        const now = Date.now();
        for (const key of ATTENTION_KEYS) {
          if (attention[key] <= 0) {
            lastNudgeAt.current[key] = 0;
          } else if (isAttentionAreaActive(key)) {
            lastNudgeAt.current[key] = now;
          } else {
            triggerNudge(key, now);
          }
        }

        bootstrapped.current = true;
        return;
      }

      applyAttention(attention);
    }, 0);

    return () => window.clearTimeout(timer);
  }, [
    applyAttention,
    attention,
    enabled,
    isAttentionAreaActive,
    triggerNudge,
  ]);

  useEffect(() => {
    if (!enabled) return;

    const timer = window.setTimeout(() => {
      const now = Date.now();
      for (const key of ATTENTION_KEYS) {
        if (isAttentionAreaActive(key)) {
          clearNudge(key, now);
        }
      }
    }, 0);

    return () => window.clearTimeout(timer);
  }, [clearNudge, enabled, isAttentionAreaActive, path]);

  useEffect(() => {
    if (!enabled) return;

    const tick = () => {
      void refreshAttention();
      remindPendingAreas();
    };

    const initial = window.setTimeout(tick, 0);
    const interval = window.setInterval(tick, POLL_INTERVAL_MS);

    const onFocus = () => tick();
    const onVisibilityChange = () => {
      if (document.visibilityState === "visible") tick();
    };

    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      window.clearTimeout(initial);
      window.clearInterval(interval);
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [enabled, refreshAttention, remindPendingAreas]);

  useEffect(
    () => () => {
      for (const timer of Object.values(nudgeTimers.current)) {
        if (timer !== undefined) window.clearTimeout(timer);
      }
    },
    [],
  );

  const links: LinkSpec[] = [
        { path: "", label: "Dashboard" },
        {
          path: "get-tagged",
          label: "Get Tagged Requests",
          count: liveAttention.getTagged,
          title: "Public requests waiting for review",
          attentionKey: "getTagged",
        },
        {
          path: "quotes",
          label: "Quotes",
          count: liveAttention.quotes,
          title: "Open Quotes not yet converted to a Job",
          attentionKey: "quotes",
        },
        {
          path: "jobs",
          label: "Jobs",
          count: liveAttention.jobs,
          title: "Open Jobs",
          attentionKey: "jobs",
        },
        {path:"shop-floor",label:"Shop Floor"},
        { path: "pick-return", label: "Pick Up & Delivery" },
        { path: "lost", label: "Lost", count:liveAttention.lost,attentionKey:"lost",title:"Lost cases requiring attention" },
        { path: "customers", label: "Customers" },
        { path: "finance", label: "Finance" },
        {
          path: "refunds",
          label: "Refunds",
          count: liveAttention.refunds,
          title: "Active refund cases",
          attentionKey: "refunds",
        },
        { path: "support", label: "Support", count: liveAttention.notifications, title: "Pending customer responses", attentionKey: "notifications" },
        { path: "equipment", label: "Equipment" },
      ];

  const renderLink = (link:LinkSpec) => {
        const href = `/app${link.path ? "/" + link.path : ""}`;
        const active = pathIsInside(path, href);
        const count = Number(link.count ?? 0);
        const delicate=link.attentionKey === "notifications" || link.attentionKey === "refunds" || link.attentionKey === "lost";
        const color=delicate?liveAttention.urgency?.[link.attentionKey as "notifications"|"refunds"|"lost"]??"green":undefined;
        const isNudging =
          Boolean(link.attentionKey) &&
          Boolean(link.attentionKey && nudging[link.attentionKey]);

        return (
          <Link
            key={link.path}
            href={href}
            aria-current={active ? "page" : undefined}
            aria-label={
              count > 0
                ? `${link.label}, ${count} requiring attention`
                : link.label
            }
            title={link.title}
            className="workspace-nav-link"
          >
            <span>{link.label}</span>
            {(count > 0 || delicate) && (
              <span
                className={`workspace-nav-count workspace-nav-count-${color??"neutral"}${isNudging ? " workspace-nav-count-attention" : ""}`}
                aria-hidden="true"
              >
                {count > 99 ? "99+" : count}
              </span>
            )}
          </Link>
        );
      };
  const visible=links.filter(link=>canAny(access,link.path==='shop-floor'?['jobs.view','production.work']:sectionPermissions(link.path)));
  if(!grouped)return <nav>{visible.map(renderLink)}</nav>;
  const groups=[{name:"Main",paths:["","get-tagged","quotes"],utility:[]},{name:"Operations",paths:["jobs","shop-floor","pick-return","lost"],utility:["/pick-return","/hub"]},{name:"Business",paths:["customers","finance","refunds","support","equipment"],utility:["/app/finance-hub","/"]},{name:"System",paths:[],utility:["/app/settings"]}];
  return <nav aria-label="Mobile workspace navigation">{groups.map(group=><section key={group.name} className="mobile-nav-section"><h3>{group.name}</h3>{visible.filter(link=>group.paths.includes(link.path)).map(renderLink)}{utilities.filter(link=>group.utility.includes(link.href)).map(link=><Link className="workspace-nav-link" key={link.href} href={link.href}>{link.label}</Link>)}</section>)}</nav>;
}
