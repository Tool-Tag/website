"use client";
import { createContext, useContext } from "react";
import { canAny, canMutate, type Access } from "@/lib/auth/permissions";
const PermissionContext = createContext<Access>({ owner: false, blocks: [] });
export function PermissionProvider({access, children}: {access: Access; children: React.ReactNode}) {
  return <PermissionContext.Provider value={access}>{children}</PermissionContext.Provider>;
}
export function useAccess() { return useContext(PermissionContext); }
export function PermissionGate({blocks, owner = false, children}: {blocks?: string[]; owner?: boolean; children: React.ReactNode}) {
  const access = useAccess();
  return (owner ? access.owner : canAny(access, blocks ?? [])) ? children : null;
}
export function useActionPermission(operation: string) { return canMutate(useAccess(), operation); }
