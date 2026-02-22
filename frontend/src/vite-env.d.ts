/// <reference types="vite/client" />

interface Window {
  __CM_BOOTSTRAP_STATE__?: string;
  cm_rpc?: (requestJson: string) => Promise<string> | string;
  cm_window_minimize?: () => Promise<void> | void;
  cm_window_toggle_fullscreen?: () => Promise<boolean> | boolean;
  cm_window_is_fullscreen?: () => Promise<boolean> | boolean;
  cm_window_close?: () => Promise<void> | void;
  webui?: {
    call?: (fn: string, ...args: unknown[]) => Promise<string> | string;
  };
}
