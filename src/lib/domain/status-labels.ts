export const quoteStatusLabel = (status: string) =>
  ({
    Draft: "Borrador",
    Sent: "Enviada",
    Viewed: "Vista",
    Accepted: "Accepted",
    "Agreement Pending": "Agreement Pending",
    Declined: "Rechazada",
    Expired: "Vencida",
    Revised: "Revisada",
  })[status] ?? status;

export const jobStatusLabel = (status: string) =>
  ({
    "Pending Agreement": "Agreement Pending",
    Authorized: "Autorizado",
    "Receiving Documentation": "Documenting Receiving",
    "In Process": "En proceso",
    "Ready for Delivery": "Listo para entrega",
    "Delivered – Pending Customer Acceptance": "Awaiting Acceptance",
    Completed: "Completed",
    Cancelled: "Cancelled",
    "Issue / Review": "Issue / Review",
  })[status] ?? status;

export const workStageLabel = (stage: string) =>
  ({
    "Not Started": "Sin iniciar",
    "Receiving Evidence": "Receiving Evidence",
    Preparing: "Preparation",
    Engraving: "Engraving",
    "Final Evidence": "Engraving",
    "Final Details": "Final Details",
    "Delivery In Progress": "Delivery In Progress",
    "Cancellation Requested / Production Hold": "Cancellation Requested / Production Hold",
    "Awaiting Delivery Acceptance": "Awaiting Acceptance",
    "Issue Review": "Issue / Review",
    Payment: "Payment Pending",
    "Payment Verification": "Verifying Payment",
    Closed: "Completed",
  })[stage] ?? stage;

export const paymentStatusLabel = (status: string) =>
  ({
    "Pending Verification": "Pending Verification",
    Confirmed: "Confirmado",
    Rejected: "Rechazado",
    Cancelled: "Cancelled",
  })[status] ?? status;

export const extensionStatusLabel = (status: string) =>
  ({
    Requested: "Solicitada",
    Draft: "Borrador",
    Sent: "Enviada",
    Approved: "Aprobada",
    Completed: "Completed",
    Cancelled: "Cancelled",
  })[status] ?? status;
