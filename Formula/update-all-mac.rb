class UpdateAllMac < Formula
  desc "Update common macOS app and package managers"
  homepage "https://github.com/mzored/update-all-mac"
  url "https://github.com/mzored/update-all-mac/archive/refs/tags/v3.4.1.tar.gz"
  sha256 "cf242474332f776555093462c040deac8fae179cb28e01dad41e4f22d182dd8b"
  license "MIT"

  def install
    bin.install "update-all-mac.command" => "update-all-mac"
  end

  test do
    assert_match "homebrew", shell_output("#{bin}/update-all-mac --list-steps")
  end
end
