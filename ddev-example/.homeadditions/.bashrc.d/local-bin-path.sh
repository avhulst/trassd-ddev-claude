# Add ~/.local/bin to PATH for interactive shells (ddev ssh).
# A post-start hook can't do this: each hook exec runs in its own subshell,
# so `export PATH=...` there dies with that shell. Put it in a startup file.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac
