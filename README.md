# Catchlight for Mac

The Mac version of [Catchlight](https://catchlight.app), the zero-knowledge notes and reminders app. Everything is encrypted on your device, there's no backend, and the whole thing works with the network switched off.

There's no app here yet. The repo exists so the work can happen in the open from the first commit, rather than being tidied up and published afterwards. The iPhone app it follows is at [Considus/Catchlight-iOS](https://github.com/Considus/Catchlight-iOS), and that's the place to look if you want to see how the encryption and the sync format actually work today.

## The non-negotiables

The Mac app carries the same ones as the iPhone app, and none of them gets relaxed because a desktop has more room to manoeuvre.

- Zero knowledge, so no backend, no analytics, and nothing transmitted off the device anywhere.
- Encryption is always on. Never optional, never toggleable.
- `kSecAttrSynchronizable: false` on every Keychain item.
- Offline-first, so everything works with no network at all. Sync is additive, and local-only is a real way to run it.
- A Take written on the Mac has to open on the iPhone and the other way round, byte for byte, so the file format and the crypto belong to the shared contract, not to this repo.

## Security

If you've found a security problem, please don't open an issue. [`SECURITY.md`](SECURITY.md) says how to report it privately.

## Licence

Apache 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
