"use client";
import {Children,createContext,cloneElement,isValidElement,useContext,useId,useLayoutEffect,useRef,useState,type ReactNode,type ReactElement} from 'react';
import {createPortal} from 'react-dom';
const FooterContext=createContext<HTMLElement|null>(null);
/** Layout only: existing event handlers, form actions and contexts remain intact. */
export function HexModalFrame({children}:{children:ReactNode}){
 const [footer,setFooter]=useState<HTMLElement|null>(null);const nodes=Children.toArray(children);let header:ReactNode=null;
 const index=nodes.findIndex(node=>isValidElement(node)&&typeof node.type==='string'&&(node.type==='header'||/^h[123]$/.test(node.type)||(node.type==='div'&&Children.toArray((node.props as {children?:ReactNode}).children).some(n=>isValidElement(n)&&typeof n.type==='string'&&/^h[123]$/.test(n.type)))));
 if(index>=0){header=nodes[index];nodes.splice(index,1);}
 return <FooterContext.Provider value={footer}><div className="hex-modal-frame">{header&&<div className="hex-modal-header">{header}</div>}<div className="hex-modal-body">{nodes.map(node=>isValidElement(node)&&node.type==='form'?cloneElement(node as ReactElement<{children?:ReactNode;className?:string}>,{className:`${(node.props as {className?:string}).className??''} hex-modal-form`},<HexModalFrame>{(node.props as {children?:ReactNode}).children}</HexModalFrame>):node)}</div><footer className="hex-modal-footer" ref={setFooter}/></div></FooterContext.Provider>;
}
export function ModalActions({children,className='actions'}:{children:ReactNode;className?:string}){
 const footer=useContext(FooterContext),anchor=useRef<HTMLSpanElement>(null),id=useId();const [formId,setFormId]=useState<string>();
 useLayoutEffect(()=>{const form=anchor.current?.closest('form');if(form){if(!form.id)form.id=`hex-form-${id}`;setFormId(form.id);}},[id]);
 const associate=(node:ReactNode):ReactNode=>{if(!isValidElement(node))return node;const el=node as ReactElement<{children?:ReactNode;form?:string}>;if(el.type==='button'||el.type==='input')return cloneElement(el,{form:el.props.form??formId});if(typeof el.type==='string'&&el.props.children)return cloneElement(el,{},Children.map(el.props.children,associate));return el;};
 const content=<div className={className}>{Children.map(children,associate)}</div>;
 return <><span ref={anchor} hidden/>{footer?createPortal(content,footer):content}</>;
}
