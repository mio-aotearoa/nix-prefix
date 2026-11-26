# vphone-cli iOS Nix validation plan

Status: proposed, not started

Date: 2026-11-26

Context: the rootless iOS track has installer and payload-validation support,
but it cannot yet produce or execute a native iOS Nix closure. `vphone-cli`
can provide a virtual iPhone test environment without solving the cross-build
problem itself.

## Objective

Use `vphone-cli` as a local, end-to-end test target for the rootless iOS Nix
payload. The test should prove whether a future native closure can:

1. Execute iOS ARM64 Mach-O binaries from `/var/jb/nix/store`.
2. Load its registration database and pass store verification.
3. Run Nix commands and at least one local derivation inside the guest.
4. Support a later Home Manager experiment without changing the payload format.

This plan separates two problems:

- **Build problem:** producing a genuine iOS Mach-O closure with the iPhone
  cross stdenv. `vphone-cli` does not fix this.
- **Runtime problem:** installing and executing that closure on iOS rootless
  userspace. `vphone-cli` can make this testable.

## Current evidence

The NUR package was built and smoke-tested on 2026-11-26:

```sh
nix build 'github:mio-aotearoa/nurpkgs#vphone-cli' \
  --out-link /tmp/nix-prefix-vphone-cli -L
/tmp/nix-prefix-vphone-cli/bin/vphone-cli --help
```

Result:

- Source pin: `29477a79bf7cc0391ec5c88174eed8046ae107bf`
- Upstream package: `Lakr233/vphone-cli` at
  `2a4ed5f8ee9b251420fd687bbce60e682645cb3c`
- Nix build completed successfully.
- The package install check passed, including strict `codesign --verify` on
  `VPhone.bundle`.
- `vphone-cli`, `vphone-vm`, and `vphone-escalator` are present.

Host preflight currently fails because AMFI blocks the source-built VM:

```text
Error: AMFI blocked vphone-vm, so the VM could not start.
CDHash: 965e4a16ac27754c404f747ba3097e79cb110526
```

The reported allowlist command is:

```sh
sudo \
  /nix/store/61k4whrws1n8c2dak3gql116fn728l0m-vphone-cli-0-unstable-2026-11-25/Applications/VPhone.bundle/Contents/MacOS/vphone-escalator \
  allow \
  /nix/store/61k4whrws1n8c2dak3gql116fn728l0m-vphone-cli-0-unstable-2026-11-25/Applications/VPhone.bundle/Contents/MacOS/vphone-vm
```

Do not assume that store path remains valid after garbage collection. Resolve
the current out-link before using the command and expect the CDHash to change
after every source rebuild.

## Safety boundaries

- Do not create a VM or change Recovery, SIP, AMFI, boot arguments, or Research
  Guest settings without explicit approval.
- Use the least permissive documented host option: SIP enabled with debugging
  relaxed and Research Guests enabled. Do not use the AMFI-disabled option.
- Keep the VM library and IPSW cache off the internal disk if enough external
  storage is not available locally.
- Do not use a GitHub-hosted macOS runner for this test. The tool requires a
  physical Apple Silicon host, non-nested virtualization, Recovery changes,
  and a signature-specific AMFI allowlist.
- Do not treat the deprecated rootless layout as a permanent product target.
  It is selected here because the current installer expects `/var/jb`.
- Do not upload or install the existing host-macOS experimental closure. It is
  expected to fail iOS platform validation.

## Prerequisites

### Storage

A default guest has a 64 GB virtual disk. IPSWs, restore trees, templates, and
patching scratch space require additional capacity. Plan for at least 120 GiB,
preferably 150 GiB, of free space before starting. Current free space was 48
GiB, so this prerequisite is not met.

If using an external volume, set a dedicated library/cache root:

```sh
export VPHONE_ROOT=/Volumes/<volume>/vphone
export VPHONE_LIBRARY_ROOT="$VPHONE_ROOT/machines"
```

The selected volume must not ignore ownership. Prefer APFS so clones share
blocks copy-on-write.

### Host security and entitlement

Confirm current state before changing anything:

```sh
csrutil status
```

If Research Guests are not enabled, the documented Recovery-terminal setup is:

```sh
csrutil enable --without debug
csrutil allow-research-guests enable
```

Then reboot. After rebuilding or changing the bundle, run:

```sh
OUT="$(nix build --no-link --print-out-paths \
  'github:mio-aotearoa/nurpkgs#vphone-cli')"
CLI="$OUT/bin/vphone-cli"
"$CLI" host preflight
```

If preflight still requests allowlisting, run the exact command it prints.
The allowlist entry is tied to `vphone-vm`'s CDHash and must be repeated after
each rebuilt bundle.

### Required validation

Before creating the VM, all of these must hold:

```sh
"$CLI" vm list
"$CLI" fw catalog
"$CLI" host preflight
```

`vm list` may be empty, but it must run successfully. `fw catalog` must resolve
the desired iPhone firmware and cloudOS pair. `host preflight` must exit zero.

## Phase 1: create a rootless virtual iPhone

Choose a dedicated machine name, library root, and firmware release. Prefer a
recent release present in `fw catalog`; the exact release should be recorded
in the test log.

Create one machine at a time. The creation path downloads IPSWs, patches the
boot chain, restores the guest, installs custom firmware, performs a first boot,
and installs the bootstrap.

```sh
NAME=nix-ios-test

"$CLI" vm create "$NAME" \
  --library-root "$VPHONE_LIBRARY_ROOT" \
  --bootstrap rootless \
  --disk-size 64 \
  --cpu 8 \
  --memory 8192 \
  --network nat
```

Do not pass `--skip-first-boot` when using `--bootstrap rootless`: the bootstrap
is installed during the creation pipeline's first-boot phase.

Expected result:

- VM bundle exists under `$VPHONE_LIBRARY_ROOT/$NAME`.
- Creation reports every pipeline stage as successful.
- `vm info` identifies the firmware and bundle versions used.

Failure handling:

- Capture `vm log <name> --kind create`, `--kind dfu`, and `--kind patch`.
- Do not reuse a half-created name. Retry from a named step only while the same
  CLI process remains available; otherwise create under a new name.
- Do not kill a restore in progress.

## Phase 2: launch and verify the guest bootstrap

Configure SSH forwarding before launch:

```sh
"$CLI" vm config "$NAME" \
  --library-root "$VPHONE_LIBRARY_ROOT" \
  --forward tcp:127.0.0.1:2222:22 \
  --unlock-at-startup on
```

Launch headlessly and wait for the control service:

```sh
"$CLI" vm launch "$NAME" \
  --library-root "$VPHONE_LIBRARY_ROOT" \
  --headless \
  --api-listen 127.0.0.1:8765 \
  --detach \
  --timeout 300
```

Verify inside the guest:

```sh
ssh -p 2222 mobile@127.0.0.1
uname -a
uname -m
test -L /var/jb
dpkg --print-architecture
command -v bash
command -v apt
sudo -v
```

The bootstrap documentation does not prescribe the SSH credentials. Use the
credentials configured for the guest, and verify that `sudo` works before
attempting installation. Do not bake a password or an assumed root login into
the test procedure.

Acceptance criteria:

- Guest reports Darwin on `arm64` or `aarch64`.
- `/var/jb` resolves to the rootless environment.
- `dpkg --print-architecture` succeeds.
- Bash and the bootstrap command-line tools are available.

If rootless bootstrap installation fails, record the error and stop. Do not
hand-build the bootstrap layout around the installer.

## Phase 3: prepare a candidate Nix payload

This phase requires a closure that passes:

```sh
test -f result/nix-ios-jb-aarch64.tar.gz
./ios/validate-payload.sh \
  --require-signature \
  result/nix-ios-jb-aarch64.tar.gz
```

Do not proceed with the experimental host-closure artifact. A valid candidate
must contain:

- Only ARM64 Mach-O files with iOS platform load commands.
- No ELF files and no macOS Mach-O files.
- `/var/jb/nix/store` paths in `registration`.
- A present `bin/nix-store` entry.
- Valid signatures after all post-link changes.

Copy the archive and installer toolkit into the guest over SSH:

```sh
ssh -p 2222 mobile@127.0.0.1 \
  'mkdir -p /tmp/nix-ios-installer'

scp -P 2222 \
  result/nix-ios-jb-aarch64.tar.gz \
  mobile@127.0.0.1:/tmp/nix-ios-jb-aarch64.tar.gz

scp -P 2222 \
  ios/install-nix-ios.sh \
  ios/install-payload.sh \
  ios/sign-store.sh \
  ios/ios-nix-env.sh \
  mobile@127.0.0.1:/tmp/nix-ios-installer/
```

The archive and toolkit are staged under `/tmp` so the test does not depend on
whether the SSH shell exposes the guest's `/var/mobile` path directly.

Before installing, record:

```sh
sha256sum /tmp/nix-ios-jb-aarch64.tar.gz
df -h /var/jb
```

Install without on-device re-signing first. Signing after registration hashes
are generated can invalidate `nix store verify`.

## Phase 4: install and execute on the guest

Run on the guest:

```sh
chmod +x /tmp/nix-ios-installer/install-nix-ios.sh
sudo /tmp/nix-ios-installer/install-nix-ios.sh \
  --archive /tmp/nix-ios-jb-aarch64.tar.gz

. /var/jb/nix/etc/nix/ios-nix-env.sh
nix --version
nix-store --version
```

Then check closure integrity:

```sh
nix-store --verify --check-contents
```

Run a minimal local derivation to prove builder execution:

```sh
SHELL_PATH="$(command -v bash)"

cat > /tmp/ios-builder-smoke.nix <<EOF
derivation {
  name = "ios-builder-smoke-test";
  system = builtins.currentSystem;
  builder = "${SHELL_PATH}";
  args = [ "-c" "printf native-builder-ok > \$out" ];
}
EOF

OUT="$(nix build --no-link --print-out-paths -f /tmp/ios-builder-smoke.nix)"
cat "$OUT"
```

Acceptance criteria:

- `nix` and `nix-store` execute without macOS binary translation.
- Database registration loads without missing-path errors.
- Store verification passes, or any content mismatch is traced to a known
  signing step rather than ignored.
- The minimal derivation builds, and the output contains
  `native-builder-ok`.

If `nix-store` fails to execute, inspect the Mach-O platform, code signature,
entitlements, dyld dependencies, and path registration before changing the
installer.

## Phase 5: determine the next blocker

Record one of these outcomes:

1. **Runtime validated:** the closure executes and builds. Next work can focus
   on broader packages and Home Manager.
2. **Signature failure:** AMFI rejects a store binary. Compare `ldid`-shape,
   Apple ad-hoc, and the virtual guest's acceptance rules. Keep signing done
   before registration hashing.
3. **Platform/linking failure:** binaries are macOS or miss iOS load commands.
   Return to the iPhone cross stdenv and linker work.
4. **Sandbox/process failure:** Nix cannot spawn builders or resolve `/var/jb`.
   Inspect sandbox settings, `allow-symlinked-store`, and the guest bootstrap
   layout.

The first failure should become a focused test in this repository, not an
unrecorded manual experiment.

## CI and repository integration

There is no planned CI dependency on `vphone-cli`:

- GitHub-hosted macOS runners are not suitable research-guest hosts.
- Every source rebuild changes the VM CDHash and requires host re-allowlisting.
- Recovery changes and `sudo` are outside the repository's automated CI model.

Potential repository changes after a successful manual run:

- Add a guest smoke-test script that assumes a running rootless guest.
- Add a documented payload compatibility matrix keyed by iOS and cloudOS build.
- Add a `vphone-cli sign` compatibility test if `ldid`-shape signing is needed.
- Keep `validate-payload.sh` as the mandatory pre-install gate.

These changes should follow evidence from the virtual guest, not precede it.

## Stop conditions

Stop and report rather than improvise if any of the following occurs:

- Host preflight still fails after the documented setup.
- Virtualization is unavailable because this Mac is itself virtualized.
- Storage drops below the safe threshold during creation.
- The firmware pair is absent from `fw catalog`.
- `vm create` enters an unrecoverable restore state.
- The candidate payload fails `validate-payload.sh`.
- Installing the payload would overwrite an existing valuable `/var/jb/nix`
  without an explicit backup decision.
