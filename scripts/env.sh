# Source this file, do not execute it:  source scripts/env.sh
# Puts the pinned CLIs from .bin/ first on PATH and points kubectl,
# flux and kind at the local cluster's kubeconfig.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "Source this file instead: source scripts/env.sh" >&2
  exit 1
fi

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$_repo_root/.bin:$PATH"
export KUBECONFIG="$HOME/.kube/openbao-local"
unset _repo_root
