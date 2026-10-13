type Env=Record<string,string|undefined>;
export class StripeRouteRefundTransport{
 constructor(private readonly request:typeof fetch=fetch,private readonly env:Env=process.env){}
 configured(){const key=this.env.STRIPE_SECRET_KEY??"";return this.env.TOOLTAG_REFUND_MODE==='test'?this.env.VERCEL_ENV!=='production'&&key.startsWith('sk_test_'):this.env.TOOLTAG_REFUND_MODE==='live'&&this.env.VERCEL_ENV==='production'&&key.startsWith('sk_live_');}
 private async call(path:string,init:RequestInit={}){
 const response=await this.request(`https://api.stripe.com/v1/${path}`,{...init,signal:AbortSignal.timeout(10000),headers:{Authorization:`Bearer ${this.env.STRIPE_SECRET_KEY}`,...init.headers}});
 if(!response.ok)throw Error('Refund provider rejected the request');return response.json();
 }
 async refund(input:{id:string;offset:number;amount:number;session:string}):Promise<{id:string;status:string}>{
 if(!this.configured())throw Error('Automatic refund transport is not enabled');
 const session=await this.call(`checkout/sessions/${encodeURIComponent(input.session)}`);const intent=typeof session.payment_intent==='string'?session.payment_intent:session.payment_intent?.id;
 if(!intent||session.payment_status!=='paid')throw Error('Original paid payment intent unavailable');
 const validated=(result:{id:string;status:string;amount:number;currency:string;payment_intent:string;metadata?:{route_part?:string}})=>{if(!result.id||result.amount!==Math.round(input.amount*100)||result.currency!=='usd'||result.payment_intent!==intent)throw Error('Refund confirmation does not match the original payment and amount');return {id:result.id,status:result.status};};
 const key=`route-refund:${input.id}:${input.offset.toFixed(2)}`;
 // Look up the durable part key before POST, including after Stripe's idempotency retention window.
 let cursor='';
 for(let page=0;page<10;page++){
 const params=new URLSearchParams({payment_intent:intent,limit:'100'});if(cursor)params.set('starting_after',cursor);
 const refunds=await this.call(`refunds?${params}`);
 const existing=refunds.data?.find((r:{metadata?:{route_part?:string}})=>r.metadata?.route_part===key);if(existing)return validated(existing);
 if(!refunds.has_more)break;if(page===9)throw Error('Refund history needs review before retry');cursor=refunds.data.at(-1)?.id;if(!cursor)throw Error('Incomplete refund history');
 }
 const body=new URLSearchParams({payment_intent:intent,amount:String(Math.round(input.amount*100)),"metadata[route_part]":key});
 const result=await this.call('refunds',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded','Idempotency-Key':key},body});
 return validated(result);
 }
}
// Kept for compatibility: this worker is intentionally inert, even with provider keys.
export async function processRouteRefunds(){return {enabled:false,processed:0};}
