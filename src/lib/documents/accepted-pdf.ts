import { PDFDocument, StandardFonts, rgb, type PDFFont } from "pdf-lib";
import type { QuoteItem } from "@/lib/domain/quote-items";
import { itemDetails, itemSubtotal } from "@/lib/domain/quote-summary";
import { money } from "@/lib/domain/money";
export type AcceptedSnapshot = {
  acceptance_folio: string; customer_name: string; customer_email: string;
  customer_phone: string; company: { name?: string; email?: string; phone?: string; address?: string };
  quote_code: string; quote_revision: number; job_code: string; sale_code?: string;
  quote_id: string; job_id: string; sale_id?: string; quote_accepted_at: string;
  agreement_accepted_at: string; agreement: { title: string; version: number; text: string };
  items: QuoteItem[]; total: string; notes?: string;
  confirmations: { quote: boolean; agreement: boolean };
  identity: { brand: string; legal: string };
  quote_recipient_selection: { email: string; kind: string };
};
export type AcceptedDocument = {
  id: string; acceptance_folio: string; file_name: string;
  acceptance_snapshot_sha256: string; canonical_snapshot: string;
  snapshot: AcceptedSnapshot; claim?: string;
};
export async function generateAcceptedPdf(document: AcceptedDocument) {
  const s = document.snapshot;
  if (!s.confirmations.quote || !s.confirmations.agreement || !s.agreement.text) throw new Error("Invalid acceptance snapshot");
  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  pdf.setTitle(`${s.acceptance_folio} - Accepted Quote and Agreement`);
  pdf.setAuthor(s.identity.brand);
  pdf.setCreationDate(new Date(s.agreement_accepted_at));
  pdf.setModificationDate(new Date(s.agreement_accepted_at));
  let page = pdf.addPage([612, 792]);
  let y = 730;
  const blue = rgb(0.16, 0.36, 0.8), ink = rgb(0.09, 0.11, 0.15);
  function nextPage() { page = pdf.addPage([612, 792]); y = 730; }
  function line(text: string, size: number, font: PDFFont) {
    if (y < 65) nextPage();
    page.drawText(text, { x: 48, y, font, size, color: ink });
    y -= size * 1.45;
  }
  // Character-aware wrapping also handles long URLs and full fingerprints.
  // Unsupported glyphs fail explicitly rather than silently changing accepted text.
  function paragraph(text: string, size = 10, font = regular) {
    for (const raw of String(text).replace(/\r\n/g, "\n").split("\n")) {
      let buffer = "";
      for (const char of raw.replace(/\t/g, "    ")) {
        if (font.widthOfTextAtSize(buffer + char, size) > 516) {
          const split = buffer.lastIndexOf(" ");
          if (split > 0) { line(buffer.slice(0, split), size, font); buffer = buffer.slice(split + 1); }
          else { line(buffer, size, font); buffer = ""; }
        }
        buffer += char;
      }
      line(buffer, size, font);
    }
    y -= 6;
  }
  function section(title: string) {
    if (y < 120) nextPage();
    y -= 12;
    page.drawLine({ start: { x: 48, y: y + 8 }, end: { x: 564, y: y + 8 }, thickness: 1, color: blue });
    paragraph(title, 12, bold);
  }
  paragraph(s.identity.brand, 26, bold);
  paragraph("ACCEPTED QUOTE + AGREEMENT", 13, bold);
  paragraph(`Agreement Folio: ${s.acceptance_folio}`, 12, bold);
  paragraph(`Customer: ${s.customer_name}\n${s.company?.name ? `Company: ${s.company.name}\n` : ""}Quote recipient: ${s.customer_email} (${s.quote_recipient_selection.kind})\nPhone: ${s.customer_phone}`);
  if (s.company?.name) paragraph([s.company.address, s.company.email, s.company.phone].filter(Boolean).join("\n"));
  paragraph(`Quote: ${s.quote_code} / revision ${s.quote_revision}\nJob: ${s.job_code}\nSale: ${s.sale_code || s.sale_id || "Not available"}\nAgreement accepted: ${s.agreement_accepted_at}\nQuote accepted: ${s.quote_accepted_at}`);
  section("ACCEPTED QUOTE / SCOPE");
  for (const item of s.items) {
    if (y < 130) nextPage();
    paragraph(item.article, 11, bold);
    paragraph(`${item.quantity} piece(s) x ${money(String(item.unit_price))} = ${itemSubtotal(item)}`);
    paragraph(itemDetails(item).join("\n"));
  }
  paragraph(`Agreed total: ${money(String(s.total))}`, 13, bold);
  if (s.notes) paragraph(`Quote notes: ${s.notes}`);
  section("CUSTOMER AGREEMENT & CUSTOM ENGRAVING TERMS");
  paragraph(`${s.agreement.title} / version ${s.agreement.version}`, 11, bold);
  paragraph(s.agreement.text);
  section("ELECTRONIC ACCEPTANCE");
  paragraph("The customer confirmed both acknowledgments:\nI have reviewed and approve the Quote details.\nI have read and agree to the ToolTag Customer Agreement & Custom Engraving Terms.");
  paragraph(`Accepted by: ${s.customer_name}\nAccepted: ${s.agreement_accepted_at}`);
  section("DOCUMENT VERIFICATION");
  paragraph(`Agreement Folio: ${s.acceptance_folio}\nQuote: ${s.quote_code} / revision ${s.quote_revision}\nJob: ${s.job_code}\nAgreement Version: ${s.agreement.version}\nAccepted: ${s.agreement_accepted_at}`);
  paragraph(`Canonical snapshot SHA-256:\n${document.acceptance_snapshot_sha256}`, 9);
  paragraph(s.identity.legal, 9);
  const pages = pdf.getPages();
  pages.forEach((p, i) => p.drawText(`${s.acceptance_folio} | ${i + 1} / ${pages.length}`, { x: 48, y: 32, size: 8, font: regular, color: ink }));
  return Buffer.from(await pdf.save());
}
