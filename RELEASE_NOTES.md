Codex Quota Menubar is a native macOS menu bar plugin for CPA.

0.6.0 adds `allowUnauthenticatedRequests` (boolean, default `false`). Enable it in plugin configuration to accept all proxy API requests without checking credentials, including Codex OAuth tokens, for a CPA instance bound to localhost. Management API authentication remains separate. Turning the option off or disabling the plugin restores normal authentication; toggling only this option preserves the menu bar process. Quitting the menu bar alone does not disable bypass.

Install and update through this project's third-party CPA store source. Add the following URL under **Plugins → Settings → Additional store sources**:

```text
https://raw.githubusercontent.com/RoyalXC/cpa-plugin-codex-quota-menubar/main/registry.json
```

The plugin is macOS-only and is distributed exclusively through this third-party store source. Official-store publication is no longer planned.

- Shows remaining five-hour and weekly Codex quotas when provided by the account, including reset times.
- Bundles the precompiled menu bar application inside the plugin; installation needs no Python, Node, Xcode, administrator access, or additional helper download.
- Supports Apple Silicon and Intel CPA core processes, account selection, manual refresh, and CPA usage event updates.
- Deploys the helper to a private per-user version directory and uses a versioned readiness handshake. Includes quiesce and rollback-compatible lifecycle handling.

Builds target macOS 13 or newer. Platform validation and signing details are recorded in the build metadata and README. The initial release uses ad-hoc signatures and is not Apple-notarized.

CPA's plugin switch must be enabled, and valid Codex OAuth credentials must already be available in CPA. The menu bar displays the selected or latest eligible Codex OAuth account, rather than the quota of third-party API-key models.
