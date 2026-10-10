import type { Metadata } from "next";
import { GetTaggedModalContent } from "@/components/get-tagged-modal-content";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Get Tagged | ToolTag",
  robots: { index: false, follow: false },
};

export default function GetTaggedModalPage() {
  return <GetTaggedModalContent />;
}
