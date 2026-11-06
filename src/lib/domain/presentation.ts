/** Presentation-only filtering. Records and configuration remain untouched. */
export function isPresentationTest(value: unknown): boolean {
 return typeof value === "string" && /TEST_VISUAL_ONLY_NO_SEND|TEST-20261011-MANUAL/i.test(value);
}
export function fiscalQuarterStarts(month: number): string[] {
 return Array.from({length:4},(_,index)=>`${String(((month-1+index*3)%12)+1).padStart(2,"0")}-01`);
}
export function fiscalStartMonth(starts: string[]): number|null {
 const month=Number(starts[0]?.slice(0,2));
 return month>=1&&month<=12&&JSON.stringify(fiscalQuarterStarts(month))===JSON.stringify(starts)?month:null;
}
