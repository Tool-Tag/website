import { requirePermission } from "@/lib/domain/context";
import { can } from "@/lib/auth/permissions";
import { Heading, FinanceTabs } from "@/components/ui";
import { FinanceRefundsList } from "@/features/finance-refunds-list";
import type {FinanceSearch} from "@/lib/domain/finance-list";
export const dynamic = "force-dynamic";
export default async function Page({searchParams}:{searchParams:Promise<FinanceSearch>}) {
 const {access}=await requirePermission("payments.refund","payments.view");
 return <FinanceRefundsList search={await searchParams} header={<><Heading title="Refunds" subtitle="Execute approved refunds manually and record payment proof."/><FinanceTabs includeGeneral={can(access,"payments.view")}/></>}/>;
}
