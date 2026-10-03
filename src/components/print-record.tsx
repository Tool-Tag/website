"use client";
export function PrintRecord() {
  return (
    <button className="no-print secondary" onClick={() => window.print()}>
      Print / Save a copy
    </button>
  );
}
