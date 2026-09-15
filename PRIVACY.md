# MB Converter Privacy Policy

**Last updated: September 14, 2026**

This policy explains how MB Converter for iPhone and iPad handles information. “We” and “us” refer to the maintainers of MB Converter.

## Overview

MB Converter converts media on your device. You do not need an account, and the app does not upload your media, conversion history, or its local error log to us automatically. The app includes no advertising or third-party analytics or tracking SDKs. We do not sell your personal information or use it for targeted advertising.

Network downloads, sharing, Apple services, and information you send us for support are explained below.

## Media and permissions

The app processes photos, videos, audio, and associated metadata that you choose to import from Photos, Files, a direct link, or the clipboard. It uses that information to preview, inspect, edit, convert, and export your files.

- **Photos and Files:** the app uses system pickers to access the items you select and makes local working copies. It does not scan your entire photo library. An item stored with iCloud or another file provider may need to be downloaded by that provider.
- **Clipboard:** the app checks whether supported media types are available to enable its import control. It reads the media content when you choose to import it. Copying a result or diagnostic report places that content on the system clipboard, where it can be pasted into other apps and may be available on your other devices through Apple's Universal Clipboard.
- **Saving and sharing:** when you choose a save or share action, the selected destination receives the exported file. Photos access may be requested when saving to your photo library. Other apps and storage providers handle those files under their own privacy policies.

Media metadata can contain personal information, such as location coordinates, dates, device details, or author names. The app can preserve, edit, or remove supported metadata according to your export settings. Removing metadata from an export does not remove it from the original file or from any previously stored history or diagnostic entry.

## Direct-link downloads and external websites

When you import a direct link, your device connects to the host and any hosts it redirects to. Those services receive information needed for the request, such as your IP address, the requested URL, and normal network request details. Information included in the link is also sent to the relevant host. Downloads are not routed through a media-conversion server operated by us.

Opening links to GitHub or other websites also connects you to those services. Their privacy policies govern their handling of your information.

## Local storage, history, and deletion

The app stores appearance and history preferences on your device.

- **Working files:** imported copies and conversion working files are stored temporarily and cleaned when the app starts. iOS may also remove temporary files. Copies prepared for sharing or the clipboard can remain in temporary storage until it is cleaned.
- **Session history:** saved history is off by default. Session-only history is cleared when you quit and reopen the app.
- **Saved history:** when enabled, the app keeps converted files, original filenames and media details, conversion settings, and result information across launches. Enabling it also saves the current session's available history. You can delete individual entries, clear History, or turn saved history off and confirm deletion in Settings.
- **Local diagnostics:** the app records launch events and errors to help troubleshoot problems. These records persist across launches, with older entries removed as the log grows to approximately 5 MB. Clearing conversion history does not clear diagnostics. The current app has no separate control to clear the error log.

Deleting the app removes its local app data, including saved history, preferences, and diagnostics. Copies you saved or shared elsewhere, clipboard content, and existing backups must be managed separately. Offloading an app preserves its documents and data.

App data may be included in iCloud or computer backups depending on your device settings. We do not receive or control those backups. See [Apple's explanation of iCloud Backup](https://support.apple.com/en-us/108770).

## Diagnostic reports and support

You can review, copy, or export the app's diagnostic report in **Settings → Error Log**. Reports may include filenames, local paths, download URLs in error details, media metadata, conversion settings and commands, error messages, event times, app and operating system versions, device model, language/region settings, and technical debugging information.

Review reports before sharing them. They may contain information about your files even if you removed metadata from a later export. Exporting a report saves it to the destination you choose; it does not itself send the report to us.

If you submit a support request or share a report with us, we receive the information you provide, along with account or contact details supplied by the service you use. We use it to respond to your request, investigate problems, and improve the app. We retain support information for as long as needed for those purposes. You can contact us about access, correction, or deletion of information you have sent us. Retention by GitHub, Apple, or other services is also subject to their policies.

## Apple diagnostics and TestFlight

Apple may collect App Store diagnostics and usage information and share reports with developers according to your device settings and Apple's policies. This is separate from MB Converter's local Error Log.

If you use a beta through TestFlight, Apple automatically collects crash logs and usage information and makes beta-testing information available to us. Depending on how you join and submit feedback, that information can include your name, email address, device details, screenshots, and comments. We use information received through TestFlight to test and improve MB Converter. See [TestFlight & Privacy](https://www.apple.com/legal/privacy/data/en/test-flight/) and [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

## Your choices

You choose which files to import, whether to use link downloads, whether to save history, and what to export or share. You can manage permissions, backups, and Apple diagnostic-sharing settings through your device's settings. Declining access may limit the feature that needs it; you can continue using other available import and export methods.

## Changes to this policy

We will update this page when the app's information-handling practices change and revise the date above.

## Contact

For privacy questions or requests, contact the MB Converter maintainers through the [project's GitHub issue tracker](https://github.com/Marginally-Better-Apps/MB-converter/issues).

GitHub issues are public. Do not post private media, sensitive links, or an unredacted diagnostic report. For a sensitive request, post a general request for a private contact method without including the sensitive information.
