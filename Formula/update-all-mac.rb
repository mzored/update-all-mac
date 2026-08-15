class UpdateAllMac < Formula
  desc "Update common macOS app and package managers"
  homepage "https://github.com/mzored/update-all-mac"
  url "https://github.com/mzored/update-all-mac/archive/refs/tags/v3.4.0.tar.gz"
  sha256 "f9ee406cafa16deafd0fb5f77640f45248b3acf54fbfad333f6b96febf15f4da"
  license "MIT"

  def install
    bin.install "update-all-mac.command" => "update-all-mac"
  end

  test do
    assert_match "homebrew", shell_output("#{bin}/update-all-mac --list-steps")
  end
end
