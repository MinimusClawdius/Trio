# Time Sensitive Notifications (private fork)

Nightscout Trio **0.8.4** added:

```xml
<key>com.apple.developer.usernotifications.time-sensitive</key>
<true/>
```

to `Trio/Resources/Trio.entitlements` so alerts can use the **time-sensitive** interruption level (pierce Focus more reliably).

## Why it was removed on MinimusClawdius

GitHub Actions archive failed:

```text
Provisioning profile "match AppStore org.nightscout.***.trio"
doesn't include the Time Sensitive Notifications capability
doesn't include com.apple.developer.usernotifications.time-sensitive
```

Existing **match** App Store profiles were generated **before** that capability existed on the App ID.

## To restore (recommended later)

1. [Apple Developer](https://developer.apple.com/account/resources/identifiers/list) → your Trio **App ID**  
   → enable **Time Sensitive Notifications**
2. Regenerate profiles, e.g. run your repo’s **create_certs** workflow /  
   `fastlane match` nuke + bootstrap for the App Store profile
3. Re-add to `Trio/Resources/Trio.entitlements`:

```xml
<key>com.apple.developer.usernotifications.time-sensitive</key>
<true/>
```

4. Push and rebuild

Until then, notifications still work; time-sensitive level may fall back to active when the entitlement is absent.
