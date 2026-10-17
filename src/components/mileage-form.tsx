"use client";
import {Form} from "./form";
export function MileageForm({onSaved}:{onSaved?:(data:unknown)=>void}) {
 return <Form operation="mileage" back={onSaved?"":"/app/finance/expenses?view=mileage"} onSaved={onSaved} button="Save trip / mileage" fields={[
 {name:"date",label:"Date",type:"date",required:true},{name:"purpose",label:"Purpose",required:true},
 {name:"origin",label:"Origin",required:true},{name:"destination",label:"Destination",required:true},
 {name:"miles",label:"Miles",type:"number",required:true},{name:"notes",label:"Notes",type:"textarea"}
 ]}/>;
}
