"use client";
import type {ReactNode} from 'react';
import {ActionModal} from './action-modal';
import {HexIcon} from './hex-icon';
/** Real forms retain ActionModal's existing close/refresh callback after saving. */
export function SettingsSection({title='Workspace settings',children,summary='Current values and editable controls'}:{title?:string;children:ReactNode;summary?:string}){return <section className="hex-settings-section"><ActionModal title={title} label={title} kicker="System · Settings" triggerClassName="hex-settings-row" trigger={<><HexIcon name="settings"/><span><strong>{title}</strong><small>{summary}</small></span><span className="settings-edit-label">Edit</span></>}>{children}</ActionModal></section>;}
