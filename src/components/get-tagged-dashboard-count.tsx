"use client";

import { useEffect, useState } from "react";
import { Metric } from "./ui";
import { GET_TAGGED_COUNT_EVENT } from "@/lib/domain/workspace-attention-events";

export function GetTaggedDashboardCount({ initial }: { initial: number | "Unavailable" }) {
  const [count, setCount] = useState<number | "Unavailable">(initial);

  useEffect(() => {
    function update(event: Event) {
      const next = (event as CustomEvent<number>).detail;
      if (Number.isSafeInteger(next) && next >= 0) setCount(next);
    }
    window.addEventListener(GET_TAGGED_COUNT_EVENT, update);
    return () => window.removeEventListener(GET_TAGGED_COUNT_EVENT, update);
  }, []);

  return <Metric label="New Get Tagged requests" currency={false} value={count} />;
}
