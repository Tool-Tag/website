"use client";
import {useState} from 'react';
/** Presentation only: collapse the desktop navigation without changing access or routes. */
export function WorkspaceSidebarToggle(){const [collapsed,setCollapsed]=useState(false);return <button type="button" className="hex-sidebar-toggle secondary" aria-label={collapsed?'Show navigation':'Hide navigation'} aria-expanded={!collapsed} onClick={event=>{const next=!collapsed;event.currentTarget.closest('.shell')?.setAttribute('data-nav-collapsed',String(next));setCollapsed(next);}}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true"><path d="M3 6h18M3 12h13M3 18h18"/></svg></button>;}
