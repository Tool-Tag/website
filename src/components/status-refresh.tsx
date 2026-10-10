"use client";
import {useEffect, useTransition} from "react";
import {useRouter} from "next/navigation";
export function StatusRefresh() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  useEffect(() => {
    const timer = window.setInterval(() => {
      if (!pending && document.visibilityState === "visible") startTransition(() => router.refresh());
    }, 20000);
    return () => window.clearInterval(timer);
  }, [router, pending]);
  return null;
}
