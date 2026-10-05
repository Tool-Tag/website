export const quoteStatusLabel = (status: string) =>
  ({
    Draft: "Borrador",
    Sent: "Enviada",
    Viewed: "Vista",
    Accepted: "Aceptada",
    "Agreement Pending": "Pendiente de acuerdo",
    Declined: "Rechazada",
    Expired: "Vencida",
    Revised: "Revisada",
  })[status] ?? status;

export const jobStatusLabel = (status: string) =>
  ({
    "Pending Agreement": "Pendiente de acuerdo",
    Authorized: "Autorizado",
    "Receiving Documentation": "Documentando recepción",
    "In Process": "En proceso",
    "Ready for Delivery": "Listo para entrega",
    "Delivered – Pending Customer Acceptance": "Esperando aceptación",
    Completed: "Completado",
    Cancelled: "Cancelado",
    "Issue / Review": "Incidencia / revisión",
  })[status] ?? status;

export const workStageLabel = (stage: string) =>
  ({
    "Not Started": "Sin iniciar",
    "Receiving Evidence": "Evidencia de recepción",
    Preparing: "Preparation",
    Engraving: "Engraving",
    "Final Evidence": "Engraving",
    "Final Details": "Final Details",
    "Delivery In Progress": "Delivery In Progress",
    "Awaiting Delivery Acceptance": "Esperando aceptación",
    "Issue Review": "Incidencia / revisión",
    Payment: "Pago pendiente",
    "Payment Verification": "Verificando pago",
    Closed: "Completado",
  })[stage] ?? stage;

export const paymentStatusLabel = (status: string) =>
  ({
    "Pending Verification": "Pendiente de verificación",
    Confirmed: "Confirmado",
    Rejected: "Rechazado",
    Cancelled: "Cancelado",
  })[status] ?? status;

export const extensionStatusLabel = (status: string) =>
  ({
    Requested: "Solicitada",
    Draft: "Borrador",
    Sent: "Enviada",
    Approved: "Aprobada",
    Completed: "Completada",
    Cancelled: "Cancelada",
  })[status] ?? status;
