"use client";
import type {ReactNode} from 'react';
import {ActionModal} from './action-modal';
import {HexIcon} from './hex-icon';
/** Real forms retain ActionModal's existing close/refresh callback after saving. */
export function SettingsSection({title='Workspace settings',children}:{title?:string;children:ReactNode}){return <section className="hex-settings-section"><ActionModal title={title} label={title} kicker="System · Settings" triggerClassName="hex-settings-row" trigger={<><HexIcon name="settings"/><span><strong>{title}</strong><small>Review and update configuration</small></span><span className="row-chevron" aria-hidden="true">›</span></>}>{children}</ActionModal></section>;}
