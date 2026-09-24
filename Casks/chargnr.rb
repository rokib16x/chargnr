cask "chargnr" do
  version "0.2.0"
  sha256 "5760d2d978212e19a5122b843c71eeb2b7cd5915d900565f66050e135358a518"

  url "https://github.com/rokib16x/chargnr/releases/download/v#{version}/chargnr-#{version}.dmg"
  name "chargnr"
  desc "Battery charge limiter for Apple Silicon Macs"
  homepage "https://github.com/rokib16x/chargnr"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "chargnr.app"
  binary "#{appdir}/chargnr.app/Contents/MacOS/chargnr-cli", target: "chargnr"

  # The helper restores normal charging when launchd stops it.
  uninstall launchctl: "com.rokib16x.chargnr.helper",
            quit:      "com.rokib16x.chargnr",
            delete:    [
              "/Library/LaunchDaemons/com.rokib16x.chargnr.helper.plist",
              "/Library/PrivilegedHelperTools/com.rokib16x.chargnr.helper",
            ]

  zap trash: [
    "/Library/Application Support/chargnr",
    "~/Library/Preferences/com.rokib16x.chargnr.plist",
  ]
end
