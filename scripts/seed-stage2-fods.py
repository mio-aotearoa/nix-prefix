#!/usr/bin/env python3
"""Pre-seed pure Fixed-Output source Derivations (FODs) into a custom Stage-2 Nix store.

Why:
  Pure dramforever Stage-2 builds use a custom storeDir (/data/data/com.termux/files/nix/store),
  so cache.nixos.org (StoreDir: /nix/store) cannot directly substitute into it. However,
  Fixed-Output Derivations (source tarballs, patches, config.guess, config.sub,
  stage0-posix-*-source) are pure content with zero store-prefix references and are
  already cached on cache.nixos.org.

  Pre-seeding them from host /nix/store (via cache.nixos.org) into the Stage-2 store using
  `nix-store --add-fixed` avoids upstream 502s/timeouts (e.g. git.savannah.gnu.org) and
  eliminates circular bootstrap source errors (stage0-posix-*-source), while keeping 100%
  pure dramforever Stage-2 compilation for every built derivation.
"""

import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

NIX_BASE32 = "0123456789abcdfghijklmnpqrsvwxyz"


def nix_base32_encode(data: bytes) -> str:
    length = (len(data) * 8 - 1) // 5 + 1
    out = []
    for n in range(length - 1, -1, -1):
        b = n * 5
        i = b // 8
        j = b % 8
        c = data[i] >> j
        if i + 1 < len(data):
            c |= data[i + 1] << (8 - j)
        out.append(NIX_BASE32[c & 0x1F])
    return "".join(out)


def compress_hash(digest: bytes, size: int = 20) -> bytes:
    out = bytearray(size)
    for i, b in enumerate(digest):
        out[i % size] ^= b
    return bytes(out)


def fixed_output_store_path(store_dir: str, name: str, method: str, hash_algo: str, hash_hex: str) -> str:
    """Compute Nix's exact fixed-output store path for any storeDir."""
    recursive = method in ("nar", "recursive")
    if recursive and hash_algo == "sha256":
        inner = f"source:sha256:{hash_hex}:{store_dir}:{name}"
    else:
        prefix = "r:" if recursive else ""
        fixed_desc = f"fixed:out:{prefix}{hash_algo}:{hash_hex}:"
        fixed_hash = hashlib.sha256(fixed_desc.encode()).hexdigest()
        inner = f"output:out:sha256:{fixed_hash}:{store_dir}:{name}"
    h = nix_base32_encode(compress_hash(hashlib.sha256(inner.encode()).digest(), 20))
    return f"{store_dir}/{h}-{name}"


def parse_sri_or_hex(hash_val: str, hash_algo: str | None) -> tuple[str, str]:
    """Return (algo, lowercase_hex) from either SRI ('sha256-...') or hex + algo."""
    if "-" in hash_val and ":" not in hash_val:
        algo, b64 = hash_val.split("-", 1)
        return algo.lower(), base64.b64decode(b64).hex()
    if ":" in hash_val:
        algo, rest = hash_val.split(":", 1)
        return algo.lower(), rest.lower()
    if not hash_algo:
        raise ValueError(f"Missing hashAlgo for {hash_val}")
    algo = hash_algo.removeprefix("r:").lower()
    return algo, hash_val.lower()


def run(cmd: list[str], check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, text=True, capture_output=capture)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--store", required=True, help="Target Stage-2 store URI")
    ap.add_argument("--store-dir", default="/data/data/com.termux/files/nix/store")
    ap.add_argument("--drv", required=True, help="Instantiated Stage-2 .drv path")
    ap.add_argument("--nixpkgs", required=True, help="Host nixpkgs path (for make-minimal-bootstrap-sources fallback)")
    ap.add_argument(
        "--scope",
        choices=["critical", "all"],
        default="critical",
        help="critical = builtin:fetchurl + savannah + stage0-posix; all = all FODs",
    )
    args = ap.parse_args()

    res = run(
        [
            "nix",
            "--extra-experimental-features",
            "nix-command",
            "derivation",
            "show",
            "-r",
            "--store",
            args.store,
            f"{args.drv}^*",
        ]
    )
    raw = json.loads(res.stdout)
    drvs = raw.get("derivations", raw)

    # Collect unique FODs
    candidates = {}
    for _drv_key, drv in drvs.items():
        if not isinstance(drv, dict):
            continue
        out = drv.get("outputs", {}).get("out", {})
        if not isinstance(out, dict) or "hash" not in out:
            continue
        method = out.get("method", "flat")
        if method not in ("flat", "nar", "recursive"):
            continue
        builder = drv.get("builder", "")
        name = drv.get("name", "")
        env = drv.get("env", {})
        url = f"{env.get('url', '')} {env.get('urls', '')}"

        is_critical = (
            builder == "builtin:fetchurl"
            or "savannah" in url
            or "stage0-posix" in name
        )
        if args.scope == "critical" and not is_critical:
            continue

        try:
            algo, hash_hex = parse_sri_or_hex(out["hash"], out.get("hashAlgo"))
        except Exception:
            continue
        if algo not in ("sha256", "sha512", "sha1", "md5"):
            continue

        target_path = fixed_output_store_path(args.store_dir, name, method, algo, hash_hex)
        host_path = fixed_output_store_path("/nix/store", name, method, algo, hash_hex)
        candidates[target_path] = {
            "name": name,
            "method": method,
            "algo": algo,
            "hash_hex": hash_hex,
            "host_path": host_path,
            "target_path": target_path,
        }

    if not candidates:
        print("No FODs to seed.")
        return 0

    # Check which target paths already exist in the Stage-2 store
    check_res = run(
        ["nix-store", "--store", args.store, "--check-validity", "--print-invalid", *candidates.keys()],
        check=False,
    )
    invalid = {line.strip() for line in check_res.stdout.splitlines() if line.strip()}
    missing = [candidates[p] for p in candidates if p in invalid]

    print(f"Stage-2 FOD seed ({args.scope}): {len(candidates)} total, {len(missing)} missing from {args.store_dir}")
    if not missing:
        return 0

    # Batch-fetch missing FODs into host /nix/store from cache.nixos.org (fast CDN, avoids upstream 502s)
    host_paths = [m["host_path"] for m in missing]
    # Fetch in chunks of 40 so one uncached path doesn't block the batch
    for i in range(0, len(host_paths), 40):
        chunk = host_paths[i : i + 40]
        subprocess.run(
            ["nix-store", "--realise", "--ignore-unknown", *chunk],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    # Also ensure stage0-posix-*-source is built via make-minimal-bootstrap-sources if not fetched
    for m in missing:
        if "stage0-posix" in m["name"] and not os.path.exists(m["host_path"]):
            r = run(["nix-build", args.nixpkgs, "-A", "make-minimal-bootstrap-sources", "--no-out-link"], check=False)
            if r.returncode == 0 and r.stdout.strip():
                m["host_path"] = r.stdout.strip()

    seeded = 0
    skipped = 0
    with tempfile.TemporaryDirectory() as tmpdir:
        for m in missing:
            src = m["host_path"]
            if not os.path.exists(src):
                skipped += 1
                continue
            staged = os.path.join(tmpdir, m["name"])
            if os.path.exists(staged) or os.path.islink(staged):
                if os.path.isdir(staged) and not os.path.islink(staged):
                    shutil.rmtree(staged)
                else:
                    os.unlink(staged)
            if os.path.isdir(src) and not os.path.islink(src):
                shutil.copytree(src, staged, symlinks=True)
            else:
                shutil.copy2(src, staged, follow_symlinks=False)

            cmd = ["nix-store", "--store", args.store, "--add-fixed"]
            if m["method"] in ("nar", "recursive"):
                cmd.append("--recursive")
            cmd.extend([m["algo"], staged])

            add_res = run(cmd, check=False)
            if add_res.returncode == 0:
                actual = add_res.stdout.strip()
                if actual == m["target_path"]:
                    seeded += 1
                else:
                    print(f"  WARNING: path mismatch for {m['name']}: got {actual}, expected {m['target_path']}", file=sys.stderr)
                    skipped += 1
            else:
                skipped += 1

            # Keep tmpdir clean as we go
            if os.path.isdir(staged) and not os.path.islink(staged):
                subprocess.run(["chmod", "-R", "u+w", staged], check=False)
                shutil.rmtree(staged)
            elif os.path.exists(staged) or os.path.islink(staged):
                os.unlink(staged)

    print(f"Stage-2 FOD seed complete: seeded {seeded}/{len(missing)} from cache.nixos.org ({skipped} will fetch directly).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
