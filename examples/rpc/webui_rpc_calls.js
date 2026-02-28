// Minimal examples for the `window.webuiRpc.cm_rpc` bridge.
// Requests are plain objects; responses are plain JSON values.

async function rpc(op, payload = {}) {
  if (!window.webuiRpc || typeof window.webuiRpc.cm_rpc !== "function") {
    throw new Error("webui bridge unavailable");
  }

  const response = await window.webuiRpc.cm_rpc({ op, ...payload });

  if (
    response &&
    typeof response === "object" &&
    !Array.isArray(response) &&
    Object.keys(response).length === 1 &&
    typeof response.error === "string"
  ) {
    throw new Error(response.error);
  }

  return response;
}

export async function refreshOneAccount(accountId) {
  return rpc("invoke:refresh_account_usage", { accountId });
}

export async function moveToFrozen(accountId) {
  await rpc("invoke:move_account", {
    accountId,
    targetBucket: "frozen",
    targetIndex: Number.MAX_SAFE_INTEGER,
    switchAwayFromMoved: true,
  });
}

export async function setUiPreferences() {
  await rpc("invoke:update_ui_preferences", {
    autoRefreshActiveEnabled: true,
    autoRefreshActiveIntervalSec: 300,
    usageRefreshDisplayMode: "remaining",
  });
}
