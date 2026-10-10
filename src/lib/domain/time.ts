export const TOOLTAG_TIMEZONE = "America/Denver";
export function denverDateTime(value?: string | null) {
  return value ? new Date(value).toLocaleString("en-US", { timeZone: TOOLTAG_TIMEZONE, timeZoneName: "short" }) : "—";
}
export function denverTime(value: string) {
  return new Date(value).toLocaleTimeString("en-US", {timeZone: TOOLTAG_TIMEZONE, hour: "numeric", minute: "2-digit"});
}
