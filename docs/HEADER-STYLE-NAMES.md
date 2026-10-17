# Reusable redesign style names

Gold and Blue Electric are general interaction skins for use anywhere in the redesign. Both are defined in `src/app/globals.css`, independently of `WorkspaceUserMenu` or any dropdown selector. The header redesign preview applies Gold to utility links and Blue Electric to Dashboard Needs Attention links.

| Name | Opt-in class | Hover/focus text |
| --- | --- | --- |
| Gold | `.gold` (alias `.menu-link-gold`) | `var(--gold)` — `#d9b366` |
| Blue Electric | `.blue-electric` (alias `.menu-link-blue-electric`) | `var(--blue)` — `#3177ff` |

Both skins provide 6px corner radius and hover/keyboard-focus styling: the specified text color, deep-black `var(--bg)` (`#090b0e`) background and a 2px `var(--line)` outline. They can be composed with classes for buttons, links, cards and other interactive controls anywhere in the app.

The host component controls display, spacing, dimensions and text wrapping. Use native interactive elements for keyboard access; these classes do not add behavior or semantics. If a host has a more specific interaction selector, compose its CSS to preserve the selected skin.

The original `.workspace-user-dropdown a` remains unchanged. Its gold appearance inspired these skins, but neither depends on it. Global link colors remain unchanged. The menu-link aliases are general skins too; they do not impose dropdown layout.


## Main Tabs

Use `.main-tab-list` with `.main-tab` controls. Matches the Jobs tabs: the active tab has a gold underline. Select with `.active`, `aria-selected="true"` (tab buttons) or `aria-current="page"` (navigation links). These styles are available for reuse; existing tab groups are not changed in this base-style block.

## Folder Tabs

Use `.folder-tab-list` with `.folder-tab` controls. Folder-shaped upper corners; the top line is blue when active and gray when inactive. Same active-state selectors as Main Tabs. Hosts own selection logic, correct ARIA semantics and keyboard behavior.

## Back

The workspace BackNavigation control displays “← Back” and uses browser history to return to the actual previous page, including its query string. A directly opened tab with no previous history falls back to `/app`. It is hidden on the workspace root, as before.
