import {HextechEnhancements} from "@/components/hextech-enhancements";
import type { Metadata } from "next";
import "./globals.css";
import "../../public/hextech.css";
import "../../public/fonts/hextech-fonts.css";
import "../../public/hextech-reference.css";
import "../../public/hextech-structure.css";
import "../../public/hextech-workflow.css";
import "../../public/hextech-unified.css";
export const metadata: Metadata = {
  title: "ToolTag · Workspace",
  description: "ToolTag operations and shared finance",
  robots: { index: false, follow: false },
};
export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body><HextechEnhancements/>{children}</body>
    </html>
  );
}
