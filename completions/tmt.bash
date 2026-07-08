# bash completion for tmt (tmux-tasks)
_tmt() {
  local cur prev subcmds
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  subcmds="watch ls status capture send key new save restore snapshots agent-scan attach version help"

  # complete the subcommand itself
  if [[ $COMP_CWORD -eq 1 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$subcmds" -- "$cur")
    return
  fi

  # for subcommands that take a session name, complete from live sessions
  case "${COMP_WORDS[1]}" in
    status|capture|send|key|attach)
      if [[ $COMP_CWORD -eq 2 ]]; then
        local sessions
        sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
        mapfile -t COMPREPLY < <(compgen -W "$sessions" -- "$cur")
        return
      fi
      ;;
    watch|ls|agent-scan)
      [[ "$cur" == -* ]] && mapfile -t COMPREPLY < <(compgen -W "--filter --interval --json" -- "$cur")
      return
      ;;
    save)
      [[ "$cur" == -* ]] && mapfile -t COMPREPLY < <(compgen -W "--filter --name" -- "$cur")
      return
      ;;
    restore)
      if [[ "$cur" == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--run --dry-run" -- "$cur")
      else
        local sdir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-tasks/snapshots"
        local snaps; snaps=$(cd "$sdir" 2>/dev/null && ls -1 *.tsv 2>/dev/null | grep -v '^latest.tsv$')
        mapfile -t COMPREPLY < <(compgen -W "$snaps" -- "$cur")
      fi
      return
      ;;
  esac
}
complete -F _tmt tmt
