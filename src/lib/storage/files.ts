export const TOOLTAG_FILES_BUCKET = "tooltag-files";

export function storageObjectName(value: string) {
  const cleaned = value
    .replace(/[\\/\0\r\n\t]/g, "_")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 180);
  return cleaned || "file";
}

export function storageStatusLabel(
  status?: string | null,
  provider?: string | null,
) {
  if (provider === "legacy_drive") return "Legacy Drive reference";
  switch (status) {
    case "stored":
      return "Stored";
    case "failed":
      return "Upload failed";
    case "pending":
      return "Uploading";
    case "not_applicable":
      return "Record only";
    case "Uploaded":
      return provider === "legacy_drive" ? "Legacy Drive reference" : "Stored";
    case "Pending Drive Upload":
      return "Historical metadata only";
    default:
      return status || "Storage status unavailable";
  }
}

export function legacyDriveUrl(fileId: string) {
  return `https://drive.google.com/open?id=${encodeURIComponent(fileId)}`;
}

export function inlineDisposition(fileName: string) {
  return `inline; filename*=UTF-8''${encodeURIComponent(fileName)}`;
}
