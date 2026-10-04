"use client";

import { useState, type ReactNode } from "react";

type JobTab = {
  id: string;
  label: string;
  count?: number;
  content: ReactNode;
};

export function JobTabs({
  tabs,
  defaultTab = "work",
}: {
  tabs: JobTab[];
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
      <nav className="job-tab-list no-print" role="tablist" aria-label="Secciones">
        {tabs.map((tab) => {
          const selected = tab.id === current.id;
          return (
            <button
              key={tab.id}
              type="button"
              role="tab"
              aria-selected={selected}
              aria-controls={`job-panel-${tab.id}`}
              id={`job-tab-${tab.id}`}
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
        id={`job-panel-${current.id}`}
        role="tabpanel"
        aria-labelledby={`job-tab-${current.id}`}
        className="job-tab-panel"
      >
        {current.content}
      </section>
    </div>
  );
}
