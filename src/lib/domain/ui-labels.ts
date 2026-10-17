/** Display names only; never change persisted enum values, request payloads or URLs. */
export function displayLabel(value:string) {
 const labels:Record<string,string>={Return:"Delivery",Returns:"Deliveries","Return Scheduled":"Delivery Scheduled","Return En Route":"Delivery En Route","Return In Progress":"Delivery In Progress","Return Missed":"Delivery Missed","Pickup & Return":"Pickup & Delivery","Pick up & Return":"Pick up & Delivery"};
 return labels[value]??value;
}
