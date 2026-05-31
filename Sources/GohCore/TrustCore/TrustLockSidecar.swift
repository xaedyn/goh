/// The stable advisory-lock sidecar for `goh sync` / `goh verify`.
///
/// `goh sync` writes `gohfile.lock` atomically by renaming a `.tmp` sibling into
/// place, which installs a fresh inode each run. An advisory `flock` held on that
/// data file would therefore not provide mutual exclusion: a concurrent process
/// would open the *new* inode and acquire its own independent lock. The sidecar
/// `gohfile.lock.lock` is created once and never renamed or replaced, so its
/// inode is stable for the whole operation. Both commands `flock` the sidecar —
/// sync with `LOCK_EX`, verify with `LOCK_SH` — so they genuinely contend
/// (spec §9, exit 7). The sidecar is a goh-owned artifact and is never reported
/// as untracked or matched as a lock entry.
enum TrustLockSidecar {
    /// The sidecar file name, co-located with `gohfile.lock` in the lock dir.
    static let name = "gohfile.lock.lock"
}
