#!/usr/bin/env bash
# =============================================================================
#  PanxCZ Kernel - standalone build script (v2)
# =============================================================================
#  Device   : Infinix Note 30 (X6833B) - MediaTek Helio G99 (MT6789)
#  Platform : GKI 5.10 / android12-5.10 / KMI generation 9
#
#  BASE     : MillenniumOSS/android_kernel_common_android12-5.10 @ chihiro-rebase
#             (this is the "Chihiro" kernel tree - it already ships the same
#              perf family as Aetherium: REFLEX governor, ADIOS I/O scheduler,
#              DAMON, PELT halflife 12, plus its own large backport set)
#
#  ROOT     : BakaSU  (https://github.com/Baka-SU/BakaSU) - the renamed
#             ReSukiSU fork, with CONFIG_KSU_MULTI_MANAGER_SUPPORT
#  HIDING   : SUSFS   (https://gitlab.com/simonpunk/susfs4ksu, gki-android12-5.10)
#
#  PERF     : BBRv3 congestion control, ported from Aetherium
#             (kaminarich/GKI-Kernel @ aetherium).
#
#             NOTE: Aetherium's BBRv3 is a single kitchen-sink commit that ALSO
#             bundles a whole SUSFS implementation (fs/*, security/selinux/*,
#             kernel/*, mm/*), which would collide with the official SUSFS
#             patch. So we ship a pre-resolved, BBRv3-ONLY patch instead:
#                 patches/bbrv3-chihiro.patch
#             generated against chihiro-rebase. It keeps Chihiro's newer
#             mainline-style TCP PLB (net->ipv4.sysctl_tcp_plb_*), adds the
#             BBRv3 driver, adds struct bbr3, and maps BBRv3's min_tso_segs()
#             onto Chihiro's older ca_ops->tso_segs(sk, mss_now) hook.
#             Verified: net/ipv4/tcp_bbr3.o compiles clean on chihiro-rebase.
#
#  CREDIT   : All core kernel work belongs to the MillenniumOSS (Chihiro),
#             Aetherium (kaminarich), BakaSU, SUSFS and upstream Linux/AOSP
#             projects. PanxCZ is a rebrand + integration layer only.
#
#  Usage (Ubuntu 22.04, as root):
#     VARIANT=A-full-allin bash build-panxcz.sh
#
#  Env knobs:
#     KERNEL_NAME, KERNEL_RELEASE, VARIANT (A-full-allin|B-susfs-hiding|
#     C-charging-gaming), LTO_MODE, BASE_REPO, BASE_BRANCH, BASE_REMOTE_NAME,
#     BBRV3 (auto|yes|no), SUSFS_BRANCH, BAKASU_REF, WORKDIR, BUILD_NUM
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------- configuration
KERNEL_NAME="${KERNEL_NAME:-PanxCZ}"
KERNEL_RELEASE="${KERNEL_RELEASE:-3.0}"
KERNEL_CODENAME="${KERNEL_CODENAME:-Chihiro}"
DEVICE_MODEL="Infinix Note 30 (X6833B)"
DEVICE_PLATFORM="MediaTek Helio G99 (MT6789) - GKI 5.10 android12 / KMI gen 9"

# --- base kernel -------------------------------------------------------------
# The *live* chihiro tree. There are two MillenniumOSS kernel repos and only
# this one is current:
#   android_kernel_common_millennium_android12-5.10  chihiro-main  5.10.269  <- here
#   android_kernel_common_android12-5.10             chihiro-*     5.10.2xx  (legacy)
# chihiro-main @ 2a6271bf1f5b is the exact source of the kernel this device
# runs: the "KagamiChihiro" prebuilt that MillenniumOSS ships in
# android_device_millennium_common-kernel (chihiro/Image.gz) reports
#   5.10.269-KagamiChihiro-MillenniumTeam-android12-9+ ... Sat Oct 3 22:58:56 UTC 2026
# which is that commit's timestamp. Building the legacy repo was the whole
# reason v10/v11 bootlooped.
BASE_REPO="${BASE_REPO:-https://github.com/MillenniumOSS/android_kernel_common_millennium_android12-5.10.git}"
BASE_BRANCH="${BASE_BRANCH:-chihiro-main}"
BASE_NAME="${BASE_NAME:-millennium-chihiro}"

# --- Aetherium: source of perf patches the base lacks ------------------------
AETHERIUM_REPO="${AETHERIUM_REPO:-https://github.com/kaminarich/GKI-Kernel.git}"
AETHERIUM_BRANCH="${AETHERIUM_BRANCH:-aetherium}"
BBRV3="${BBRV3:-yes}"           # yes | auto | no
# BBRv3 is shipped as a resolved patch because the upstream commit cannot be
# cherry-picked onto chihiro-rebase (11 conflicting files) and bundles SUSFS.
BBRV3_PATCH_URL="${BBRV3_PATCH_URL:-https://gitlab.com/api/v4/projects/panxcz-group%2Fpanxcz-backup%2Fkernel-src/repository/files/patches%2Fbbrv3-chihiro.patch/raw?ref=main}"
BBRV3_PATCH="${BBRV3_PATCH:-patches/bbrv3-chihiro.patch}"

# --- root solution -----------------------------------------------------------
BAKASU_REPO="${BAKASU_REPO:-https://github.com/Baka-SU/BakaSU.git}"
BAKASU_REF="${BAKASU_REF:-main}"

# --- hiding ------------------------------------------------------------------
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android12-5.10}"

# --- build -------------------------------------------------------------------
AOSP_MANIFEST="${AOSP_MANIFEST:-https://android.googlesource.com/kernel/manifest}"
AOSP_BRANCH="${AOSP_BRANCH:-common-android12-5.10}"
VARIANT="${VARIANT:-A-full-allin}"
LTO_MODE="${LTO_MODE:-thin}"
# Root/hiding are separately switchable so the two can be bisected against each
# other. v14 (both on) boots *recovery* perfectly but Android never comes up, so
# the suspect set is small and this is how we split it in one build each:
#   ROOT_KSU=no SUSFS=no  -> control: should be the stock kernel, proves the
#                            tree + pipeline; no root, no hiding.
#   ROOT_KSU=yes SUSFS=no -> is it SUSFS' path/stat/mount hooks (which Android
#                            hammers and recovery barely touches)?
ROOT_KSU="${ROOT_KSU:-yes}"   # yes | no
SUSFS="${SUSFS:-yes}"         # yes | no
# Wipe out/android12-5.10/common before compiling. The VPS keeps ONE tree for
# many builds, and `git clean -fdx` only cleans the *source* tree - out/ is left
# alone. Reusing it across a changed base or a changed .config mixes objects and
# generated headers from two different kernels on the same link line, which is
# not a supported configuration and is a plausible source of a kernel that
# hangs. Default is the safe one; CLEAN_OUT=no is an explicit speed opt-in.
CLEAN_OUT="${CLEAN_OUT:-yes}"
# 5.10.269 base: chihiro-lnx-stable merged with AOSP android12-5.10-lts.
# chihiro-main is already 5.10.269, so merging AOSP LTS onto a legacy branch is
# no longer needed (and the hand-resolved merge was a bootloop suspect).
LTS_MERGE="${LTS_MERGE:-no}"
LTS_BASE_BRANCH="${LTS_BASE_BRANCH:-panxcz-base-5.10.269}"
LTS_SOURCE_BRANCH="${LTS_SOURCE_BRANCH:-chihiro-lnx-stable}"
WORKDIR="${WORKDIR:-/opt/panxcz}"
BUILD_NUM="${BUILD_NUM:-$(date -u +%Y%m%d%H%M)}"
BUILD_N="${BUILD_N:-1}"      # trailing counter in the Aetherium-style zip name
SWAP_GB="${SWAP_GB:-8}"

EXTRA="-${KERNEL_NAME}-${KERNEL_RELEASE}.${BUILD_NUM}"
ZIPNAME="${KERNEL_NAME}-${KERNEL_RELEASE}.${BUILD_NUM}-AnyKernel3.zip"
# Overridable so bisect runs can keep their artifacts apart (the zip name does
# not encode ROOT_KSU/SUSFS, so a shared OUTDIR silently overwrites the previous
# candidate's Image).
OUTDIR="${OUTDIR:-${WORKDIR}/out-artifacts}"
GKI="${WORKDIR}/gki"
COMMON="${GKI}/common"

# Resolve this script's own directory NOW, while the CWD is still the caller's.
# Later steps cd into the kernel tree, and BASH_SOURCE is a relative path there,
# so resolving it lazily (after a cd) silently yields an empty string.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

log()  { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*"; exit 1; }

log "PanxCZ build v2 start $(date -u)"
cat <<EOF
  KERNEL_NAME   : ${KERNEL_NAME} ${KERNEL_RELEASE}
  BASE          : ${BASE_REPO} (${BASE_BRANCH})
  ROOT          : BakaSU ${BAKASU_REF}
  HIDING        : SUSFS ${SUSFS_BRANCH}
  PERF (ported) : BBRv3 (${BBRV3}) from Aetherium
  VARIANT       : ${VARIANT}   LTO: ${LTO_MODE}
  Workdir       : ${WORKDIR}
  Version extra : ${EXTRA}
EOF

# ---------------------------------------------------------------- 1. swap
log "Step 1/12 - swap + workspace"
mkdir -p "${WORKDIR}"
if [ "${SWAP_GB}" -gt 0 ] && ! swapon --show | grep -q "${WORKDIR}/swapfile"; then
  [ -f "${WORKDIR}/swapfile" ] || { fallocate -l "${SWAP_GB}G" "${WORKDIR}/swapfile" || dd if=/dev/zero of="${WORKDIR}/swapfile" bs=1M count=$((SWAP_GB*1024)); chmod 600 "${WORKDIR}/swapfile"; }
  mkswap "${WORKDIR}/swapfile" >/dev/null
  swapon "${WORKDIR}/swapfile"
fi
free -h | head -3

# ---------------------------------------------------------------- 2. deps
log "Step 2/12 - dependencies"
export DEBIAN_FRONTEND=noninteractive
# A fresh VPS often has unattended-upgrades holding the dpkg lock; wait for it
# instead of failing the whole build (this cost one build cycle already).
APT_LOCK="-o DPkg::Lock::Timeout=600"
apt-get $APT_LOCK update -qq
apt-get $APT_LOCK install -y -qq \
  git curl build-essential bc bison flex libssl-dev libelf-dev \
  python3 python3-pip unzip zip rsync libncurses-dev lld cpio kmod ca-certificates
command -v repo >/dev/null 2>&1 || { curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo; chmod a+x /usr/local/bin/repo; }
git config --global user.name  "PanxCZ Builder"
git config --global user.email "builder@panxcz.local"
git config --global advice.detachedHead false

# ---------------------------------------------------------------- 3. AOSP build tooling
log "Step 3/12 - AOSP manifest (build/ + prebuilts)"
mkdir -p "${GKI}"
cd "${GKI}"
# Only build/ and the prebuilts are needed from the manifest - common/ gets
# replaced in the next step. A common/ that was replaced on a previous run
# makes repo's checkout fail, so put it back on the manifest revision first.
# A sync error is not fatal as long as build/ and prebuilts-master/ exist.
if [ -d "${COMMON}/.git" ]; then
  git -C "${COMMON}" checkout -f -q "${AOSP_BRANCH}" 2>/dev/null \
    || git -C "${COMMON}" checkout -f -q . 2>/dev/null || true
  git -C "${COMMON}" clean -fdq 2>/dev/null || true
fi
if [ -d .repo ]; then
  repo sync -c --no-tags --no-clone-bundle --optimized-fetch -j"$(nproc)" \
    || { warn "repo sync failed - retrying with --force-sync"; \
         repo sync -c --no-tags --no-clone-bundle --optimized-fetch --force-sync -j"$(nproc)" \
           || warn "repo sync still reporting errors (common/ is replaced anyway)"; }
else
  repo init -u "${AOSP_MANIFEST}" -b "${AOSP_BRANCH}" --depth=1
  repo sync -c --no-tags --no-clone-bundle --optimized-fetch -j"$(nproc)" \
    || warn "repo sync reported errors"
fi
[ -d build ] || die "AOSP build/ tooling missing after sync"
[ -d prebuilts-master ] || die "AOSP prebuilts missing after sync"
echo "OK: build tooling + prebuilts present"

# ---------------------------------------------------------------- 4. base swap
# Blobless fetch keeps full commit history (needed for cherry-picks) while
# downloading blobs lazily; the working tree is still complete after checkout.
log "Step 4/12 - swap common/ with ${BASE_NAME}"
cd "${COMMON}"

# Ensure the base remote exists and points to the correct repository.
if git remote | grep -qx "$BASE_NAME"; then
    git remote set-url "$BASE_NAME" "$BASE_REPO"
else
    git remote add "$BASE_NAME" "$BASE_REPO"
fi

# First, try fetching the requested branch or commit.
log "Fetching base ref: ${BASE_BRANCH}"

git fetch --no-tags --filter=blob:none "$BASE_NAME" "$BASE_BRANCH" || true

# A resolvable commit is not enough; its tree must also be available.
if ! git cat-file -e "${BASE_BRANCH}^{tree}" 2>/dev/null; then
    log "Base tree missing; fetching remote branches"

    git fetch --no-tags --filter=blob:none "$BASE_NAME" \
        '+refs/heads/*:refs/remotes/'"${BASE_NAME}"'/*' \
        || die "Failed to fetch branches from ${BASE_REPO}"
fi

# Verify the actual commit tree before checking it out.
if ! git cat-file -e "${BASE_BRANCH}^{tree}" 2>/dev/null; then
    die "Base commit/tree unavailable: ${BASE_BRANCH}"
fi

git checkout -f "${BASE_BRANCH}" \
    || die "Failed to checkout base ref: ${BASE_BRANCH}"

git checkout -B panxcz-build
git clean -fdx
echo -n "base LTS level: "; awk '/^(VERSION|PATCHLEVEL|SUBLEVEL) =/{printf "%s.",$3}END{print ""}' Makefile
echo "--- HEAD ---"; git log --oneline -3
echo "--- base sanity ---"
grep -q "CONFIG_CPU_FREQ_GOV_REFLEX=y" arch/arm64/configs/gki_defconfig && echo "OK: Chihiro base has REFLEX governor" || warn "REFLEX not found"
grep -q "CONFIG_MQ_IOSCHED_ADIOS=y"     arch/arm64/configs/gki_defconfig && echo "OK: Chihiro base has ADIOS I/O"     || warn "ADIOS not found"

# ---------------------------------------------------------------- 5. perf port
log "Step 5/12 - port BBRv3 (${BBRV3})"
if [ "${BBRV3}" != "no" ]; then
  # Locate the patch. Prefer the copy shipped next to this script, referenced by
  # ABSOLUTE path (the CWD here is the kernel tree, which has no patches/ dir).
  # Fall back to the backup repo, which is private and so needs a token.
  if [ ! -f "${BBRV3_PATCH}" ] && [ -f "${SCRIPT_DIR}/../patches/bbrv3-chihiro.patch" ]; then
    BBRV3_PATCH="${SCRIPT_DIR}/../patches/bbrv3-chihiro.patch"
  fi
  if [ ! -f "${BBRV3_PATCH}" ]; then
    warn "BBRv3 patch not found alongside the script"
    BBRV3_PATCH="${WORKDIR}/patches/bbrv3-chihiro.patch"
    mkdir -p "$(dirname "${BBRV3_PATCH}")"
    if [ -n "${GITLAB_TOKEN:-}" ]; then
      echo "fetching from the backup repo..."
      curl -fsSL --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${BBRV3_PATCH_URL}" -o "${BBRV3_PATCH}" || warn "authenticated download failed"
    else
      warn "GITLAB_TOKEN not set: the backup repo is private, so the download will fail"
    fi
  fi
  [ -f "${BBRV3_PATCH}" ] || die "BBRv3 patch unavailable"
  echo "using patch: ${BBRV3_PATCH}"

  if git apply --check "${BBRV3_PATCH}" 2>/dev/null; then
    git apply "${BBRV3_PATCH}"
    echo "OK: BBRv3 patch applied cleanly"
  else
    warn "plain apply failed - retrying with 3-way merge"
    set +e
    git apply --3way "${BBRV3_PATCH}" >/tmp/bbrv3.log 2>&1
    RC=$?
    set -e
    if [ "${RC}" -ne 0 ]; then
      tail -20 /tmp/bbrv3.log 2>/dev/null || true
      # 3-way may leave conflict markers in the tree; drop the whole footprint
      git checkout -- $(git apply --numstat "${BBRV3_PATCH}" 2>/dev/null | awk 'NF==3{print $3}') 2>/dev/null || true
      rm -f net/ipv4/tcp_bbr3.c
      if [ "${BBRV3}" = "yes" ]; then die "BBRv3 was required but could not be applied"; fi
      warn "continuing WITHOUT BBRv3"
    else
      echo "OK: BBRv3 patch applied with 3-way merge"
    fi
  fi
else
  echo "skipped (BBRV3=no)"
fi

# ---------------------------------------------------------------- 6. toolchain
# The base asks for clang-r416183b which the manifest also ships; keep an
# auto-detect just in case the pin changes.
log "Step 6/12 - clang path"
CLANGROOT="../prebuilts-master/clang/host/linux-x86"
ls -d "${CLANGROOT}"/clang-*/ 2>/dev/null || warn "no clang dirs under ${CLANGROOT}"
CPD="$(grep '^CLANG_PREBUILT_BIN=' build.config.common | cut -d= -f2 || true)"
if [ -n "${CPD}" ] && [ -x "../${CPD}/clang" ]; then
  echo "OK: clang present at ../${CPD}/clang"
else
  DET="$(ls -d "${CLANGROOT}"/clang-r*/ 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "${DET}" ] || die "no clang prebuilt found"
  NAME="$(basename "${DET}")"
  echo "Auto-detected clang: ${NAME}"
  sed -i "s|^CLANG_PREBUILT_BIN=.*|CLANG_PREBUILT_BIN=prebuilts-master/clang/host/linux-x86/${NAME}/bin|" build.config.common
  CPD="$(grep '^CLANG_PREBUILT_BIN=' build.config.common | cut -d= -f2)"
  [ -x "../${CPD}/clang" ] || die "clang still not found at ../${CPD}/clang"
  echo "OK: clang -> ../${CPD}/clang"
fi

# ---------------------------------------------------------------- 7. rebrand
log "Step 7/12 - rebrand to ${KERNEL_NAME}"
sed -i "s|^EXTRAVERSION *=.*|EXTRAVERSION = ${EXTRA}|" Makefile
grep '^EXTRAVERSION' Makefile
: > scripts/setlocalversion
chmod +x scripts/setlocalversion
BANNER="${KERNEL_NAME} kernel - based on ${BASE_NAME} (credit: MillenniumOSS) - Aetherium perf - ${DEVICE_MODEL}"
if grep -q 'pr_notice("%s", linux_banner);' init/main.c; then
  sed -i "s|pr_notice(\"%s\", linux_banner);|pr_notice(\"%s\", linux_banner);\n\tpr_notice(\"${BANNER}\\\\n\");|" init/main.c
  grep -n "PanxCZ kernel - based on" init/main.c || true
fi
# allow non-GKI configs (KSU/SUSFS)
sed -i 's|^POST_DEFCONFIG_CMDS=.*|POST_DEFCONFIG_CMDS=""|' build.config.gki
cat build.config.gki

# ---------------------------------------------------------------- 8. root
if [ "${VARIANT}" != "C-charging-gaming" ] && [ "${ROOT_KSU}" != "no" ]; then
  log "Step 8/12 - integrate BakaSU"
  curl -fsSL "https://raw.githubusercontent.com/Baka-SU/BakaSU/${BAKASU_REF}/kernel/setup.sh" > /tmp/bakasu-setup.sh
  # `git clean -fdx` never removes a directory that contains its own .git, so a
  # KernelSU/ left behind by an earlier run survives - and BakaSU's setup.sh
  # then only does `git pull` on it. That silently kept building *SukiSU-Ultra*
  # instead of BakaSU (caught in v10). Only keep the tree if it really is BakaSU.
  if [ -d KernelSU/.git ] && \
     ! git -C KernelSU remote get-url origin 2>/dev/null | grep -qi 'Baka-SU/BakaSU'; then
    warn "KernelSU/ is not BakaSU ($(git -C KernelSU remote get-url origin 2>/dev/null)) - re-cloning"
    rm -rf KernelSU
  fi
  sh /tmp/bakasu-setup.sh
  # BakaSU requires a real .git next to the kernel/ dir - never strip it.
  [ -d KernelSU/.git ] || die "BakaSU .git missing (Kbuild requires it; it errors out otherwise)"
  git -C KernelSU remote get-url origin 2>/dev/null | grep -qi 'Baka-SU/BakaSU' \
    || die "KernelSU origin is not BakaSU - refusing to build the wrong root solution"
  echo "OK: root solution = BakaSU $(git -C KernelSU rev-parse --short HEAD)"
  grep -qs '^config KSU_SUSFS$' KernelSU/kernel/Kconfig \
    || die "this BakaSU tree has no SUSFS support (no CONFIG_KSU_SUSFS in kernel/Kconfig)"
  test -L drivers/kernelsu && echo "OK: drivers/kernelsu symlink present"
  grep -n kernelsu drivers/Makefile || true
  grep -n kernelsu drivers/Kconfig  || true
  if [ -f "${SCRIPT_DIR}/fix-bakasu-version.sh" ]; then
    bash "${SCRIPT_DIR}/fix-bakasu-version.sh" "$PWD" || true
  fi
else
  log "Step 8/12 - skipped (variant ${VARIANT}, ROOT_KSU=${ROOT_KSU})"
fi

# ---------------------------------------------------------------- 9. susfs
if [ "${VARIANT}" != "C-charging-gaming" ] && [ "${SUSFS}" != "no" ]; then
  log "Step 9/12 - integrate SUSFS (${SUSFS_BRANCH})"
  # BakaSU ships SUSFS as a first-class *hook method*: CONFIG_KSU_SUSFS selects
  # tools/inline_hook_check.mk + tools/susfs_compat.mk, calls susfs_init() from
  # core/init.c, and its Kbuild hard-errors
  #   "You should integrate susfs in your kernel."
  # unless fs/susfs.c exists AND every ksu_handle_* kernel-side hook is present.
  #
  # So the only thing to add here is simonpunk's kernel-side patch. The
  # KernelSU-side patch (kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch)
  # must NOT be applied: it is generated as "current KernelSU -> SUSFS tree on an
  # OLDER KernelSU", so it also reverts the current hook infrastructure
  # (ksu_late_loaded, hook/lsm_hook.o, hook/syscall_hook_manager.o,
  # infra/symbol_resolver.o, hook/arm64/*) and rewrites init.c back to the
  # pre-hook-manager design. That is what broke v9 with
  #   "assigning to 'int' from incompatible type 'void'" in sucompat.c.
  rm -rf /tmp/susfs
  git clone --depth 1 -b "${SUSFS_BRANCH}" "${SUSFS_REPO}" /tmp/susfs
  rm -rf /tmp/susfs/.git
  cp -rf /tmp/susfs/kernel_patches/fs/* fs/
  cp -rf /tmp/susfs/kernel_patches/include/linux/* include/linux/
  patch -p1 --forward --no-backup-if-mismatch \
    < /tmp/susfs/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch \
    || die "the SUSFS kernel-side patch left rejects on ${BASE_NAME}@${BASE_BRANCH}"
  ls -l fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h \
    || die "SUSFS kernel sources are missing after the patch"

  # BakaSU's own build check (tools/inline_hook_check.mk) looks for exactly
  # these, and errors out at build time if any is missing. Fail here instead, so
  # the message points at the patch rather than at a four-minute compile.
  for h in ksu_handle_setresuid:kernel/sys.c ksu_handle_execveat:fs/exec.c \
           ksu_handle_faccessat:fs/open.c ksu_handle_sys_read:fs/read_write.c \
           ksu_handle_stat:fs/stat.c ksu_handle_sys_reboot:kernel/reboot.c \
           ksu_handle_input_handle_event:drivers/input/input.c; do
    sym="${h%%:*}"; file="${h##*:}"
    grep -q "${sym}" "${file}" \
      || die "SUSFS kernel-side hook ${sym} missing from ${file} - BakaSU would refuse to build"
  done
  echo "OK: SUSFS kernel-side hooks verified"
else
  log "Step 9/12 - skipped (variant ${VARIANT}, SUSFS=${SUSFS})"
fi

# ---------------------------------------------------------------- 10. defconfig
log "Step 10/12 - inject defconfig"
DEFCONFIG=arch/arm64/configs/gki_defconfig
if [ "${VARIANT}" != "C-charging-gaming" ] && [ "${ROOT_KSU}" != "no" ]; then
  printf '%s\n' \
    "" \
    "# ---- PanxCZ: root ----" \
    "CONFIG_KSU=y" \
    "CONFIG_KSU_MULTI_MANAGER_SUPPORT=y" \
    >> "${DEFCONFIG}"
  if [ "${SUSFS}" != "no" ]; then
    # KernelSU hooking method: SUSFS' inline hook (BakaSU's default is
    # CONFIG_KSU_TRACEPOINT_HOOK, so the choice has to be switched explicitly).
    printf '%s\n' \
      "CONFIG_KSU_SUSFS=y" \
      "CONFIG_KSU_SUSFS_SUS_PATH=y" \
      "CONFIG_KSU_SUSFS_SUS_MOUNT=y" \
      "CONFIG_KSU_SUSFS_SUS_KSTAT=y" \
      "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" \
      "CONFIG_KSU_SUSFS_ENABLE_LOG=y" \
      "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" \
      "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" \
      "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" \
      "CONFIG_KSU_SUSFS_SUS_MAP=y" \
      "# CONFIG_KSU_TRACEPOINT_HOOK is not set" \
      "# CONFIG_KSU_MANUAL_HOOK is not set" \
      >> "${DEFCONFIG}"
    # (AUTO_ADD_SUS_*, SUS_SU and TRY_UMOUNT were dropped from SUSFS' Kconfig a
    # while ago; listing them only produced silent no-ops.)
    # CONFIG_KSU_SUSFS depends on THREAD_INFO_IN_TASK.
    grep -q '^CONFIG_THREAD_INFO_IN_TASK=y' "${DEFCONFIG}" \
      || printf '%s\n' 'CONFIG_THREAD_INFO_IN_TASK=y' >> "${DEFCONFIG}"
  fi
fi
if [ "${VARIANT}" != "B-susfs-hiding" ]; then
  printf '%s\n' \
    "" \
    "# ---- PanxCZ: responsiveness / gaming (Helio G99) ----" \
    "# HZ stays 250: that is what the stock PanxCZ base kernel (and every" \
    "# proven-working build for this device) runs, and HZ is baked into the" \
    "# jiffies conversions the vendor modules use, so it is not free to change." \
    "CONFIG_HZ_250=y" \
    "CONFIG_HZ=250" \
    "# CONFIG_HZ_300 is not set" \
    "CONFIG_NET_SCH_FQ=y" \
    >> "${DEFCONFIG}"
  # BBRv3 is compiled in, but deliberately NOT the default congestion control.
  #
  # v10 shipped CONFIG_DEFAULT_TCP_CONG="bbr3", so every TCP socket selected
  # bbr3 during boot, and the port Oopses in bbr3_main ~48s into a boot:
  #
  #   Unable to handle kernel NULL pointer dereference at virtual address 0000000000000022
  #   pc : bbr3_main+0xec/0xc7c     (tcp_ack -> bbr3_main)
  #   Internal error: Oops: 96000006 [#2] PREEMPT SMP
  #
  # mrdump then reboots the phone, which looks exactly like a bootloop. The
  # stock base kernel runs default "westwood", so that is pinned back here and
  # bbr3 stays available but opt-in:
  #   sysctl -w net.ipv4.tcp_congestion_control=bbr3
  #
  # NOTE: the Kconfig symbol is written as `config TCP_CONG_BBR3`, NOT
  # `CONFIG_TCP_CONG_BBR3` - grepping for the CONFIG_ form silently never
  # matched and left BBRv3 disabled. BBR3 also depends on TCP_CONG_ADVANCED.
  if grep -qE '^[[:space:]]*config[[:space:]]+TCP_CONG_BBR3' net/ipv4/Kconfig 2>/dev/null; then
    printf '%s\n' \
      "CONFIG_TCP_CONG_ADVANCED=y" \
      "CONFIG_TCP_CONG_BBR3=y" \
      "# CONFIG_DEFAULT_BBR3 is not set" \
      "# CONFIG_DEFAULT_BBR is not set" \
      "CONFIG_DEFAULT_WESTWOOD=y" \
      'CONFIG_DEFAULT_TCP_CONG="westwood"' \
      >> "${DEFCONFIG}"
    echo "OK: BBRv3 compiled in but NOT default (default = westwood, as the stock base)"
  else
    warn "BBRv3 Kconfig entry not found - base default congestion control kept"
  fi
fi
# Chihiro's gki_defconfig ships PID_NS, USER_NS, IPC_NS and the devices cgroup
# disabled (SUSFS/BakaSU builds usually drop these to shrink what an
# unprivileged sandbox escape could reach). We need them for proper container
# support (Docker/runc, proot-distro --isolated, etc) under root - appended
# last so these lines win over the "is not set" ones already in the file.
# IPC_NS depends on SYSVIPC || POSIX_MQUEUE and the base has both off, so
# POSIX_MQUEUE (the smaller struct footprint) is enabled to keep IPC_NS from
# being dropped silently. xt_addrtype is what Docker's default bridge uses.
printf '%s\n' \
  "" \
  "# ---- PanxCZ: namespaces + devices cgroup (container support) ----" \
  "CONFIG_NAMESPACES=y" \
  "CONFIG_PID_NS=y" \
  "CONFIG_USER_NS=y" \
  "CONFIG_POSIX_MQUEUE=y" \
  "CONFIG_IPC_NS=y" \
  "CONFIG_UTS_NS=y" \
  "CONFIG_NET_NS=y" \
  "CONFIG_CGROUPS=y" \
  "CONFIG_CGROUP_DEVICE=y" \
  "CONFIG_CGROUP_FREEZER=y" \
  "CONFIG_CGROUP_PIDS=y" \
  "CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y" \
  >> "${DEFCONFIG}"
echo "OK: namespaces + devices cgroup appended"
tail -40 "${DEFCONFIG}"

# ---------------------------------------------------------------- 11. build
log "Step 11/12 - build (LTO=${LTO_MODE}, jobs=$(nproc), CLEAN_OUT=${CLEAN_OUT})"
cd "${GKI}"
if [ "${CLEAN_OUT}" = "yes" ]; then
  OUT_COMMON="${GKI}/out/android12-5.10/common"
  if [ -d "${OUT_COMMON}" ]; then
    log "Step 11a/12 - wiping stale build output (${OUT_COMMON})"
    rm -rf "${OUT_COMMON}"
  fi
  echo "OK: clean build from scratch"
fi
LTO="${LTO_MODE}" BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh

# ---------------------------------------------------------------- 12. package
log "Step 12/12 - package artifacts"
mkdir -p "${OUTDIR}"
IMAGE="$(find "${GKI}/out" -type f -name Image | head -n1)"
[ -n "${IMAGE}" ] || die "Image not found"
cp -f "${IMAGE}" "${OUTDIR}/Image"
KVER="$(grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL) = ' "${COMMON}/Makefile" | awk '{print $3}' | paste -sd.)"
echo "Kernel version: ${KVER}${EXTRA}"

# --- verify the ported features really made it into the binary --------------
# Use System.map, not `strings`: a silently-disabled Kconfig symbol is exactly
# the failure this catches and is invisible in a config readback.
SYSMAP="$(find "${GKI}/out" -name System.map | head -n1)"
if [ -n "${SYSMAP}" ]; then
  SYSMAP_FAIL=""
  # Only assert the features this run actually asked for - a bisect build that
  # deliberately omits SUSFS must not be failed for not containing it.
  PROBES=""
  [ "${SUSFS}" = "no" ] || PROBES="${PROBES} susfs"
  [ "${BBRV3}" = "no" ] || PROBES="${PROBES} bbr3"
  for probe in ${PROBES}; do
    n="$(grep -ic "${probe}" "${SYSMAP}" 2>/dev/null || echo 0)"
    if [ "${n}" -gt 0 ]; then
      echo "OK: ${n} '${probe}' symbols in System.map"
    else
      # A silently-disabled Kconfig symbol is exactly the failure this catches
      # (that is how v5 shipped with no hiding at all). Refuse to ship it.
      warn "'${probe}' symbols MISSING from System.map - feature was NOT built"
      SYSMAP_FAIL="${SYSMAP_FAIL} ${probe}"
    fi
  done
  [ -z "${SYSMAP_FAIL}" ] || die "build produced no${SYSMAP_FAIL} symbols - refusing to publish"
fi
OCFG="${GKI}/out/android12-5.10/common/.config"
CFG_FAIL=""
CFG_WANT=""
[ "${ROOT_KSU}" = "no" ] || CFG_WANT="${CFG_WANT} CONFIG_KSU"
[ "${SUSFS}" = "no" ] || CFG_WANT="${CFG_WANT} CONFIG_KSU_SUSFS CONFIG_KSU_SUSFS_SUS_PATH CONFIG_KSU_SUSFS_SUS_MOUNT"
CFG_WANT="${CFG_WANT} CONFIG_PID_NS CONFIG_USER_NS CONFIG_IPC_NS CONFIG_NET_NS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS CONFIG_POSIX_MQUEUE CONFIG_NETFILTER_XT_MATCH_ADDRTYPE"
for sym in ${CFG_WANT}; do
  if grep -q "^${sym}=y" "${OCFG}" 2>/dev/null; then
    echo "OK: ${sym}=y in .config"
  else
    warn "${sym} not set in the generated .config"
    CFG_FAIL="${CFG_FAIL} ${sym}"
  fi
done
[ -z "${CFG_FAIL}" ] || die "root/hiding config lost:${CFG_FAIL}"
if [ "${ROOT_KSU}" = "no" ] || [ "${SUSFS}" = "no" ]; then
  echo "NOTE: bisect build - ROOT_KSU=${ROOT_KSU} SUSFS=${SUSFS}"
fi
grep -q '^CONFIG_DEFAULT_TCP_CONG="bbr3"' "${OCFG}" 2>/dev/null \
  && echo "OK: BBRv3 is the default congestion control" \
  || warn "BBRv3 is not the default congestion control"

# --- drift check against the kernel this device actually boots ---------------
# The reference is the config embedded in the "KagamiChihiro" kernel that
# MillenniumOSS ships for exactly this device (android_device_millennium_common-kernel,
# chihiro/Image.gz, 5.10.269) - i.e. the config *known to boot here*. Diffing
# against it is what catches the regressions that cost v10/v11: those shipped
# CONFIG_HZ=300 and CONFIG_DEFAULT_TCP_CONG="bbr3", and nothing flagged them,
# because both are perfectly valid Kconfig values.
REFCFG="${SCRIPT_DIR}/../patches/config-reference-kagamichihiro-5.10.269.txt"
if [ -f "${REFCFG}" ] && command -v python3 >/dev/null 2>&1; then
  log "Step 12b/12 - drift check vs the known-good device config"
  ACTUAL=/tmp/panxcz-actual-config.txt
  if python3 "${SCRIPT_DIR}/extract-kernel-config.py" "${IMAGE}" -o "${ACTUAL}" >/dev/null 2>&1 \
     && [ -s "${ACTUAL}" ]; then
    # Expected additions and build-machine paths are not drift. Comments are
    # skipped - the version banner always differs.
    # `^[<>] #` drops comment banners, `^[<>] *$` drops the blank separator
    # lines that come with the extra KernelSU/SUSFS config sections.
    # CONFIG_PID_NS/USER_NS/IPC_NS/CGROUP_DEVICE/CGROUP_PIDS are deliberate
    # PanxCZ additions (container support), not drift - see step 10.
    DRIFT="$(diff <(sort "${REFCFG}") <(sort "${ACTUAL}") | grep -E '^[<>]' \
             | grep -vE '^[<>] (CONFIG_KSU|# CONFIG_KSU|CONFIG_UNUSED_KSYMS_WHITELIST)' \
             | grep -vE '^[<>] #? ?CONFIG_(PID_NS|USER_NS|IPC_NS|CGROUP_DEVICE|CGROUP_PIDS|POSIX_MQUEUE|NETFILTER_XT_MATCH_ADDRTYPE)([= ]|$)' \
             | grep -vE '^[<>] #' | grep -vE '^[<>][[:space:]]*$' || true)"
    if [ -z "${DRIFT}" ]; then
      echo "OK: config matches the known-good device kernel (modulo KSU/SUSFS)"
    else
      warn "config drift vs the known-good device kernel:"
      printf '%s\n' "${DRIFT}" | sed 's/^/    /'
    fi
  else
    warn "could not extract the config from ${IMAGE} - drift check skipped"
  fi
fi

# --- AnyKernel3 -------------------------------------------------------------
# Packaging lives in its own script (scripts/make-anykernel3.sh) so the zip can
# be regenerated from an existing Image without re-running a 40-minute build.
# It rewrites anykernel.sh for this device (upstream's still targets
# maguro/toro/tuna with an omap BLOCK path; here we need BLOCK=boot +
# IS_SLOT_DEVICE=1) and puts the zip contents at the zip ROOT instead of
# nesting them under anykernel/ - the latter is what made v10 unflashable.
AK_SCRIPT="${SCRIPT_DIR}/make-anykernel3.sh"
[ -f "${AK_SCRIPT}" ] || die "${AK_SCRIPT} is missing from the payload"
AK_IMAGE="${IMAGE}" AK_KVER="${KVER}" AK_OUTDIR="${OUTDIR}" AK_WORKDIR="${WORKDIR}" \
AK_NAME="${KERNEL_NAME}" AK_RELEASE="${KERNEL_RELEASE}" AK_VARIANT="${VARIANT}" \
AK_CODENAME="${KERNEL_CODENAME}" AK_BASE_NAME="${BASE_NAME}" \
AK_BUILD_N="${BUILD_N}" AK_DEVICE_MODEL="${DEVICE_MODEL}" \
AK_DEVICE_PLATFORM="${DEVICE_PLATFORM}" \
  bash "${AK_SCRIPT}" || die "AnyKernel3 packaging failed"
ZIPNAME="$(cat "${OUTDIR}/.zipname")"
[ -f "${OUTDIR}/${ZIPNAME}" ] || die "AnyKernel3 zip was not produced"
echo "OK: AnyKernel3 zip = ${ZIPNAME}"
ls -lh "${OUTDIR}"

cat > "${OUTDIR}/summary.txt" <<EOF
PanxCZ build summary
====================
Date            : $(date -u)
Variant         : ${VARIANT}
LTO             : ${LTO_MODE}
Kernel version  : ${KVER}${EXTRA}
Base            : ${BASE_REPO} (${BASE_BRANCH})
Root solution   : BakaSU (${BAKASU_REF}) + CONFIG_KSU_MULTI_MANAGER_SUPPORT
Hiding          : SUSFS ${SUSFS_BRANCH} (CONFIG_KSU_SUSFS_*)
Perf ported     : BBRv3 from Aetherium (${BBRV3})
Device          : ${DEVICE_PLATFORM}
Image           : ${OUTDIR}/Image
AnyKernel3 zip  : ${OUTDIR}/${ZIPNAME}

Credit: core kernel work belongs to MillenniumOSS (Chihiro), Aetherium
(kaminarich), BakaSU and upstream Linux / AOSP. PanxCZ is a rebrand +
integration layer only.
EOF
cat "${OUTDIR}/summary.txt"
log "DONE - build finished $(date -u)"
