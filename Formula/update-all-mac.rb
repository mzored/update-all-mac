class UpdateAllMac < Formula
  desc "Update common macOS app and package managers"
  homepage "https://github.com/mzored/update-all-mac"
  url "https://github.com/mzored/update-all-mac/archive/refs/tags/v3.4.2.tar.gz"
  sha256 "8444d0dac6838bb0c531caf33e3c948ae48f99354ed4ee2915839bd118ab2033"
  license "MIT"

  def install
    bin.install "update-all-mac.command" => "update-all-mac"
  end

  test do
    assert_match "homebrew", shell_output("#{bin}/update-all-mac --list-steps")
  end
end
