# Contributing to Catchlight for Mac

Thanks for taking a look. Catchlight holds people's private notes under a key the user controls and nobody else has, so the constraints below aren't house style. They're the reason the app is worth having.

There's no app code here yet, so there's nothing to build. This page will say how once there is.

## Before you write anything

Read the non-negotiables in [`README.md`](README.md), the zero-knowledge and encryption-always-on ones in particular. A contribution that weakens either of them won't be accepted, however good the rest of it is.

The encryption design is shared with the iPhone app, and its derivation parameters and domain-separation strings are frozen. They're the bytes every Catchlight client has to agree on, which is the only way a Take written on a Mac opens on an iPhone, so please don't propose changes to them here.

## Pull requests

- No analytics, no telemetry, nothing transmitted off the device. Ever.
- `kSecAttrSynchronizable: false` on every Keychain item, and that one isn't up for discussion.
- No third-party dependencies without talking about it first.
- Follow the code style that's already there.

## Security issues

Please don't open a public issue for a security vulnerability. [`SECURITY.md`](SECURITY.md) says how to report one privately.
