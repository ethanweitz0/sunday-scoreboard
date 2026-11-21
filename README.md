# Sunday Scoreboard

Watch a live stream on Apple TV with ESPN Fantasy Football scoring popups. A starter gaining **6 or more fantasy points** between ESPN updates triggers a five-second banner with their name, points gained, and the matchup score. Passing, rushing, receiving, and offensive fumble-recovery touchdowns also trigger a banner. If both rules apply, one touchdown banner appears.

## 1. Try the demo on your Mac

You’ll need a Mac with Xcode and the tvOS platform installed. The project targets tvOS 17 or later.

1. On GitHub, select **Code → Download ZIP** and unzip it.
2. Open **SundayScoreboard.xcodeproj** in Xcode. Install the tvOS platform and simulator runtime if prompted.
3. In the toolbar, choose the **SundayScoreboard** scheme and an **Apple TV simulator**. Press **⌘R**.
4. In the app, choose **Demo → Big fantasy gain**. You can also try **Demo → Touchdown**. Both work without accounts or a video stream.

## 2. Install on Apple TV

1. Connect the Mac and Apple TV to the same network. On Apple TV, open **Settings → Remotes and Devices → Remote App and Devices**.
2. In Xcode, open **Device Hub** or **Devices and Simulators**, select your Apple TV, and follow the pairing prompts.
3. In the **SundayScoreboard** target’s **Signing & Capabilities** tab, enable **Automatically manage signing** and select your Apple development team. Add your Apple Account in **Xcode → Settings → Accounts** if the team list is empty. If the bundle identifier is unavailable, change it to a unique identifier, such as `com.yourname.sundayscoreboard`.
4. Choose the paired Apple TV as the run destination and press **⌘R**. Follow any development prompts on the device.

[Apple’s guide to running apps in Xcode](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

## 3. Connect your ESPN team

1. In a browser, open your team's **Clubhouse** in ESPN Fantasy Football. Find `seasonId`, `leagueId`, and `teamId` in the page address. For example, a query ending in `?leagueId=123456&seasonId=2026&teamId=3` gives season `2026`, league ID `123456`, and team ID `3`.
2. In Sunday Scoreboard, choose **Setup** and enter those numbers under **ESPN Fantasy**.
3. For a public league, leave both cookie fields blank. For a private league, sign in to ESPN Fantasy in your browser. In Chrome, open **Developer Tools → Application → Storage → Cookies**, select the ESPN origin, and enter the values of `SWID` and `espn_s2` in the app’s secure fields. Treat those values like passwords and keep them out of GitHub issues and screenshots.
4. Select **Connect ESPN** and look for **ESPN connected**. Close Setup to see the scoreboard.

The first successful refresh sets the starting score. The app checks ESPN roughly every 20 seconds while open and watches your active starters. ESPN and the stream can update at different speeds, so banners may appear before or after the play. Points gained are the net change since the previous refresh.

## 4. Add live video (optional)

- **Direct stream.** In **Setup**, enter a playable HTTPS HLS `.m3u8` URL and choose **Play URL**.
- **Xtream provider.** Enter your provider’s HTTPS server address, username, and password. Choose **Load channels**, then **Done → Channels**, and select a channel.

The app also works as a scoreboard without video. ESPN cookies and stream credentials stay in app memory for the current session.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Apple TV is missing in Xcode | Check that both devices are on the same network and that the Apple TV pairing screen is open. |
| Xcode reports a signing error | Select your development team and try a unique bundle identifier. You can still use the simulator to try the demo. |
| ESPN cannot load a matchup | Confirm the season and IDs from your own team page. For private leagues, re-enter both cookie values. During a bye or outside an active matchup there may be no lineup to load. |
| A channel opens but does not play | Check that it serves HTTPS HLS. Try another channel or a direct HLS URL from your provider. |
