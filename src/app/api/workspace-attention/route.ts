import { NextResponse } from "next/server";
import { context } from "@/lib/domain/context";
import { workspaceAttention } from "@/lib/domain/workspace-attention";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const ctx = await context();
    const attention = await workspaceAttention(ctx.db, ctx.unit);

    return NextResponse.json(attention, {
      headers: {
        "Cache-Control": "no-store, max-age=0",
      },
    });
  } catch {
    return NextResponse.json(
      { error: "Unable to load workspace attention." },
      {
        status: 401,
        headers: {
          "Cache-Control": "no-store, max-age=0",
        },
      },
    );
  }
}
