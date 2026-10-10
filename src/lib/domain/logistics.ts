export type LogisticsOptionCode =
  | "pickup_only"
  | "pickup_delivery"
  | "dropoff_pickup"
  | "dropoff_delivery";

export type LogisticsOption = {
  code: LogisticsOptionCode;
  name: string;
  description: string;
  fee: number;
  pickup: boolean;
  delivery: boolean;
};

export const LOGISTICS_OPTIONS: readonly LogisticsOption[] = [
  {
    code: "pickup_only",
    name: "Pickup Only",
    description:
      "We pick up your items from your address. You pick up the finished work at our shop.",
    fee: 9.99,
    pickup: true,
    delivery: false,
  },
  {
    code: "pickup_delivery",
    name: "Pickup & Delivery",
    description:
      "We pick up your items and deliver the finished work back to you.",
    fee: 19.99,
    pickup: true,
    delivery: true,
  },
  {
    code: "dropoff_pickup",
    name: "Drop-off & Pickup",
    description:
      "You drop off your items at our shop and pick up the finished work there.",
    fee: 0,
    pickup: false,
    delivery: false,
  },
  {
    code: "dropoff_delivery",
    name: "Drop-off + Delivery",
    description:
      "You drop off your items at our shop. We deliver the finished work back to you.",
    fee: 9.99,
    pickup: false,
    delivery: true,
  },
] as const;

export function logisticsOption(
  code: string | null | undefined,
): LogisticsOption | undefined {
  return LOGISTICS_OPTIONS.find((option) => option.code === code);
}

export function logisticsFee(code: string | null | undefined) {
  return logisticsOption(code)?.fee ?? 0;
}

export function logisticsRequiresPickup(code: string | null | undefined) {
  return Boolean(logisticsOption(code)?.pickup);
}

export function logisticsRequiresDelivery(code: string | null | undefined) {
  return Boolean(logisticsOption(code)?.delivery);
}
