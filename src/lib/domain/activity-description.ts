/** Audit payloads stay in the database; the dashboard describes their meaning. */
export function activityRecordLabel(entity:string){
 const key=entity.toLowerCase().replace(/^public\./,'');
 const labels:Record<string,string>={documents:'Document',document:'Document',accepted_documents:'Accepted agreement',agreements:'Agreement',sales:'Sale',job_receipts:'Receipt',payment_requests:'Payment',quotes:'Quote',quote:'Quote',jobs:'Job',job:'Job',customers:'Customer',customer:'Customer',transactions:'Transaction',transaction:'Transaction',payments:'Payment',expenses:'Expense',refund_requests:'Refund',job_items:'Job item',support_conversations:'Support case',pick_return_orders:'Pickup & delivery'};
 return labels[key]??'Record';
}
export function activityDescription(entity:string,fields:string){
 const label=activityRecordLabel(entity),changes=String(fields??'').toLowerCase();
 if(label==='Document')return /storage_path|storage_bucket|file_name|file_size/.test(changes)?'Document uploaded':'Document updated';
 if(/status|stage/.test(changes))return `${label} status updated`;
 if(/payment|paid|amount|balance/.test(changes))return `${label} payment details updated`;
 return `${label} updated`;
}
