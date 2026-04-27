# Bash completion for osrep (Omega SREP).
#
# Install:
#   /usr/share/bash-completion/completions/osrep   (system-wide)
#   ~/.local/share/bash-completion/completions/osrep
# or source manually:
#   source completions/osrep.bash

_osrep() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Long flags taking an inline =VALUE.
    if [[ "$cur" == --chunk-avg=* ]]; then
        COMPREPLY=( $(compgen -W "1024 2048 4096 8192 16384" -- "${cur#--chunk-avg=}") )
        COMPREPLY=( "${COMPREPLY[@]/#/--chunk-avg=}" )
        return 0
    fi
    if [[ "$cur" == --chunk-min=* ]]; then
        COMPREPLY=( $(compgen -W "512 1024 2048 4096" -- "${cur#--chunk-min=}") )
        COMPREPLY=( "${COMPREPLY[@]/#/--chunk-min=}" )
        return 0
    fi
    if [[ "$cur" == --chunk-max=* ]]; then
        COMPREPLY=( $(compgen -W "8192 16384 32768 65536" -- "${cur#--chunk-max=}") )
        COMPREPLY=( "${COMPREPLY[@]/#/--chunk-max=}" )
        return 0
    fi
    if [[ "$cur" == --chunk-buf=* ]]; then
        COMPREPLY=( $(compgen -W "1048576 8388608 67108864" -- "${cur#--chunk-buf=}") )
        COMPREPLY=( "${COMPREPLY[@]/#/--chunk-buf=}" )
        return 0
    fi
    if [[ "$cur" == --seed=* ]]; then
        COMPREPLY=( $(compgen -W "0 1 42 0xCAFEBABE" -- "${cur#--seed=}") )
        COMPREPLY=( "${COMPREPLY[@]/#/--seed=}" )
        return 0
    fi
    if [[ "$cur" == -hash=* ]]; then
        COMPREPLY=( $(compgen -W "vmac siphash md5 sha1 sha512" -- "${cur#-hash=}") )
        COMPREPLY=( "${COMPREPLY[@]/#/-hash=}" )
        return 0
    fi

    # Top-level option list.
    case "$cur" in
        -*)
            local opts="
                -m0 -m1 -m2 -m3 -m4 -m5 -mx
                -m1f -m2f -m3f -m4f -m5f
                -m1o -m2o -m3o -m4o -m5o
                -d -i -delete
                -mmap -nommap -hash- -slp -slp+ -slp-
                -dup --dup-paranoid
                --chunk-avg= --chunk-min= --chunk-max= --chunk-buf=
                --seed= --version --help
                -V -h
                -hash=
            "
            COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
            return 0
            ;;
    esac

    # Default: complete on filenames (compress/decompress takes paths).
    COMPREPLY=( $(compgen -f -- "$cur") )
    return 0
}

complete -F _osrep -o filenames osrep
