import { z } from "zod";

export const PICKUP_FEE = 19.99;

export const PICKUP_REQUEST_DISCLAIMER = [
  "ToolTag Pickup is normally requested for Saturdays between 8:00 AM and 12:00 PM, subject to route capacity.",
  "Pickup & Delivery is $19.99 total: $9.99 for Pickup and $9.99 for Delivery.",
  "The logistics fee must be paid and confirmed before the requested Pickup becomes confirmed.",
  "Delivery is coordinated after the engraving work is finished; no delivery day or time is selected at the request stage.",
].join("\n\n");

const shortText = z.string().trim().max(160);
const phone = z
  .string()
  .trim()
  .max(40)
  .refine((value) => {
    const digits = value.replace(/\D/g, "");
    return digits.length >= 7 && digits.length <= 15;
  }, "Enter a valid phone number.");

const optionalEmail = z.union([z.literal(""), z.string().email().max(254)]);

const markSchema = z
  .object({
    type: z.enum(["Text", "Image / Logo"]),
    location: shortText.min(1, "Add an engraving location."),
    text: z.string().trim().max(1000),
    description: z.string().trim().max(1000),
    url: z
      .string()
      .trim()
      .max(2000)
      .refine(
        (value) =>
          !value || (/^https?:\/\//i.test(value) && URL.canParse(value)),
        "Use an http or https link.",
      ),
    paint_fill: z.boolean(),
    color: shortText,
  })
  .superRefine((mark, ctx) => {
    if (mark.type === "Text" && !mark.text) {
      ctx.addIssue({
        code: "custom",
        path: ["text"],
        message: "Enter the text to engrave.",
      });
    }
    if (mark.type === "Image / Logo" && !mark.description) {
      ctx.addIssue({
        code: "custom",
        path: ["description"],
        message: "Describe your logo or image.",
      });
    }
    if (mark.paint_fill && !mark.color) {
      ctx.addIssue({
        code: "custom",
        path: ["color"],
        message: 'Enter a color or "Not sure".',
      });
    }
  });

const size = z
  .string()
  .trim()
  .max(12)
  .refine(
    (value) =>
      !value ||
      (/^\d+(\.\d{1,2})?$/.test(value) &&
        Number(value) > 0 &&
        Number(value) <= 10000),
    "Enter a positive size in millimeters (up to 10,000).",
  );

export const getTaggedRequestSchema = z
  .object({
    contact: z.object({
      name: shortText.min(2, "Enter your full name."),
      email: z.string().email().max(254).transform((value) => value.toLowerCase()),
      phone,
      company_name: shortText,
      company_email: optionalEmail.transform((value) => value.toLowerCase()),
      company_phone: z.union([z.literal(""), phone]),
    }),
    service: z.object({
      method: z.enum(["Drop-off", "Pickup", "Not sure"]),
      address: z.string().trim().max(500),
    }),
    items: z
      .array(
        z.object({
          article: shortText.min(1, "Describe the item."),
          brand: shortText.min(1, 'Enter a brand or "Not sure".'),
          model: shortText,
          quantity: z.number().int().min(1).max(1000),
          width_mm: size,
          height_mm: size,
          marks: z.array(markSchema).min(1, "Add an engraving.").max(20),
          notes: z.string().trim().max(2000),
        }),
      )
      .min(1, "Add at least one item.")
      .max(20),
    notes: z.string().trim().max(2000),
  })
  .superRefine((request, ctx) => {
    if (request.service.method === "Pickup" && !request.service.address) {
      ctx.addIssue({
        code: "custom",
        path: ["service", "address"],
        message: "Enter the Pickup address.",
      });
    }
  });

export type GetTaggedRequest = z.infer<typeof getTaggedRequestSchema>;
export type GetTaggedItem = GetTaggedRequest["items"][number];
export type GetTaggedMark = GetTaggedItem["marks"][number];

export function emptyMark(): GetTaggedMark {
  return {
    type: "Text",
    location: "",
    text: "",
    description: "",
    url: "",
    paint_fill: false,
    color: "",
  };
}

export function emptyItem(): GetTaggedItem {
  return {
    article: "",
    brand: "",
    model: "",
    quantity: 1,
    width_mm: "",
    height_mm: "",
    notes: "",
    marks: [emptyMark()],
  };
}

export function emptyGetTaggedRequest(): GetTaggedRequest {
  return {
    contact: {
      name: "",
      email: "",
      phone: "",
      company_name: "",
      company_email: "",
      company_phone: "",
    },
    service: { method: "Not sure", address: "" },
    items: [emptyItem()],
    notes: "",
  };
}

export function getTaggedQuoteItems(request: GetTaggedRequest) {
  return request.items.map((item) => {
    const marks = item.marks.map((mark) => ({
      type: mark.type,
      location: mark.location,
      text: mark.type === "Text" ? mark.text : "",
      description: mark.description,
      url: mark.url,
      paint_fill: mark.paint_fill,
      paint_details: {
        mode: "single",
        color: mark.paint_fill ? mark.color : "",
        instructions: "",
      },
    }));

    const hasImage = marks.some((mark) => mark.type === "Image / Logo");
    const engravingText = marks
      .map((mark) =>
        mark.type === "Text"
          ? mark.text
          : `Image / Logo: ${mark.description || "Customer artwork"}`,
      )
      .filter(Boolean)
      .join("\n");

    return {
      article: [item.article, item.brand, item.model].filter(Boolean).join(" · "),
      quantity: item.quantity,
      engraving_type: hasImage ? "Image / Logo" : "Text",
      engraving_text: engravingText,
      width_mm: item.width_mm,
      height_mm: item.height_mm,
      paint_fill: false,
      colors: 0,
      unit_price: "0.00",
      notes: item.notes,
      marks,
    };
  });
}
