/// <reference types="vite/client" />

interface Window {
  __CM_BOOTSTRAP_STATE__?: string;
  webuiRpc?: {
    cm_rpc?: (request: Record<string, unknown>) => Promise<unknown> | unknown;
  };
}
