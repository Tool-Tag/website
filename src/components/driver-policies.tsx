"use client";
import {useState} from "react";
import Link from "next/link";
import {BackNavigation} from "./back-navigation";
import {DRIVER_POLICIES,DRIVER_POLICIES_REVISION} from "@/lib/domain/driver-policies";
export function DriverPolicies(){
 const [language,setLanguage]=useState<"en"|"es">("en");
 return <main className="public policy-page" lang={language}><BackNavigation fallback="/"/>
 <div className="actions"><button type="button" aria-pressed={language==="en"} onClick={()=>setLanguage("en")}>English</button><button type="button" aria-pressed={language==="es"} onClick={()=>setLanguage("es")}>Español</button></div>
 <h1>{language==="en"?"Pick up & Delivery — Policies and Conditions":"Recolección y entrega — Políticas y condiciones"}</h1>
 <ol className="driver-policy-list">{DRIVER_POLICIES.map((policy,index)=><li key={index}><h2>{policy[language][0]}</h2><p>{policy[language][1]}</p></li>)}</ol>
 <p>Agreement Rev: {DRIVER_POLICIES_REVISION}<br/>ToolTag - Bandits of the Framing LLC</p>
 <Link href="/pick-return/my-loss-agreements">{language==="en"?"My driver loss agreements (sign in required)":"Mis acuerdos de pérdida (requiere iniciar sesión)"}</Link>
 </main>;
}
