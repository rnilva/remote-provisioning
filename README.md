# remote-provisioning

Self-configuring setup for rented GPU instances (vast.ai). Drop the raw URL of
[`provision.sh`](./provision.sh) into a template's `PROVISIONING_SCRIPT` env var
and every new instance bootstraps my dev environment automatically.

## What it installs

- **zsh + oh-my-zsh**, set as the default shell, with a managed `~/.zshrc` block
  (PATH, `EDITOR=nvim`, auto-activate `/venv/main`, handy aliases).
- **tmux** with a sensible `~/.tmux.conf` (Ctrl-a prefix, mouse, vim pane nav,
  `|`/`-` splits, 256-color/RGB).
- **Neovim** (latest stable, fetched from GitHub releases — apt's is too old) +
  **LazyVim** starter, with plugins pre-synced headlessly.
- **Modern CLI tools**: ripgrep, fd, fzf, bat, lazygit.
- **uv** (fast Python package manager).

## How vast.ai runs it

`PROVISIONING_SCRIPT` is a feature of vast.ai's **base images**
(`vastai/base-image`, `vastai/pytorch`, and templates derived from them — they
run Supervisor + the Instance Portal). The script is:

- downloaded and executed **as `root`**, **after Supervisor starts** (so the
  `/venv/main` Python venv already exists);
- run **once** — vast touches `/.provisioning_complete` on success and skips it
  on later reboots (the script is still written to be idempotent for safe
  partial re-runs);
- logged to `/var/log/portal/`, viewable in the **Instance Portal**.

> ⚠️ A bare generic `nvidia/cuda` template (no Supervisor) will **not** run
> `PROVISIONING_SCRIPT`. Pick a template based on `vastai/base-image` or
> `vastai/pytorch`. For a truly bare image, use the on-start / `BOOT_SCRIPT`
> mechanism instead.

## Setup

1. Push this repo to GitHub.
2. In vast.ai → **Templates**, edit a template based on `vastai/base-image` or
   `vastai/pytorch`, and add an env var:

   ```
   PROVISIONING_SCRIPT=https://raw.githubusercontent.com/<you>/remote-provisioning/main/provision.sh
   ```

3. Launch an instance from that template. Watch progress in the Instance Portal
   (or `tail -f /var/log/portal/provisioning.log`).
4. SSH in and run `exec zsh` (or just open a new shell) to pick up the config.

## Cloudflare R2 credentials (for the `corroborate` project)

`corroborate` uses **boto3's standard credential chain**, so the script writes
`~/.aws/credentials` + `~/.aws/config` (with the R2 endpoint and a `[services
r2]` block; region `auto`). boto3 then picks them up with no extra wiring.

**Secrets never live in this repo.** Provide them as **vast.ai template env
vars**, which the script consumes at boot:

| Env var                 | Value                                                        |
| ----------------------- | ----------------------------------------------------------- |
| `R2_ACCESS_KEY_ID`      | R2 API token's Access Key ID                                |
| `R2_SECRET_ACCESS_KEY`  | R2 API token's Secret Access Key                            |
| `R2_ACCOUNT_ID`         | Cloudflare account ID (endpoint is derived from it)         |
| `R2_ENDPOINT_URL`       | *(optional)* full endpoint, overrides `R2_ACCOUNT_ID`       |

The derived endpoint is `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com`. If
none are set, the script just skips R2 setup.

> 🔒 **Security:** vast template env vars are shown in plaintext in the template
> UI. Keep the template **private** (don't share/publish it), or set these vars
> per-instance at launch instead of saving them on the template. The script does
> not echo secret values to the Instance Portal logs, and writes `~/.aws` files
> as `chmod 600`. Use a **scoped R2 API token** (single bucket, minimal perms)
> so a leak is contained, and rotate it if exposed.

Verify on the instance with: `aws s3 ls --endpoint-url $R2_ENDPOINT_URL` (if the
AWS CLI is present) or corroborate's own pre-flight auth check.

## Customizing

Everything lives in [`provision.sh`](./provision.sh) as clearly delimited,
idempotent sections — edit the tmux/zsh heredocs or add steps as needed. Because
vast caches per-instance via `/.provisioning_complete`, changes apply to the
**next** instance you launch.
