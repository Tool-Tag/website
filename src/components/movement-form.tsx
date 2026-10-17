"use client";
import Link from "next/link";
import { useState } from "react";
import {MileageForm} from "./mileage-form";
import {EvidenceUpload} from "./evidence-upload";
import { Form, type Field } from "./form";
type Option = { value: string; label: string };
export function MovementForm({
  requestId,
  accounts,
  categories,
  sales,
  expenses,

  destinationAccounts,
  defaultType = "EXPENSE",
  saleId,
  vendors,
  lostCaseId,
  onSaved,
}: {
  requestId: string;
  lostCaseId?: string;
  onSaved?: (data:unknown)=>void;
  accounts: Option[];
  categories: Option[];
  sales: Option[];
  expenses: Option[];
  collections: Option[];
  destinationAccounts: Option[];
  defaultType?: string;
  saleId?: string;
  vendors: string[];
}) {
  const [amount,setAmount]=useState("");
  const [proofId,setProofId]=useState("");
  const [type, setType] = useState(defaultType);
  const [subtype, setSubtype] = useState("Personal Draw");
  const [paidBy, setPaidBy] = useState("Business");
  const today = new Date().toLocaleDateString("en-CA");
  const fields: Field[] = [
    { name: "amount", label: "Amount (USD)", type: "number", required: true },
    {
      name: "transaction_date",
      label: "Transaction Date",
      type: "date",
      value: today,
      required: true,
    },
    {
      name: "account_id",
      label: "Attributed Account",
      options: accounts,
      required: true,
      value: accounts[0]?.value,
    },
    { name: "description", label: "Description / Purpose", required: true },
  ];
  if (type === "EXPENSE")
    fields.push(
      {
        name: "category_id",
        label: "Category",
        options: categories,
        required: true,
      },
      {
        name: "vendor",
        label: "Vendor — Select or Enter a New One",
        required: true,
        suggestions: vendors,
      },
      {
        name: "lodging",
        label: "Lodging?",
        value: "false",
        options: [
          { value: "false", label: "No" },
          { value: "true", label: "Yes: Receipt Always Required" },
        ],
      },
    );
  if (type === "COLLECTION" && !saleId)
    fields.push({
      name: "sale_id",
      label: "Sale (blank = unlinked collection for review)",
      options: sales,
    });
  if (type === "COLLECTION")
    fields.push({
      name: "payment_method",
      label: "Payment Method",
      required: true,
      options: ["Cash", "Zelle", "Venmo"].map((value) => ({
        value,
        label: value,
      })),
    });
  if (type === "REFUND")
    fields.push({
      name: "original_id",
      label: "Original Expense (vendor refund)",
      required: true,
      options: expenses,
    });
  if (type === "INTER_UNIT_TRANSFER")
    fields.push({
      name: "destination_account_id",
      label: "BOFT Destination Account",
      options: destinationAccounts,
      required: true,
    });
  fields.push(
    { name: "reference", label: "Reference (optional)" },
    {
      name: "reason",
      label: "Exception Reason / Closed-Month Change",
      help: "Required if the period is closed or the refund exceeds the 14-day window.",
      wide: true,
    },
  );
  return (
    <>
      <div className="formgrid" style={{ marginBottom: 20 }}>
        <label>Type<select
            value={type}
            disabled={!!saleId||Boolean(lostCaseId)}
            onChange={(e) => setType(e.target.value)}
          >
            {[
              ["EXPENSE", "Expense"],
              ["COLLECTION", "Collection"],
              ["OWNER_INJECTION", "Owner Injection"],
              ["OWNER_DRAW", "Owner Draw / Reimbursement"],
              ["INTER_UNIT_TRANSFER", "Internal Transfer to BOFT"],
              ["REFUND", "Refund"],
              ["MILEAGE", "Trip/Mileage"],
            ].map(([v, l]) => (
              <option value={v} key={v}>
                {l}
              </option>
            ))}
          </select>
        </label>
        {type === "EXPENSE" && (
          <label>
            Paid by
            <select value={paidBy} onChange={(e) => setPaidBy(e.target.value)}>
              <option value="Business">ToolTag / Main Account</option>
              <option value="Owner">Owner — creates reimbursement due</option>
            </select>
          </label>
        )}
        {type === "OWNER_DRAW" && (
          <label>
            Subtype
            <select
              value={subtype}
              onChange={(e) => setSubtype(e.target.value)}
            >
              <option>Personal Draw</option>
              <option>Reimbursement</option>
            </select>
          </label>
        )}
      </div>
      {type === "REFUND" && <p className="notice">Customer refunds must be linked to a Job. <Link href="/app/refunds">Open refund case management</Link></p>}
      {type==="EXPENSE"&&<section className="panel"><h3>Expense receipt</h3><p>A receipt image is required for expenses of $75 or more. Take a photo or choose an image, then upload it before recording the expense.</p>{proofId?<><p role="status">Receipt image ready.</p><button type="button" className="secondary" onClick={()=>setProofId("")}>Replace receipt</button></>:<EvidenceUpload config={{type:"Other",expenseProof:true,photoOnly:true,defaultVisibility:"internal"}} accept="image/png,image/jpeg,image/webp" button="Upload receipt image" onStored={setProofId}/>}</section>}
      {type==="EXPENSE"&&Number(amount)>=75&&!proofId&&<p className="notice error" role="alert">Upload a receipt photo before recording this expense. Expenses of $75 or more cannot be processed without a stored image.</p>}
      {type==="MILEAGE"?<MileageForm onSaved={onSaved}/>:<Form
        onFieldChange={(name,value)=>{if(name==="amount")setAmount(value);}}
        submitDisabled={type==="EXPENSE"&&Number(amount)>=75&&!proofId}
        key={`${type}:${subtype}:${paidBy}`}
        operation="movement"
        onSaved={onSaved?(data)=>onSaved({type,id:data}):undefined}
        fields={fields}
        hidden={{
          request_id: requestId,
          ...(type==="EXPENSE"&&proofId?{proof_id:proofId}:{}),
          ...(lostCaseId ? {lost_id:lostCaseId} : {}),
          type,
          subtype,
          paid_by: paidBy,
          ...(saleId ? { sale_id: saleId } : {}),
          ...(type === "INTER_UNIT_TRANSFER"
            ? { destination_unit_id: "10000000-0000-0000-0000-000000000001" }
            : {}),
        }}
        back={
          onSaved ? "" : saleId ? `/app/finance/sales/${saleId}` : "/app/finance/transactions"
        }
        button="Record Transaction"
      />}
    </>
  );
}
