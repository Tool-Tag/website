export const quoteStatusLabel = (status: string) =>
  ({
    Draft: "Draft",
    Sent: "Sent",
    Viewed: "Viewed",
    Accepted: "Accepted",
    "Agreement Pending": "Agreement Pending",
    Declined: "Declined",
    Expired: "Expired",
    Revised: "Revised",
  })[status] ?? status;

export const jobStatusLabel = (status: string) =>
  ({
    "Pending Agreement": "Pending Agreement",
    Authorized: "Authorized",
    "Receiving Documentation": "Receiving Documentation",
    "In Process": "In Process",
    "Ready for Delivery": "Ready for Delivery",
    "Delivered – Pending Customer Acceptance": "Awaiting Customer Acceptance",
    Completed: "Completed",
    Cancelled: "Cancelled",
    "Issue / Review": "Issue / Review",
  })[status] ?? status;

export const workStageLabel = (stage: string) =>
  ({
    "Not Started": "Not Started",
    "Receiving Evidence": "Receiving Evidence",
    Preparing: "Preparation",
    Engraving: "Engraving",
    "Final Evidence": "Engraving",
    "Final Details": "Final Details",
    "Delivery In Progress": "Delivery In Progress",
    "Cancellation Requested / Production Hold": "Cancellation Requested / Production Hold",
    "Awaiting Delivery Acceptance": "Awaiting Delivery Acceptance",
    "Issue Review": "Issue Review",
    Payment: "Payment Pending",
    "Payment Verification": "Payment Verification",
    Closed: "Completed",
  })[stage] ?? stage;

export const paymentStatusLabel = (status: string) =>
  ({
    "Pending Verification": "Pending Verification",
    Confirmed: "Confirmed",
    Rejected: "Rejected",
    Cancelled: "Cancelled",
  })[status] ?? status;

export const extensionStatusLabel = (status: string) =>
  ({
    Requested: "Requested",
    Draft: "Draft",
    Sent: "Sent",
    Approved: "Approved",
    Completed: "Completed",
    Cancelled: "Cancelled",
  })[status] ?? status;
