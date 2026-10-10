"use client";
import type {Point} from "./route-estimate";
let current:{point:Point;at:number}|null=null;
export function rememberDriverLocation(point:Point){current={point,at:Date.now()};}
export function driverLocation():Point|null{return current&&Date.now()-current.at<90000?current.point:null;}
