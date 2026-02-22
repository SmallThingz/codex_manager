/// <reference types="vite/client" />

interface Window {
  __CM_BOOTSTRAP_STATE__?: string;
  cm_rpc?: (requestJson: string) => Promise<string> | string;
}
