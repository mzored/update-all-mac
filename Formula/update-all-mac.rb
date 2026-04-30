class UpdateAllMac < Formula
  desc "Update common macOS app and package managers"
  homepage "https://github.com/mzored/update-all-mac"
  url "https://github.com/mzored/update-all-mac/archive/refs/tags/v3.1.1.tar.gz"
  sha256 "ecf910b5c00f3900dea2bcf57ec4d7c7f9ad29c45560ece2ad98c2bba5bffb7b"
  license "MIT"

  def install
    bin.install "update-all-mac.command" => "update-all-mac"
  end

  test do
    assert_match "homebrew", shell_output("#{bin}/update-all-mac --list-steps")
  end
end
