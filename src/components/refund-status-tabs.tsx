"use client";
import {createContext, useContext, useState, type ReactNode} from "react";

export const REFUND_CASE_STATUSES = ["Pending", "In Review", "Approved", "Issued"] as const;
type RefundTab = (typeof REFUND_CASE_STATUSES)[number] | "History";
const RefundTabContext = createContext<RefundTab | null>(null);
export function useRefundTab() { return useContext(RefundTabContext); }

/** Keep case dialogs mounted when an open Pending case moves into In Review. */
export function RefundStatusTabs({counts,historyCount,create,history,children}:{
 counts:Record<(typeof REFUND_CASE_STATUSES)[number],number>;
 historyCount:number;
 create:ReactNode;
 history:ReactNode;
 children:ReactNode;
}) {
 const [selected,setSelected]=useState<RefundTab>("Pending");
 const tabs=[...REFUND_CASE_STATUSES,"History"] as const;
 const slug=(tab:RefundTab)=>tab.toLowerCase().replaceAll(" ","-");
 const count=selected==="History"?historyCount:counts[selected];
 return <RefundTabContext.Provider value={selected}><div className="job-tabs">
  <nav className="job-tab-list no-print" role="tablist" aria-label="Refund status">
   {tabs.map(tab=><button key={tab} type="button" role="tab" id={`refund-tab-${slug(tab)}`} aria-selected={selected===tab} aria-controls={`refund-panel-${slug(tab)}`} className={selected===tab?"job-tab active":"job-tab"} onClick={()=>setSelected(tab)}>{tab}<span className="tab-count">{tab==="History"?historyCount:counts[tab]}</span></button>)}
  </nav>
  <section role="tabpanel" id={`refund-panel-${slug(selected)}`} aria-labelledby={`refund-tab-${slug(selected)}`} className="job-tab-panel">
   <div hidden={selected!=="Pending"}>{create}</div>
   {selected!=="History"&&count===0&&<p className="empty">No {selected.toLowerCase()} refunds.</p>}
   {children}
   <div hidden={selected!=="History"}>{history}</div>
  </section>
 </div></RefundTabContext.Provider>;
}
