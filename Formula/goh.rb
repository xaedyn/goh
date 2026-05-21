# Homebrew formula for goh. Lives in-repo until a dedicated tap exists.
#
# Placeholder: `url` and `sha256` are filled when v0.1.0 is tagged. `brew services
# start goh` generates the operative LaunchAgent plist from the `service` block
# below — see Resources/dev.goh.daemon.plist for the reference layout.
class Goh < Formula
  desc "Daemon-backed terminal download manager for Apple Silicon macOS"
  homepage "https://github.com/xaedyn/goh"
  url "https://github.com/xaedyn/goh/archive/refs/tags/v0.1.0.tar.gz"
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :tahoe
  depends_on xcode: :build

  def install
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/goh"
    bin.install ".build/release/gohd"
  end

  # The daemon is opt-in: `brew install` installs the binaries but starts nothing.
  # The user enables the LaunchAgent explicitly with `brew services start goh`.
  service do
    run [opt_bin/"gohd"]
    keep_alive crashed: true
    run_type :immediate
    log_path var/"log/goh.log"
    error_log_path var/"log/goh.log"
  end

  test do
    assert_equal "goh", shell_output(bin/"goh").strip
  end
end
