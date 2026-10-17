import {FinanceListFrame} from "@/components/finance-list-frame";
import { requirePermission } from "@/lib/domain/context";
import { can } from "@/lib/auth/permissions";
import { Heading, FinanceTabs } from "@/components/ui";
import { RefundsPanel } from "@/features/refunds";
export const dynamic = "force-dynamic";
export default async function Page() { const { access } = await requirePermission("payments.refund", "payments.view"); return <FinanceListFrame header={<><Heading title="Refunds" subtitle="Execute approved refunds manually and record payment proof."/><FinanceTabs includeGeneral={can(access, "payments.view")}/></>}><RefundsPanel view="execution" /></FinanceListFrame>; }
