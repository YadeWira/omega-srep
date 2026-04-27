# Tiny path-portability shim sourced by test scripts that pass paths
# to non-MSYS programs (typically Python on Windows). On Linux the
# function is a no-op; on MinGW/MSYS/Cygwin it converts the POSIX
# path Bash uses into a Windows-style mixed-form path
# (`C:/foo/bar`) that native Windows programs can open.
#
# Usage:
#   source "$(dirname "$0")/_winpath.sh"
#   python3 some_script.py "$(winpath "$some_path")"

winpath() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m -- "$1"
    else
        printf '%s' "$1"
    fi
}
