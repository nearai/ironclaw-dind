# Interactive bash defaults for ironclaw-dind (SSH and tools that spawn bash -i).

case $- in
    *i*) ;;
    *) return 0 ;;
esac

HISTCONTROL=ignoreboth
HISTSIZE=10000
HISTFILESIZE=20000
HISTFILE="${HOME}/.bash_history"
shopt -s histappend
shopt -s checkwinsize 2>/dev/null || true

# Colored prompt when stdout is a TTY
if [ -n "${TERM:-}" ] && [ "${TERM}" != dumb ] && [ -t 1 ]; then
    PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='\u@\h:\w\$ '
fi

# Bash completion (package: bash-completion)
if [ -f /usr/share/bash-completion/bash_completion ]; then
    # shellcheck disable=SC1091
    . /usr/share/bash-completion/bash_completion
fi

# Rust toolchain (ironclaw-worker appends this in Dockerfile when rustup is installed)
if [ -f "${HOME}/.cargo/env" ]; then
    # shellcheck disable=SC1091
    . "${HOME}/.cargo/env"
fi
