/// <reference types="vite/client" />

interface Window {
  __CM_BOOTSTRAP_STATE__?: string;
  webuiRpc?: {
    cm_rpc?: (requestJson: string) => Promise<unknown> | unknown;
  };
}
