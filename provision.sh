#!/usr/bin/env bash
#
# provision.sh — vast.ai PROVISIONING_SCRIPT
#
# Point a vast.ai template's PROVISIONING_SCRIPT env var at the *raw* URL of
# this file, e.g.
#
#   PROVISIONING_SCRIPT=https://raw.githubusercontent.com/<you>/remote-provisioning/main/provision.sh
#
# It runs once, as root, after Supervisor starts (so /venv/main already exists).
# vast touches /.provisioning_complete on success and skips it on later boots,
# but every step below is written to be idempotent so a partial re-run is safe.
#
# Sets up: zsh + oh-my-zsh, tmux (sensible config), neovim (latest stable) +
# LazyVim, modern CLI tools (ripgrep, fd, fzf, bat, lazygit), and uv.

set -euo pipefail

# ----------------------------------------------------------------------------
# Setup & helpers
# ----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
HOME="${HOME:-/root}"
export HOME
ARCH="$(uname -m)" # x86_64 on virtually all vast GPU hosts

log()  { printf '\n\033[1;36m[provision]\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Latest release tag for a GitHub repo, e.g. latest_tag neovim/neovim -> v0.11.0
latest_tag() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
    | grep -Po '"tag_name":\s*"\K[^"]+'
}

log "Starting provisioning on $(hostname) ($ARCH), HOME=$HOME"

# ----------------------------------------------------------------------------
# 1. Base apt packages + modern CLI tools
# ----------------------------------------------------------------------------
log "Installing base packages via apt"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git unzip tar \
  build-essential software-properties-common \
  tmux zsh \
  ripgrep fd-find fzf bat

# Debian/Ubuntu ship fd as 'fdfind' and bat as 'batcat'; LazyVim looks for the
# canonical names, so expose them on PATH.
mkdir -p /usr/local/bin
have fdfind && ln -sf "$(command -v fdfind)" /usr/local/bin/fd
have batcat && ln -sf "$(command -v batcat)" /usr/local/bin/bat

# lazygit (LazyVim's <leader>gg) — not in apt, pull the latest release binary.
if ! have lazygit; then
  log "Installing lazygit"
  lg_ver="$(latest_tag jesseduffield/lazygit)"; lg_ver="${lg_ver#v}"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/lazygit.tar.gz" \
    "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${lg_ver}_Linux_x86_64.tar.gz"
  tar -xzf "$tmp/lazygit.tar.gz" -C "$tmp" lazygit
  install -m 755 "$tmp/lazygit" /usr/local/bin/lazygit
  rm -rf "$tmp"
fi

# ----------------------------------------------------------------------------
# 2. Neovim (latest stable) — apt's version is too old for LazyVim
# ----------------------------------------------------------------------------
if ! have nvim; then
  log "Installing latest stable Neovim to /opt/nvim"
  tmp="$(mktemp -d)"
  # Asset was renamed in 0.10.4: try the new name first, fall back to the old.
  if ! curl -fsSL -o "$tmp/nvim.tar.gz" \
        "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"; then
    curl -fsSL -o "$tmp/nvim.tar.gz" \
      "https://github.com/neovim/neovim/releases/latest/download/nvim-linux64.tar.gz"
  fi
  rm -rf /opt/nvim
  mkdir -p /opt/nvim
  tar -xzf "$tmp/nvim.tar.gz" -C /opt/nvim --strip-components=1
  ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
  rm -rf "$tmp"
fi
log "Neovim: $(nvim --version | head -1)"

# ----------------------------------------------------------------------------
# 3. uv (fast Python package manager)
# ----------------------------------------------------------------------------
if ! have uv && [ ! -x "$HOME/.local/bin/uv" ]; then
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# ----------------------------------------------------------------------------
# 4. zsh + oh-my-zsh, set as default shell
# ----------------------------------------------------------------------------
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  log "Installing oh-my-zsh"
  # Let the installer write its default ~/.zshrc (which sources oh-my-zsh);
  # our managed block is appended afterwards. CHSH=no — we set the shell below.
  RUNZSH=no CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# Make zsh the login shell for root.
if [ "$(getent passwd "$(id -un)" | cut -d: -f7)" != "$(command -v zsh)" ]; then
  log "Setting zsh as default shell"
  chsh -s "$(command -v zsh)" || usermod -s "$(command -v zsh)" "$(id -un)" || true
fi

# Append a managed block to ~/.zshrc (idempotent via marker).
ZMARK="# >>> remote-provisioning managed block >>>"
if ! grep -qF "$ZMARK" "$HOME/.zshrc" 2>/dev/null; then
  log "Writing managed ~/.zshrc block"
  cat >> "$HOME/.zshrc" <<'ZRC'

# >>> remote-provisioning managed block >>>
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
export EDITOR=nvim
export VISUAL=nvim

# Activate the vast.ai venv automatically if present.
[ -f /venv/main/bin/activate ] && source /venv/main/bin/activate

alias vi=nvim
alias vim=nvim
alias ll='ls -alh'
alias gs='git status'
alias t='tmux new -A -s main'   # attach-or-create the 'main' session

# uv shell completions (best-effort)
command -v uv >/dev/null 2>&1 && eval "$(uv generate-shell-completion zsh 2>/dev/null)" || true
# <<< remote-provisioning managed block <<<
ZRC
fi

# ----------------------------------------------------------------------------
# 5. tmux config
# ----------------------------------------------------------------------------
if [ ! -f "$HOME/.tmux.conf" ]; then
  log "Writing ~/.tmux.conf"
  cat > "$HOME/.tmux.conf" <<'TMUX'
# ---- remote-provisioning tmux defaults ----
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 10
set -g focus-events on

# Prefix: Ctrl-a (easier than Ctrl-b)
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# Intuitive splits, keep cwd
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# Vim-style pane navigation
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Reload config
bind r source-file ~/.tmux.conf \; display "tmux.conf reloaded"

# Status bar
set -g status-style "bg=colour235,fg=colour250"
set -g status-left "#[bold] #S "
set -g status-right "#[fg=colour245] %Y-%m-%d %H:%M "
set -g status-left-length 30
TMUX
fi

# ----------------------------------------------------------------------------
# 6. LazyVim starter
# ----------------------------------------------------------------------------
if [ ! -d "$HOME/.config/nvim" ]; then
  log "Installing LazyVim starter"
  mkdir -p "$HOME/.config"
  git clone --depth 1 https://github.com/LazyVim/starter "$HOME/.config/nvim"
  rm -rf "$HOME/.config/nvim/.git"
fi

# Pre-install plugins headlessly so the first interactive launch is instant.
log "Syncing LazyVim plugins (headless, may take a minute)"
nvim --headless "+Lazy! sync" +qa 2>&1 | tail -5 || \
  log "Plugin sync hit an error; it will finish on first interactive launch."

# ----------------------------------------------------------------------------
# 7. Cloudflare R2 credentials for the ../corroborate project
#
#    Secrets are NEVER stored in this script (it lives at a public raw URL).
#    They come from vast.ai *template env vars*, set on the template:
#       R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID
#    (or supply R2_ENDPOINT_URL directly instead of R2_ACCOUNT_ID).
#
#    corroborate's cloud_auth.py uses boto3's standard credential chain, so we
#    materialize ~/.aws/{credentials,config} — including the R2 endpoint and the
#    [services r2] block it documents. R2 requires region 'auto'.
# ----------------------------------------------------------------------------
if [ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ]; then
  r2_endpoint="${R2_ENDPOINT_URL:-https://${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID or R2_ENDPOINT_URL}.r2.cloudflarestorage.com}"
  log "Writing ~/.aws credentials for Cloudflare R2 (endpoint: ${r2_endpoint})"
  mkdir -p "$HOME/.aws"
  ( umask 077
    cat > "$HOME/.aws/credentials" <<EOF
[default]
aws_access_key_id = ${R2_ACCESS_KEY_ID}
aws_secret_access_key = ${R2_SECRET_ACCESS_KEY}
EOF
    cat > "$HOME/.aws/config" <<EOF
[default]
region = auto
output = json
endpoint_url = ${r2_endpoint}
services = r2

[services r2]
s3 =
  endpoint_url = ${r2_endpoint}
EOF
  )
  chmod 600 "$HOME/.aws/credentials" "$HOME/.aws/config"
else
  log "R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY not set — skipping R2 setup."
fi

# ----------------------------------------------------------------------------
log "Provisioning complete. Open a new shell (or run: exec zsh) to start."
