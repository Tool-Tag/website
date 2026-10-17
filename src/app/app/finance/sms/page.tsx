import { Heading, FinanceTabs } from "@/components/ui";
import {FinanceSmsList} from "@/features/finance-sms-list";
import type {FinanceSearch} from "@/lib/domain/finance-list";
export const dynamic = "force-dynamic";
export default async function Page({searchParams}:{searchParams:Promise<FinanceSearch>}) { return <FinanceSmsList search={await searchParams} header={<><Heading title="SMS cost accounting"/><FinanceTabs/></>}/>; }
