# Homebrew formula for tmux-tasks.
#
# Publish this in a tap repo (e.g. github.com/<you>/homebrew-tap) so users can:
#   brew tap HJSang/tap
#   brew install tmux-tasks
#
# Update `url`, `homepage`, and `sha256` when you cut a release tag.
class TmuxTasks < Formula
  desc "Monitor and interact with per-task tmux sessions from one place"
  homepage "https://github.com/HJSang/tmux-tasks"
  url "https://github.com/HJSang/tmux-tasks/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  license :public_domain
  version "0.2.0"

  depends_on "tmux"
  depends_on "jq" # only needed for `agent-scan --json`

  def install
    bin.install "bin/tmt"
    bash_completion.install "completions/tmt.bash" => "tmt"
  end

  test do
    assert_match "tmux-tasks", shell_output("#{bin}/tmt version")
  end
end
