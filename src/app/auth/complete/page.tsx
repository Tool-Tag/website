import type {Metadata} from 'next';
import {CompleteStaffAuth} from './session-completion';
export const metadata:Metadata={title:'Complete your ToolTag invitation',robots:{index:false,follow:false},referrer:'no-referrer'};
export default function CompleteInvitation(){return <main className="auth"><p className="eyebrow">TOOLTAG WORKSPACE</p><h1>Finish setting up your access</h1><CompleteStaffAuth/></main>;}
