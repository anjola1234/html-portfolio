#!/usr/bin/env bash
set -eu  # exit on error/unset


# Default values
BRANCH="main"
CLEANUP=0

usage() {
  cat <<EOF
Usage: $0 [--cleanup] 
Interactive prompts will collect:
  - Git repository URL (HTTPS)
  - Personal Access Token (PAT) (input hidden)
  - Branch (default: main)
  - Remote SSH username
  - Remote server IP or host
  - SSH private key path (absolute or relative)
  - Application internal container port (e.g. 3000)
Options:
  --cleanup    Remove deployed resources on the remote host (optional)
EOF
  exit 2
}

# Parse flags (only --cleanup supported here)
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) CLEANUP=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

# Helper: read non-empty
read_nonempty() {
  local prompt="$1"
  local var
  while :; do
    printf "%s: " "$prompt" >&2
    if ! IFS= read -r var; then
      echo "Input aborted" >&2
      exit 3
    fi
    if [ -n "$var" ]; then
      printf '%s' "$var"
      return 0
    fi
    echo "Value cannot be empty. Please try again." >&2
  done
}

# Git repo URL (basic validation: starts with http[s]:// or git@)
while :; do
  repo_url=$(read_nonempty "Git repository URL (HTTPS or SSH)")
  case "$repo_url" in
    http://*|https://*|git@*) break ;;
    *)
      echo "Repository URL must start with http(s):// or git@ (SSH). Try again." >&2
      ;;
  esac
done

# PAT (hidden input). We won't print this anywhere.
printf "Personal Access Token (PAT) (input will be hidden): " >&2
stty -echo
if ! IFS= read -r GIT_PAT; then
  stty echo
  echo "Input aborted" >&2
  exit 3
fi
stty echo
echo >&2  # newline after hidden input
if [ -z "$GIT_PAT" ]; then
  echo "PAT cannot be empty." >&2
  exit 4
fi

# Branch (optional)
printf "Branch name (press Enter for 'main'): " >&2
IFS= read -r branch_in
if [ -n "$branch_in" ]; then
  BRANCH="$branch_in"
fi

# Remote SSH details
SSH_USER=$(read_nonempty "Remote SSH username (e.g. ubuntu)")
REMOTE_HOST=$(read_nonempty "Remote server IP or hostname")
# SSH key path (default ~/.ssh/id_rsa)
printf "SSH key path (press Enter for '~/.ssh/id_rsa'): " >&2
IFS= read -r keypath_in
if [ -n "$keypath_in" ]; then
  SSH_KEY_PATH="$keypath_in"
else
  SSH_KEY_PATH="$HOME/.ssh/id_rsa"
fi
# Expand tilde if present (POSIX-compatible)
case "$SSH_KEY_PATH" in
  ~/*) SSH_KEY_PATH="$HOME/${SSH_KEY_PATH#~/}" ;;
esac

# Application internal port (integer)
while :; do
  app_port=$(read_nonempty "Application internal container port (e.g. 3000)")
  case "$app_port" in
    ''|*[!0-9]*)
      echo "Port must be a number. Try again." >&2
      ;;
    *)
      CONTAINER_PORT="$app_port"
      break
      ;;
  esac
done

# Create a timestamped log file in the current directory
TS=$(date +%Y%m%d_%H%M%S)
LOGFILE="deploy_${TS}.log"
# Ensure we don't accidentally write the PAT in logs; store a masked PAT for debug only
MASKED_PAT="****${GIT_PAT: -4}"


log() {
  printf '%s %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGFILE"
}

log "START: deployment script"
log "Parameters: repo=${repo_url}, branch=${BRANCH}, remote=${SSH_USER}@${REMOTE_HOST}, ssh_key=${SSH_KEY_PATH}, container_port=${CONTAINER_PORT}"
log "Masked PAT: ${MASKED_PAT}"

# Security note for user
echo "NOTE: PAT will not be echoed to logs or terminal after input; it is stored in the script memory only for cloning." >&2


# Helper: cleanup function for temporary HOME
cleanup_tmp_home() {
  if [ -n "${TMP_HOME:-}" ] && [ -d "$TMP_HOME" ]; then
    # wipe sensitive files before remove
    if [ -f "$TMP_HOME/.netrc" ]; then
      shred -u "$TMP_HOME/.netrc" 2>/dev/null || rm -f "$TMP_HOME/.netrc"
    fi
    rm -rf "$TMP_HOME"
  fi
}
trap 'cleanup_tmp_home' EXIT

# Normalize repo dir name (strip .git and trailing slash)
repo_dir=$(basename "$repo_url")
repo_dir=${repo_dir%.git}
repo_dir=${repo_dir%/}

log "Section 2: Clone/Update repository: $repo_url -> local dir: $repo_dir (branch: $BRANCH)"

# If HTTPS repo, prepare a temporary HOME with .netrc storing the PAT
if printf '%s\n' "$repo_url" | grep -Eq '^https?://'; then
  # If not already provided, ask for GitHub username to include in .netrc
  # (needed because some git clients expect a username, we avoid exposing PAT on CLI)
  if [ -z "${GIT_USER:-}" ]; then
    printf "GitHub username for HTTP access (used only for .netrc): " >&2
    if ! IFS= read -r GIT_USER; then
      log "ERROR: aborted reading GitHub username"
      exit 11
    fi
  fi
  # Create temporary HOME to hold .netrc
  TMP_HOME=$(mktemp -d 2>/dev/null || (echo "Failed to create temp dir" >&2; exit 12))
  # Create secure .netrc
  cat > "$TMP_HOME/.netrc" <<NETRC
machine github.com
login $GIT_USER
password $GIT_PAT
NETRC
  chmod 600 "$TMP_HOME/.netrc"
  export HOME="$TMP_HOME"
  log "Created temporary HOME for git with .netrc for github.com (secure)"
fi

# Function to run git safely with current environment (with logging)
git_run() {
  log "+ git $*"
  if ! git "$@" 2>&1 | tee -a "$LOGFILE"; then
    log "ERROR: git command failed: git $*"
    return 1
  fi
  return 0
}

# Clone or update logic
if [ -d "$repo_dir" ] && [ -d "$repo_dir/.git" ]; then
  log "Repository already exists locally. Updating..."
  cd "$repo_dir" || { log "ERROR: failed to cd into $repo_dir"; exit 13; }
  # Ensure remote origin is correct (attempt to set it if mismatch)
  origin_url=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$origin_url" ] && [ "$origin_url" != "$repo_url" ]; then
    log "Remote 'origin' URL differs. Setting origin to $repo_url"
    git_run remote set-url origin "$repo_url" || { log "ERROR: failed to set origin url"; exit 14; }
  fi

  # Fetch and checkout branch
  git_run fetch --all --prune || { log "ERROR: git fetch failed"; exit 15; }
  # If branch exists locally, checkout, else try to create tracking branch
  if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    git_run checkout "$BRANCH" || git_run checkout -b "$BRANCH" "origin/$BRANCH" || { log "ERROR: checkout failed"; exit 16; }
  else
    # branch not on remote; try local checkout or error
    if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
      git_run checkout "$BRANCH" || { log "ERROR: checkout existing local branch failed"; exit 17; }
    else
      log "ERROR: branch '$BRANCH' not found on remote or locally"
      exit 18
    fi
  fi
  git_run pull --ff-only || { log "ERROR: git pull failed"; exit 19; }
  cd - >/dev/null || true
  log "Repository updated successfully"
else
  # Clone fresh
  log "Cloning repository..."
  # Use --branch so it checks out specified branch if it exists; otherwise clone default then checkout later.
  if ! git_run clone --depth 1 --branch "$BRANCH" "$repo_url" "$repo_dir"; then
    log "Clone with branch failed; trying full clone to recover..."
    # fallback: full clone then attempt checkout
    if ! git_run clone "$repo_url" "$repo_dir"; then
      log "ERROR: git clone failed"
      exit 20
    fi
    cd "$repo_dir" || { log "ERROR: cd after clone failed"; exit 21; }
    if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
      git_run checkout -b "$BRANCH" "origin/$BRANCH" || { log "ERROR: checkout after clone failed"; exit 22; }
    else
      log "Warning: branch '$BRANCH' not found; staying on default branch"
    fi
    cd - >/dev/null || true
  else
    log "Clone succeeded"
  fi
fi

# Ensure we have a working copy and move into it for next steps
if [ -d "$repo_dir" ] && [ -d "$repo_dir/.git" ]; then
  cd "$repo_dir" || { log "ERROR: cannot cd into $repo_dir"; exit 23; }
  # Record latest commit
  latest_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  log "Repository ready at $(pwd) (commit: $latest_commit)"
else
  log "ERROR: repository not present after clone/update"
  exit 24
fi

# Unset sensitive env if set
if [ -n "${TMP_HOME:-}" ]; then
  # revert HOME to original if needed - but we will cleanup in trap
  # We do not export an original HOME variable here; the trap will remove temp dir securely.
  log "Note: temporary HOME will be removed on exit (sensitive creds not persisted)"
fi


