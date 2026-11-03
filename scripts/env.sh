# Sourced by the other scripts. Moves to the project root and keeps every build byproduct
# inside build/: Swift and Xcode otherwise leave temporary directories, lock files and module
# caches in $TMPDIR and in global caches.

NIBBLE_ROOT="${${(%):-%x}:A:h:h}"
cd "$NIBBLE_ROOT"

BUILD_DIR="$NIBBLE_ROOT/build"
# ".noindex" keeps Spotlight from listing build copies of the app next to an installed one.
DERIVED_DATA="$BUILD_DIR/DerivedData.noindex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Settings of this checkout that stay out of git, such as NIBBLE_TEAM (see local.env.example).
[[ -f "$NIBBLE_ROOT/local.env" ]] && source "$NIBBLE_ROOT/local.env"

mkdir -p "$BUILD_DIR"
# Temporary folders whose run has ended. A run removes its own on exit, but zsh skips the EXIT trap
# when a script dies on an expansion error (an unset parameter, a bad substitution).
for stale_tmp in "$BUILD_DIR"/tmp.*(N/); do
    owner=""
    [[ -f "$stale_tmp/.owner" ]] && owner="$(<"$stale_tmp/.owner")"
    if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then rm -rf "$stale_tmp"; fi
done
export TMPDIR="$(mktemp -d "$BUILD_DIR/tmp.XXXXXX")/"
print -r -- $$ > "${TMPDIR}.owner"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
trap 'rm -rf "$TMPDIR"' EXIT
