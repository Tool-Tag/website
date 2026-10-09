"use client";

import { useState, type ReactNode } from "react";

type QuoteTab = {
  id: string;
  label: string;
  count?: number;
  content: ReactNode;
};

export function QuoteTabs({
  tabs,
  defaultTab = "active",
}: {
  tabs: QuoteTab[];
  defaultTab?: string;
}) {
  const initial = tabs.some((tab) => tab.id === defaultTab)
    ? defaultTab
    : tabs[0]?.id ?? "";
  const [active, setActive] = useState(initial);
  const current = tabs.find((tab) => tab.id === active) ?? tabs[0];

  if (!current) return null;

  return (
    <div className="job-tabs">
      <nav
        className="job-tab-list no-print"
        role="tablist"
        aria-label="Quote Status Tabs"
      >
        {tabs.map((tab) => {
          const selected = tab.id === current.id;
          return (
            <button
              key={tab.id}
              type="button"
              role="tab"
              aria-selected={selected}
              aria-controls={`quote-panel-${tab.id}`}
              id={`quote-tab-${tab.id}`}
              className={selected ? "job-tab active" : "job-tab"}
              onClick={() => setActive(tab.id)}
            >
              {tab.label}
              {typeof tab.count === "number" && (
                <span className="tab-count">{tab.count}</span>
              )}
            </button>
          );
        })}
      </nav>

      <section
        id={`quote-panel-${current.id}`}
        role="tabpanel"
        aria-labelledby={`quote-tab-${current.id}`}
        className="job-tab-panel"
      >
        {current.content}
      </section>
    </div>
  );
}
