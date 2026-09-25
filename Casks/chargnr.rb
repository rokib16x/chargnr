cask "chargnr" do
  version "0.2.1"
  sha256 "bf29850cf52134df5900610b437ae1b0b00558f2fb747e57d1833b15a50d1fa7"

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
