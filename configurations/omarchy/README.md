# Omarchy app profiles

What `scripts/omarchy-apply.sh` keeps installed on the Omarchy machines.
Omarchy owns the desktop, the packages and the updates; these files only say
**which apps** a machine should carry, and the script hands whatever is missing
to Omarchy's own tools (`omarchy-pkg-add`, `omarchy-pkg-aur-add`,
`omarchy-install-*`, `omarchy-webapp-install`). Omarchy itself has no list of
user packages, so this is that list.

Additive only: deleting a line never uninstalls anything (use
`omarchy pkg drop <pkg>` / Remove > Web App).

## Layout

```
hosts/<hostname>.txt   one per machine: which profiles, plus any extra lines
hosts/default.txt      a machine with no host file (new VM, renamed host)
profiles/<name>.txt    app lines, grouped by purpose
```

The script picks `hosts/$(hostname).txt`. With no such file it uses
`hosts/default.txt` (only `base-cli`) and warns, and from the post-update hook
it also sends a desktop notification, so a renamed machine is noticed rather
than quietly getting less.

| Host | Machine | Profiles |
|------|---------|----------|
| `rouven-air-m2-omarchy` | MacBook Air M2, Omarchy side of the dual boot (aarch64). The macOS side is `rouven-air-m2`. | all six |
| `rouven-thinkpad-omarchy` | ThinkPad X1 (x86_64) | all six |

| Profile | For |
|---------|-----|
| `base-cli` | every machine, VMs included: Tailscale (the fleet reaches the config service over it) and the CLI tools from `modules/common.nix` Omarchy does not ship |
| `desktop` | a machine a person sits at: 1Password, browsers, Dropbox |
| `dev` | Ghostty, Zed, Cursor, Claude desktop, Herdr desktop app, Ollama |
| `comms` | Signal, Telegram, Element, Slack |
| `media` | Spotify, VLC |
| `web-apps` | the owner's web apps (Mac apps with no Linux build, plus `pwas.txt`) |

A new machine: add `hosts/<hostname>.txt` with the profiles it needs, then run
the script there. A VM usually wants only `base-cli` and `dev`.

## Line format

One entry per line, fields separated by `|`:

```
profile | <name>                               host files only: pull in profiles/<name>.txt
pkg     | <arch package>                       official repos or Omarchy's repo
aur     | <aur package>                        built by yay; not vetted by Arch
omarchy | <omarchy-install-* command [args]> | <package> or app:<launcher name>
        Omarchy's own installer (adds extensions, bar plugins, services);
        the third field is how we know it already ran.
webapp  | <launcher name> | <https url> [| <https icon url>]
        icon omitted = fetched from the site.
```

- Any app line can be limited to one CPU architecture: `pkg@x86_64`,
  `webapp@aarch64`. Apps with no aarch64 Linux build get a web-app stand-in on
  the M2 Air.
- Profiles cannot pull in other profiles. An app in two profiles is installed once.
- The whole list (host file plus its profiles) is validated before anything
  runs; one bad line installs nothing.
- Prefer `pkg` over `aur`: Omarchy's repo ships prebuilt, signed copies of
  cursor-bin, slack-desktop, brave-bin, zen-browser-bin, claude-desktop,
  dropbox, spotify and (aarch64) zed — no local AUR build needed.

## Not repeated here, because Omarchy installs them itself

Google Chrome, Obsidian, LocalSend, LibreOffice, Docker, mise, Neovim, the herdr CLI,
Superwhisper, mpv, Disktree, and the web apps ChatGPT, Grok, WhatsApp, X,
YouTube, Zoom, Discord, Google apps, HEY, Basecamp.

## Not ported, on purpose

- Mac-only, Omarchy has its own: iStat Menus (btop / top bar), TripMode,
  GrandPerspective / PearCleaner / PureMac / DevCleaner (Disktree), OrbStack /
  UTM (native Docker / KVM), GPG Suite (gnupg), Tunnelblick, Commander One.
- No Linux client: Granola, Grammarly, Franz, Clockify desktop, Sonos.

The list was derived 2026-11-24 from rouven-m5-pro's Homebrew casks and
`pwas.txt`, checked against Omarchy 4's own defaults, and pruned by the owner
2026-11-26. It was split into profiles 2026-11-28.
