/** Named controls shadow HTMLFormElement properties (notably <input name="id">).
 * Attribute access preserves the real ID used by external submit buttons. */
export function modalFormTarget(form: Pick<HTMLFormElement,"getAttribute"|"setAttribute">, fallback: string): string {
 const existing=form.getAttribute("id");
 if(existing)return existing;
 form.setAttribute("id",fallback);
 return fallback;
}
