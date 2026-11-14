"use client";

import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";

export function WorkspaceNavigationProgress() {
  const pathname = usePathname();
  const search = useSearchParams().toString();
  const route = search ? `${pathname}?${search}` : pathname;
  const [pendingFrom, setPendingFrom] = useState<string | null>(null);
  const [previousRoute, setPreviousRoute] = useState(route);
  if (previousRoute !== route) {
    setPreviousRoute(route);
    setPendingFrom(null);
  }

  useEffect(() => {
    let timeout: number | undefined;
    function start(event: MouseEvent) {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const link = event.target instanceof Element ? event.target.closest<HTMLAnchorElement>("a[href]") : null;
      if (!link || (link.target && link.target !== "_self") || link.hasAttribute("download")) return;
      const url = new URL(link.href);
      if (url.origin !== location.origin || !/^\/app(?:\/|$)/.test(url.pathname)) return;
      const destination = new URLSearchParams(url.search);
      const current = new URLSearchParams(location.search);
      destination.sort();
      current.sort();
      if (url.pathname === location.pathname && destination.toString() === current.toString()) return;

      setPendingFrom(route);
      window.clearTimeout(timeout);
      timeout = window.setTimeout(() => setPendingFrom(null), 8000);
    }
    document.addEventListener("click", start, true);
    return () => {
      document.removeEventListener("click", start, true);
      window.clearTimeout(timeout);
    };
  }, [route]);

  return pendingFrom === route ? <div className="workspace-navigation-progress" role="status">Loading page…</div> : null;
}
