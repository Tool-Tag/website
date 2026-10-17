import {FinanceListFrame} from "@/components/finance-list-frame";
import { Heading, FinanceTabs } from "@/components/ui";
import { SmsCosts } from "@/features/sms-costs";
export const dynamic = "force-dynamic";
export default function Page() { return <FinanceListFrame header={<><Heading title="SMS cost accounting"/><FinanceTabs /></>}><SmsCosts /></FinanceListFrame>; }
