import type {CSSProperties} from 'react';
const paths:Record<string,string>={
 dashboard:'M3 3h7v7H3zM14 3h7v4h-7zM14 11h7v10h-7zM3 14h7v7H3z',
 request:'M12 3l7 4v5c0 4-3 7-7 9-4-2-7-5-7-9V7z',
 quote:'M6 3h12v18l-3-2-3 2-3-2-3 2zM9 8h6M9 12h6',
 job:'M3 7l9-5 9 5v10l-9 5-9-5zM3 7l9 5 9-5M12 12v10',
 route:'M3 7h11v10H3zM14 10h4l3 4v3h-7zM5 20h4M16 20h4',
 lost:'M12 8v5M12 17h.01M10 3L2 19h20L14 3z',
 cancel:'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM8 8l8 8M16 8l-8 8',
 mail:'M3 5h18v14H3zM3 6l9 7 9-7',
 support:'M21 12a8 8 0 0 1-8 8H4l-2 2V12a9 9 0 0 1 9-9h2a8 8 0 0 1 8 9z',
 finance:'M12 2v20M17 6c-1-1-3-2-5-2-6 0-7 7 0 8s6 8 0 8c-2 0-4-1-5-2',
 customer:'M8 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM1 22v-3a7 7 0 0 1 14 0v3M17 4a4 4 0 0 1 0 8M20 22v-3a7 7 0 0 0-3-6',
 equipment:'M3 8h18v13H3zM8 8V4h8v4M9 14h6',
 settings:'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2',
 clock:'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l4 2',
 globe:'M3 12h18M12 3c6 5 6 13 0 18-6-5-6-13 0-18zM12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z',
};
export function HexIcon({name='job',style}:{name?:string;style?:CSSProperties}){return <span className="hex-icon" style={style} aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="miter"><path d={paths[name]??paths.job}/></svg></span>;}
export function WorkspaceBrand({subtitle='Workspace'}:{subtitle?:string}={}){return <span className="hex-workspace-brand"><span className="hex-brand-mark" aria-hidden="true">T</span><span><span className="hex-wordmark">Tool<em>Tag</em></span><small>{subtitle}</small></span></span>;}
