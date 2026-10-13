import { Heading, FinanceTabs } from "@/components/ui";
import { SmsCosts } from "@/features/sms-costs";
export const dynamic = "force-dynamic";
export default function Page() { return <><Heading title="SMS cost accounting"/><FinanceTabs /><SmsCosts /></>; }
