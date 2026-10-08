"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { WorkspaceAttention } from "@/lib/domain/workspace-attention";

type LinkSpec = {
  path: string;
  label: string;
  count?: number;
  title?: string;
};

export function Nav({
  bottom = false,
  attention,
}: {
  bottom?: boolean;
  attention?: WorkspaceAttention;
}) {
  const path = usePathname();

  const links: LinkSpec[] = bottom
    ? [
        { path: "finance-hub", label: "Finance Hub" },
        { path: "settings", label: "Settings" },
      ]
    : [
        { path: "", label: "Dashboard" },
        {
          path: "get-tagged",
          label: "Get Tagged Requests",
          count: attention?.getTagged,
          title: "Public requests waiting for review",
        },
        {
          path: "quotes",
          label: "Quotes",
          count: attention?.quotes,
          title: "Open Quotes not yet converted to a Job",
        },
        {
          path: "jobs",
          label: "Jobs",
          count: attention?.jobs,
          title: "Open Jobs",
        },
        { path: "customers", label: "Customers" },
        { path: "finance", label: "Finance" },
        {
          path: "refunds",
          label: "Refunds",
          count: attention?.refunds,
          title: "Cancellation refunds waiting to be issued",
        },
        { path: "equipment", label: "Equipment" },
      ];

  return (
    <nav>
      {links.map((link) => {
        const href = `/app${link.path ? "/" + link.path : ""}`;
        const active = path === href;
        const count = Number(link.count ?? 0);

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
            {count > 0 && (
              <span className="workspace-nav-count" aria-hidden="true">
                {count > 99 ? "99+" : count}
              </span>
            )}
          </Link>
        );
      })}
    </nav>
  );
}
