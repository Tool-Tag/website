"use client";
import { usePathname, useRouter } from "next/navigation";

export function BackNavigation() {
  const path = usePathname();
  const router = useRouter();
  if (path === "/app") return null;

  function goBack() {
    if (window.history.length > 1) router.back();
    else router.replace("/app");
  }

  return <p className="workspace-back"><button type="button" className="secondary gold" onClick={goBack}>← Back</button></p>;
}
