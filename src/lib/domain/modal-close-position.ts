export function modalClosePosition(rect:{top:number;right:number},viewportWidth:number,viewportHeight:number,size=36){
 const gap=6;
 if(rect.right+gap+size<=viewportWidth)return {top:Math.max(gap,Math.min(viewportHeight-size-gap,rect.top-size/2)),left:rect.right+gap,right:'auto'};
 // Wide panels use the exterior space above instead of clamping the X inside.
 return {top:Math.max(gap,rect.top-size-gap),left:Math.max(gap,Math.min(viewportWidth-size-gap,rect.right-size)),right:'auto'};
}
