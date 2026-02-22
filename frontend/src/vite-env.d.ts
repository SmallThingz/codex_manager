/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SHOW_WINDOW_BAR?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

interface Window {
  __CM_BOOTSTRAP_STATE__?: string;
  cm_rpc?: (requestJson: string) => Promise<string> | string;
  cm_window_minimize?: () => Promise<void> | void;
  cm_window_toggle_fullscreen?: () => Promise<boolean> | boolean;
  cm_window_is_fullscreen?: () => Promise<boolean> | boolean;
  cm_window_toggle_maximize?: () => Promise<boolean> | boolean;
  cm_window_is_maximized?: () => Promise<boolean> | boolean;
  cm_window_close?: () => Promise<void> | void;
  cm_window_start_drag?: () => Promise<void> | void;
  webui?: {
    call?: (fn: string, ...args: unknown[]) => Promise<string> | string;
  };
}
