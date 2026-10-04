# Security

Catchlight for Mac is the desktop version of a zero-knowledge, end-to-end encrypted app. Takes are encrypted on the device with standard cryptography (AES-256-GCM, HKDF and HMAC-SHA-256, all through Apple CryptoKit), and the key comes from the user's Privacy phrase and never leaves the device. There's no backend and there are no analytics, so if the encryption fails, there's nothing else standing between someone's notes and whoever is looking. If you've found a way past it, I want to hear about it.

## Reporting a vulnerability

Please report security issues **privately**, and don't open a public issue or a pull request.

Email **security@considus.com**. Tell me what you found, how to reproduce it, which version or commit it affects, and what it lets an attacker do.

I'll acknowledge it within **3 business days** and keep you posted while it's being looked at. This is coordinated disclosure, so please give me a reasonable amount of time to ship a fix before you make it public. You're welcome to the credit once it's out, or to stay anonymous, whichever you'd prefer.

## What's in scope

The Mac app, and how it stores, protects and syncs Takes on the Mac. The shared cryptographic design and the sync format sit in [Considus/Catchlight-Core](https://github.com/Considus/Catchlight-Core), and a report against any of the repos reaches the same inbox, so don't worry about picking the right one.

Report a problem with the catchlight.app website to the same address. The policy that covers the site, alongside every Catchlight app and package, is at [catchlight.app/security](https://catchlight.app/security/).

Generally out of scope, anything that needs a Mac that's already compromised, or physical access to one that's unlocked and signed in. Social engineering and denial of service are out too, along with findings in third-party platforms like Apple or whichever cloud provider the user picked, because those aren't mine to fix.

## Safe harbour

You won't face legal action from me or from Considus for research done in good faith, so long as you avoid violating anyone's privacy, avoid destroying data, and follow this policy.

## Supported versions

The `main` branch gets security fixes, and so will the current release once there is one.
