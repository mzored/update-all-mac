class UpdateAllMac < Formula
  desc "Update common macOS app and package managers"
  homepage "https://github.com/mzored/update-all-mac"
  url "https://github.com/mzored/update-all-mac/archive/refs/tags/v3.3.0.tar.gz"
  sha256 "930350667502884a0b002b7a84c70877f0a35615205a0b9b144f2e289929c03f"
  license "MIT"

  def install
    bin.install "update-all-mac.command" => "update-all-mac"
  end

  test do
    assert_match "homebrew", shell_output("#{bin}/update-all-mac --list-steps")
  end
end
